import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;

import '../services/gpu_compositor.dart';
import 'editor_models.dart';

export 'editor_models.dart';

part 'editor_operations.dart';
part 'editor_effects.dart';
part 'editor_project.dart';
part 'editor_transform.dart';

/// Copy-on-write raster editor. Each committed stroke replaces one offscreen
/// image; all unchanged layer images are shared across undo snapshots.
class EditorController extends ChangeNotifier {
  EditorController({
    this.maxHistorySteps = 40,
    this.maxHistoryBytes = 128 << 20,
  });

  final int maxHistorySteps;
  final int maxHistoryBytes;
  Size _documentSize = const Size(1200, 900);
  List<EditorLayer> _layers = [];
  String? _activeLayerId;
  EditorTool _tool = EditorTool.brush;
  Color _brushColor = const Color(0xff7865e9);
  double _brushSize = 30;
  double _brushOpacity = 1;
  Rect? _selection;
  Path? _selectionPath;
  EditorSelectionKind? _selectionKind;
  Offset? _cloneSource;
  bool _cloneSourcePickMode = false;
  Color _secondaryColor = Colors.white;
  bool _shapeFilled = true;
  double _magicWandTolerance = .12;
  ui.Image? _clipboard;
  bool _busy = false;
  bool _disposed = false;
  int _revision = 0;
  int _nextId = 0;
  final List<_HistoryEntry> _undo = [];
  final List<_HistoryEntry> _redo = [];
  final Set<ui.Image> _images = HashSet.identity();
  _Snapshot? _transaction;
  String _transactionLabel = '';
  bool _transactionChanged = false;
  _Stroke? _stroke;
  _TransformSession? _transform;
  Timer? _gpuTimer;
  ui.Image? _gpuImage;
  int _gpuRevision = -1;
  int _gpuGeneration = 0;
  bool _gpuBuilding = false;
  String _renderer = 'Canvas GPU';

  Size get documentSize => _documentSize;
  List<EditorLayer> get layers => List.unmodifiable(_layers);
  String? get activeLayerId => _activeLayerId;
  EditorLayer? get activeLayer {
    for (final layer in _layers) {
      if (layer.id == _activeLayerId) return layer;
    }
    return null;
  }

  EditorTool get tool => _tool;
  Color get brushColor => _brushColor;
  double get brushSize => _brushSize;
  double get brushOpacity => _brushOpacity;
  Rect? get selection => _selection;
  Path? get selectionPath =>
      _selectionPath == null ? null : Path.from(_selectionPath!);
  EditorSelectionKind? get selectionKind => _selectionKind;
  Offset? get cloneSource => _cloneSource;
  bool get cloneSourcePickMode => _cloneSourcePickMode;
  Color get secondaryColor => _secondaryColor;
  bool get shapeFilled => _shapeFilled;
  double get magicWandTolerance => _magicWandTolerance;
  bool get canPaste => _clipboard != null;
  List<String> get historyLabels =>
      _undo.map((entry) => entry.label).toList().reversed.toList();
  bool get isBusy => _busy;
  bool get isStroking => _stroke != null;
  bool get canUndo =>
      !_busy && _stroke == null && (_undo.isNotEmpty || _transactionChanged);
  bool get canRedo =>
      !_busy && _stroke == null && !_transactionChanged && _redo.isNotEmpty;
  int get revision => _revision;
  int get historyLength => _undo.length;
  int get historyBytes => _retainedImages().fold(
    0,
    (sum, image) => sum + image.width * image.height * 4,
  );
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;
  String get renderer => _renderer;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _id() => 'layer-${_nextId++}';
  _Snapshot _snapshot() => _Snapshot(
    _documentSize,
    List.of(_layers),
    _activeLayerId,
    _selection,
    selectionPath,
    _selectionKind,
  );

  void beginTransaction(String label) {
    if (_disposed || _transaction != null) return;
    _transaction = _snapshot();
    _transactionLabel = label;
    _transactionChanged = false;
  }

  void commitTransaction() {
    if (_transform != null) return;
    if (_transaction == null) return;
    if (_transactionChanged) {
      _undo.add(_HistoryEntry(_transaction!, _transactionLabel));
      _redo.clear();
    }
    _transaction = null;
    _transactionChanged = false;
    _pruneHistory();
    _notify();
  }

  void cancelTransaction() {
    final before = _transaction;
    _transform = null;
    _transaction = null;
    _transactionChanged = false;
    if (before != null) _restore(before);
    _collectUnusedImages();
  }

  void _edit(String label, VoidCallback action) {
    if (_transform != null) cancelTransform();
    final ownsTransaction = _transaction == null;
    if (ownsTransaction) beginTransaction(label);
    action();
    _transactionChanged = true;
    _contentChanged();
    if (ownsTransaction) commitTransaction();
  }

  void _contentChanged() {
    _revision++;
    _gpuGeneration++;
    _gpuImage?.dispose();
    _gpuImage = null;
    _gpuRevision = -1;
    _gpuTimer?.cancel();
    if (!_disposed && supportsWebGl && _stroke == null && _transform == null) {
      _gpuTimer = Timer(const Duration(milliseconds: 110), _refreshGpu);
    }
    _notify();
  }

  void _restore(_Snapshot state) {
    _documentSize = state.size;
    _layers = List.of(state.layers);
    _activeLayerId = state.activeId;
    _selection = state.selection;
    _selectionPath = state.path == null ? null : Path.from(state.path!);
    _selectionKind = state.kind;
    _cloneSource = null;
    _cloneSourcePickMode = false;
    _contentChanged();
  }

  void undo() {
    if (_busy || _stroke != null) return;
    if (_transform != null) {
      final changed = _transactionChanged;
      cancelTransform();
      if (changed) return;
    }
    commitTransaction();
    if (_undo.isEmpty) return;
    final entry = _undo.removeLast();
    _redo.add(_HistoryEntry(_snapshot(), entry.label));
    _restore(entry.state);
    _collectUnusedImages();
  }

  void redo() {
    if (_busy || _stroke != null) return;
    if (_transform != null) cancelTransform();
    commitTransaction();
    if (_redo.isEmpty) return;
    final entry = _redo.removeLast();
    _undo.add(_HistoryEntry(_snapshot(), entry.label));
    _restore(entry.state);
    _pruneHistory();
  }

  Set<ui.Image> _retainedImages() {
    final result = HashSet<ui.Image>.identity();
    void include(Iterable<EditorLayer> layers) {
      result.addAll(layers.map((layer) => layer.image));
      result.addAll(layers.map((layer) => layer.mask).whereType<ui.Image>());
    }

    include(_layers);
    for (final entry in [..._undo, ..._redo]) {
      include(entry.state.layers);
    }
    if (_transaction != null) include(_transaction!.layers);
    if (_clipboard != null) result.add(_clipboard!);
    return result;
  }

  void _pruneHistory() {
    while (_undo.length + _redo.length > maxHistorySteps) {
      if (_undo.isNotEmpty) {
        _undo.removeAt(0);
      } else {
        _redo.removeAt(0);
      }
    }
    while (historyBytes > maxHistoryBytes &&
        (_undo.isNotEmpty || _redo.isNotEmpty)) {
      if (_undo.isNotEmpty) {
        _undo.removeAt(0);
      } else {
        _redo.removeAt(0);
      }
    }
    _collectUnusedImages();
  }

  void _collectUnusedImages() {
    final retained = _retainedImages();
    final unused = _images.where((image) => !retained.contains(image)).toList();
    for (final image in unused) {
      _images.remove(image);
      image.dispose();
    }
  }

  Future<ui.Image> _raster(void Function(Canvas) draw, {Size? size}) async {
    final dimensions = size ?? _documentSize;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    draw(canvas);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(
        dimensions.width.round(),
        dimensions.height.round(),
      );
    } finally {
      picture.dispose();
    }
  }

  Future<void> newDocument(int width, int height) async {
    if (_busy) return;
    if (width < 1 || height < 1 || width > 4096 || height > 4096) {
      throw ArgumentError('문서 크기는 1~4096 픽셀이어야 합니다.');
    }
    cancelStroke();
    cancelTransform();
    _busy = true;
    _notify();
    try {
      final size = Size(width.toDouble(), height.toDouble());
      final image = await _raster((_) {}, size: size);
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      _undo.clear();
      _redo.clear();
      _transaction = null;
      _documentSize = size;
      final layer = EditorLayer(id: _id(), name: '레이어 1', image: image);
      _layers = [layer];
      _activeLayerId = layer.id;
      _selection = null;
      _selectionPath = null;
      _selectionKind = null;
      _cloneSource = null;
      _cloneSourcePickMode = false;
      _contentChanged();
      _collectUnusedImages();
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> addLayer({String? name}) async {
    if (_busy) return;
    cancelTransform();
    _busy = true;
    _notify();
    try {
      final image = await _raster((_) {});
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      final layer = EditorLayer(
        id: _id(),
        name: name ?? '레이어 ${_layers.length + 1}',
        image: image,
      );
      _edit('레이어 추가', () {
        final index = _layers.indexWhere((item) => item.id == _activeLayerId);
        _layers.insert(index + 1, layer);
        _activeLayerId = layer.id;
      });
    } finally {
      _busy = false;
      _notify();
    }
  }

  void selectLayer(String id) {
    if (_busy || _stroke != null || !_layers.any((layer) => layer.id == id)) {
      return;
    }
    if (id != _activeLayerId) cancelTransform();
    _activeLayerId = id;
    _notify();
  }

  void removeActiveLayer() {
    if (!_busy) cancelTransform();
    final index = _layers.indexWhere((layer) => layer.id == _activeLayerId);
    if (_busy || index < 0 || _layers[index].locked) return;
    _edit('레이어 삭제', () {
      _layers.removeAt(index);
      _activeLayerId = _layers.isEmpty
          ? null
          : _layers[math.min(index, _layers.length - 1)].id;
    });
  }

  void duplicateActiveLayer() {
    if (!_busy) cancelTransform();
    final layer = activeLayer;
    if (_busy || layer == null) return;
    final duplicate = layer.copyWith(id: _id(), name: '${layer.name} 복사');
    _edit('레이어 복제', () {
      _layers.insert(_layers.indexOf(layer) + 1, duplicate);
      _activeLayerId = duplicate.id;
    });
  }

  void moveLayer(String id, int delta) {
    if (!_busy) cancelTransform();
    final index = _layers.indexWhere((layer) => layer.id == id);
    if (_busy || index < 0 || _layers[index].locked) return;
    final target = (index + delta).clamp(0, _layers.length - 1);
    if (index == target) return;
    _edit('레이어 순서', () {
      final layer = _layers.removeAt(index);
      _layers.insert(target, layer);
    });
  }

  void _replaceLayer(
    String id,
    EditorLayer Function(EditorLayer) update,
    String label, {
    bool allowLocked = false,
  }) {
    if (!_busy) cancelTransform();
    final index = _layers.indexWhere((layer) => layer.id == id);
    if (_busy || index < 0 || (!allowLocked && _layers[index].locked)) return;
    _edit(label, () {
      _layers[index] = update(_layers[index]);
    });
  }

  void toggleLayerVisibility(String id) => _replaceLayer(
    id,
    (layer) => layer.copyWith(visible: !layer.visible),
    '레이어 표시',
    allowLocked: true,
  );
  void toggleLayerLock(String id) => _replaceLayer(
    id,
    (layer) => layer.copyWith(locked: !layer.locked),
    '레이어 잠금',
    allowLocked: true,
  );
  void renameLayer(String id, String name) {
    if (name.trim().isEmpty) return;
    _replaceLayer(
      id,
      (layer) => layer.copyWith(name: name.trim()),
      '레이어 이름',
      allowLocked: true,
    );
  }

  void setLayerOpacity(double value) {
    if (_activeLayerId != null && activeLayer!.opacity != value.clamp(0, 1)) {
      _replaceLayer(
        _activeLayerId!,
        (layer) => layer.copyWith(opacity: value.clamp(0, 1)),
        '레이어 투명도',
      );
    }
  }

  void setLayerBlendMode(ui.BlendMode value) {
    if (_activeLayerId != null && activeLayer!.blendMode != value) {
      _replaceLayer(
        _activeLayerId!,
        (layer) => layer.copyWith(blendMode: value),
        '블렌드 모드',
      );
    }
  }

  void setAdjustments({
    double? brightness,
    double? contrast,
    double? saturation,
  }) {
    if (_activeLayerId == null) return;
    _replaceLayer(
      _activeLayerId!,
      (layer) => layer.copyWith(
        brightness: brightness?.clamp(-1, 1),
        contrast: contrast?.clamp(0, 2),
        saturation: saturation?.clamp(0, 2),
      ),
      '색상 보정',
    );
  }

  void setTool(EditorTool value) {
    if (value != _tool) cancelTransform();
    if (_stroke != null) cancelStroke();
    _tool = value;
    _notify();
  }

  void setBrushColor(Color value) {
    _brushColor = value;
    _notify();
  }

  void setBrushSize(double value) {
    _brushSize = value.clamp(1, 300);
    _notify();
  }

  void setBrushOpacity(double value) {
    _brushOpacity = value.clamp(0.01, 1);
    _notify();
  }

  void setSelection(Rect? value) {
    if (_busy) return;
    cancelTransform();
    final bounds = Offset.zero & _documentSize;
    final selected = value?.intersect(bounds);
    _selection = selected == null || selected.isEmpty ? null : selected;
    _selectionPath = _selection == null ? null : (Path()..addRect(_selection!));
    _selectionKind = _selection == null ? null : EditorSelectionKind.rectangle;
    _notify();
  }

  void clearSelection() => setSelection(null);

  void moveActiveLayer(Offset delta) {
    final layer = activeLayer;
    if (layer != null) setLayerTransform(offset: layer.offset + delta);
  }

  void setLayerTransform({Offset? offset, double? rotation, double? scale}) {
    if (_activeLayerId == null) return;
    _replaceLayer(
      _activeLayerId!,
      (layer) => layer.copyWith(
        offset: offset,
        rotation: rotation,
        scale: scale?.clamp(0.05, 10),
      ),
      '레이어 변형',
    );
  }

  Offset layerToDocument(Offset point, EditorLayer layer) {
    final center = _documentSize.center(Offset.zero);
    final local = (point - center) * layer.scale;
    final cos = math.cos(layer.rotation), sin = math.sin(layer.rotation);
    return center +
        layer.offset +
        Offset(
          local.dx * cos - local.dy * sin,
          local.dx * sin + local.dy * cos,
        );
  }

  Offset documentToLayer(Offset point, EditorLayer layer) {
    final center = _documentSize.center(Offset.zero);
    final local = point - center - layer.offset;
    final cos = math.cos(layer.rotation), sin = math.sin(layer.rotation);
    return center +
        Offset(
              local.dx * cos + local.dy * sin,
              -local.dx * sin + local.dy * cos,
            ) /
            layer.scale;
  }

  void beginStroke(Offset point, {double pressure = 1}) {
    if (!_busy) cancelTransform();
    final layer = activeLayer;
    if (_busy ||
        layer == null ||
        layer.locked ||
        !layer.visible ||
        _stroke != null ||
        ![
          EditorTool.brush,
          EditorTool.eraser,
          EditorTool.cloneStamp,
        ].contains(_tool) ||
        (_tool == EditorTool.cloneStamp && _cloneSource == null)) {
      return;
    }
    beginTransaction(_tool == EditorTool.eraser ? '지우개' : '브러시');
    _stroke = _Stroke(
      layer,
      _tool == EditorTool.eraser,
      _brushColor,
      _brushSize / layer.scale,
      _brushOpacity,
      selectionPath,
      cloneSource: _tool == EditorTool.cloneStamp
          ? documentToLayer(_cloneSource!, layer)
          : null,
      cloneAnchor: _tool == EditorTool.cloneStamp
          ? documentToLayer(point, layer)
          : null,
    );
    appendStroke(point, pressure: pressure);
  }

  void appendStroke(Offset point, {double pressure = 1}) {
    final stroke = _stroke;
    if (stroke == null || _busy) return;
    final local = documentToLayer(point, stroke.layer);
    final effectivePressure = pressure <= 0 ? 1.0 : pressure.clamp(0.05, 1.0);
    if (stroke.points.isNotEmpty &&
        (local - stroke.points.last.point).distance < 0.1) {
      return;
    }
    stroke.points.add(_StrokePoint(local, effectivePressure));
    _notify();
  }

  Future<void> endStroke() async {
    final stroke = _stroke;
    if (stroke == null || _busy) return;
    _busy = true;
    _notify();
    try {
      final image = await _raster((canvas) {
        canvas.drawImage(stroke.layer.image, Offset.zero, Paint());
        _paintStroke(canvas, stroke);
      });
      if (_disposed || _stroke != stroke) {
        image.dispose();
        return;
      }
      _images.add(image);
      final index = _layers.indexWhere((layer) => layer.id == stroke.layer.id);
      if (index >= 0) {
        _layers[index] = _layers[index].copyWith(image: image, clearText: true);
        _transactionChanged = true;
      }
      _stroke = null;
      _contentChanged();
      commitTransaction();
    } catch (_) {
      // A failed GPU allocation must not leave the editor stuck in a stroke
      // transaction. The previous immutable image remains the valid content.
      if (_stroke == stroke) cancelStroke();
      rethrow;
    } finally {
      _busy = false;
      _notify();
    }
  }

  void cancelStroke() {
    if (_stroke == null) return;
    _stroke = null;
    cancelTransaction();
    _notify();
  }

  void _paintStroke(Canvas canvas, _Stroke stroke) {
    if (stroke.points.isEmpty) return;
    canvas.save();
    if (stroke.selection != null) {
      canvas.clipPath(_documentPathToLayer(stroke.selection!, stroke.layer));
    }
    // A stroke is one opacity group, so overlapping segments do not darken it.
    canvas.saveLayer(
      Offset.zero & _documentSize,
      Paint()
        ..blendMode = stroke.erase ? ui.BlendMode.dstOut : ui.BlendMode.srcOver
        ..color = Colors.white.withValues(alpha: stroke.opacity),
    );
    final paint = Paint()
      ..color = stroke.erase ? Colors.white : stroke.color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (stroke.cloneSource != null) {
      final path = Path();
      for (var index = 0; index < stroke.points.length; index++) {
        final point = stroke.points[index];
        final radius = stroke.size * point.pressure / 2;
        path.addOval(Rect.fromCircle(center: point.point, radius: radius));
        if (index > 0) {
          final previous = stroke.points[index - 1];
          final distance = (point.point - previous.point).distance;
          final steps = math.max(
            1,
            (distance / math.max(1, radius / 2)).ceil(),
          );
          for (var step = 1; step < steps; step++) {
            path.addOval(
              Rect.fromCircle(
                center: Offset.lerp(previous.point, point.point, step / steps)!,
                radius: radius,
              ),
            );
          }
        }
      }
      canvas.clipPath(path);
      canvas.drawImage(
        stroke.layer.image,
        stroke.cloneAnchor! - stroke.cloneSource!,
        Paint(),
      );
    } else if (stroke.points.length == 1) {
      canvas.drawCircle(
        stroke.points.first.point,
        stroke.size * stroke.points.first.pressure / 2,
        paint,
      );
    } else {
      for (var index = 1; index < stroke.points.length; index++) {
        final previous = stroke.points[index - 1],
            current = stroke.points[index];
        paint.strokeWidth =
            stroke.size * (previous.pressure + current.pressure) / 2;
        canvas.drawLine(previous.point, current.point, paint);
      }
    }
    canvas.restore();
    canvas.restore();
  }

  /// Transparent composition in document coordinates. Checkerboard and UI
  /// overlays belong to the viewport and never become exported image content.
  void paintDocument(Canvas canvas, {bool includeStroke = true}) {
    // Keep the checkerboard (or any host background) out of layer blending.
    // Export starts transparent, so the viewport must use that same backdrop.
    canvas.saveLayer(Offset.zero & _documentSize, Paint());
    canvas.clipRect(Offset.zero & _documentSize);
    if (_gpuImage != null &&
        _gpuRevision == _revision &&
        _transform == null &&
        (!includeStroke || _stroke == null)) {
      canvas.drawImage(_gpuImage!, Offset.zero, Paint());
    } else {
      for (final layer in _layers) {
        if (layer.visible) {
          _paintLayer(canvas, layer, includeStroke: includeStroke);
        }
      }
    }
    canvas.restore();
  }

  void _paintLayer(
    Canvas canvas,
    EditorLayer layer, {
    bool includeStroke = false,
    bool applyComposite = true,
  }) {
    canvas.saveLayer(
      Offset.zero & _documentSize,
      Paint()
        ..blendMode = applyComposite ? layer.blendMode : ui.BlendMode.srcOver
        ..color = Colors.white.withValues(
          alpha: applyComposite ? layer.opacity : 1,
        )
        ..colorFilter = ColorFilter.matrix(
          colorMatrixForAdjustments(
            layer.brightness,
            layer.contrast,
            layer.saturation,
          ),
        ),
    );
    final transform = _transform;
    if (transform?.path != null && transform!.layer.id == layer.id) {
      _paintSelectionTransform(canvas, transform);
    } else {
      final center = _documentSize.center(Offset.zero);
      canvas.translate(
        center.dx + layer.offset.dx,
        center.dy + layer.offset.dy,
      );
      canvas.rotate(layer.rotation);
      canvas.scale(layer.scale);
      canvas.translate(-center.dx, -center.dy);
      paintLayerContent(canvas, layer, includeStroke: includeStroke);
    }
    canvas.restore();
  }

  void paintLayerContent(
    Canvas canvas,
    EditorLayer layer, {
    bool includeStroke = true,
  }) {
    canvas.drawImage(
      layer.image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    if (includeStroke && _stroke?.layer.id == layer.id) {
      _paintStroke(canvas, _stroke!);
    }
    if (layer.mask != null && layer.maskEnabled) {
      canvas.drawImage(
        layer.mask!,
        Offset.zero,
        Paint()..blendMode = ui.BlendMode.dstIn,
      );
    }
  }

  static List<double> colorMatrixForAdjustments(
    double brightness,
    double contrast,
    double saturation,
  ) {
    final inverse = 1 - saturation;
    final red = 0.2126 * inverse,
        green = 0.7152 * inverse,
        blue = 0.0722 * inverse;
    final offset = 255 * (brightness + (1 - contrast) * 0.5);
    return [
      (red + saturation) * contrast,
      green * contrast,
      blue * contrast,
      0,
      offset,
      red * contrast,
      (green + saturation) * contrast,
      blue * contrast,
      0,
      offset,
      red * contrast,
      green * contrast,
      (blue + saturation) * contrast,
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  Future<void> importImage(Uint8List bytes, String name) async {
    if (_busy) return;
    cancelTransform();
    _busy = true;
    _notify();
    ui.Codec? codec;
    ui.Image? decoded;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final decodeScale = math.min(
        1.0,
        4096 / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * decodeScale).round()),
        targetHeight: math.max(1, (descriptor.height * decodeScale).round()),
      );
      decoded = (await codec.getNextFrame()).image;
      final source = decoded;
      final image = await _raster((canvas) {
        final scale = math.min(
          _documentSize.width / source.width,
          _documentSize.height / source.height,
        );
        final width = source.width * scale, height = source.height * scale;
        final target = Rect.fromLTWH(
          (_documentSize.width - width) / 2,
          (_documentSize.height - height) / 2,
          width,
          height,
        );
        canvas.drawImageRect(
          source,
          Rect.fromLTWH(
            0,
            0,
            source.width.toDouble(),
            source.height.toDouble(),
          ),
          target,
          Paint()..filterQuality = FilterQuality.high,
        );
      });
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      final layer = EditorLayer(
        id: _id(),
        name: name.trim().isEmpty ? '가져온 이미지' : name,
        image: image,
      );
      _edit('이미지 가져오기', () {
        _layers.add(layer);
        _activeLayerId = layer.id;
      });
    } finally {
      decoded?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
      _busy = false;
      _notify();
    }
  }

  Future<ui.Image> _textImage(
    String text,
    double fontSize,
    Color color,
    Offset position,
    String fontFamily,
  ) => _raster((canvas) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontFamily: fontFamily,
          fontWeight: FontWeight.w600,
          height: 1.15,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    painter.layout(
      maxWidth: math.max(1, _documentSize.width - math.max(0, position.dx)),
    );
    painter.paint(canvas, position);
    painter.dispose();
  });

  Future<void> addText(
    String text, {
    double fontSize = 84,
    Color? color,
    Offset? position,
    String? fontFamily,
  }) async {
    if (_busy || text.trim().isEmpty) return;
    cancelTransform();
    _busy = true;
    _notify();
    try {
      final textColor = color ?? _brushColor,
          origin =
              position ??
              Offset(_documentSize.width * 0.12, _documentSize.height * 0.42);
      final family = fontFamily ?? 'sans-serif';
      final image = await _textImage(text, fontSize, textColor, origin, family);
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      final layer = EditorLayer(
        id: _id(),
        name: text.length > 24 ? '${text.substring(0, 24)}…' : text,
        image: image,
        text: text,
        fontSize: fontSize,
        color: textColor,
        textPosition: origin,
        fontFamily: family,
      );
      _edit('텍스트 추가', () {
        _layers.add(layer);
        _activeLayerId = layer.id;
      });
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> updateText(
    String text, {
    double? fontSize,
    Color? color,
    String? fontFamily,
  }) async {
    if (!_busy) cancelTransform();
    final layer = activeLayer;
    if (_busy ||
        layer == null ||
        !layer.isText ||
        layer.locked ||
        text.trim().isEmpty) {
      return;
    }
    _busy = true;
    _notify();
    try {
      final image = await _textImage(
        text,
        fontSize ?? layer.fontSize,
        color ?? layer.color,
        layer.textPosition,
        fontFamily ?? layer.fontFamily,
      );
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      _edit('텍스트 편집', () {
        final index = _layers.indexWhere((item) => item.id == layer.id);
        _layers[index] = layer.copyWith(
          image: image,
          text: text,
          fontSize: fontSize,
          color: color,
          fontFamily: fontFamily,
        );
      });
    } finally {
      _busy = false;
      _notify();
    }
  }

  String _blendName(ui.BlendMode mode) => switch (mode) {
    ui.BlendMode.multiply => 'multiply',
    ui.BlendMode.screen => 'screen',
    ui.BlendMode.overlay => 'overlay',
    ui.BlendMode.darken => 'darken',
    ui.BlendMode.lighten => 'lighten',
    ui.BlendMode.difference => 'difference',
    ui.BlendMode.plus => 'add',
    _ => 'normal',
  };

  Future<ui.Image?> _buildGpuComposite() async {
    if (!supportsWebGl) return null;
    final size = _documentSize;
    final rasterized = <Future<ui.Image>>[];
    final temporaryImages = <ui.Image>[];
    final visible = _layers.where((layer) => layer.visible).toList();
    // Record all pictures before awaiting, to pin the source image resources.
    for (final layer in visible) {
      rasterized.add(
        _raster(
          (canvas) => _paintLayer(canvas, layer, applyComposite: false),
          size: size,
        ).then((image) {
          temporaryImages.add(image);
          return image;
        }),
      );
    }
    try {
      // Future.wait waits for every allocation even when one fails, letting
      // the finally block release all successfully allocated temporary images.
      final images = await Future.wait(rasterized);
      final gpuLayers = <GpuLayer>[];
      for (var index = 0; index < images.length; index++) {
        final image = images[index];
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (bytes == null) return null;
        gpuLayers.add(
          GpuLayer(
            rgba: bytes.buffer.asUint8List(
              bytes.offsetInBytes,
              bytes.lengthInBytes,
            ),
            opacity: visible[index].opacity,
            blendMode: _blendName(visible[index].blendMode),
          ),
        );
      }
      return await compositeWebGl(
        width: size.width.round(),
        height: size.height.round(),
        layers: gpuLayers,
      );
    } finally {
      for (final image in temporaryImages) {
        image.dispose();
      }
    }
  }

  Future<void> _refreshGpu() async {
    if (_disposed ||
        _stroke != null ||
        _transform != null ||
        _busy ||
        _gpuBuilding) {
      return;
    }
    _gpuBuilding = true;
    final generation = _gpuGeneration;
    ui.Image? image;
    try {
      image = await _buildGpuComposite();
    } catch (_) {
      _renderer = 'Canvas GPU';
      return;
    } finally {
      _gpuBuilding = false;
      if (!_disposed &&
          generation != _gpuGeneration &&
          _stroke == null &&
          _transform == null) {
        _gpuTimer?.cancel();
        _gpuTimer = Timer(const Duration(milliseconds: 110), _refreshGpu);
      }
    }
    if (_disposed ||
        generation != _gpuGeneration ||
        _stroke != null ||
        _transform != null) {
      image?.dispose();
      return;
    }
    if (image != null) {
      _gpuImage?.dispose();
      _gpuImage = image;
      _gpuRevision = _revision;
      _renderer = 'WebGL shaders';
      _notify();
    }
  }

  Future<Uint8List> exportPng() async {
    if (_stroke != null) await endStroke();
    if (_transform != null) await commitTransform();
    ui.Image? image;
    try {
      image = await _buildGpuComposite();
    } catch (_) {
      /* Canvas fallback. */
    }
    image ??= await _raster(
      (canvas) => paintDocument(canvas, includeStroke: false),
    );
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG 인코딩에 실패했습니다.');
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  Future<void> initializeDemo() async {
    if (_busy || _layers.isNotEmpty) return;
    _busy = true;
    _notify();
    final size = _documentSize;
    final rect = Offset.zero & size;
    try {
      final demo = <EditorLayer>[];
      Future<void> add(String name, void Function(Canvas) draw) async {
        final image = await _raster(draw);
        if (_disposed) {
          image.dispose();
          return;
        }
        _images.add(image);
        demo.add(EditorLayer(id: _id(), name: name, image: image));
      }

      await add('피치 하늘', (canvas) {
        canvas.drawRect(
          rect,
          Paint()
            ..shader = ui.Gradient.linear(
              Offset.zero,
              Offset(0, size.height),
              [
                const Color(0xffe4c9b9),
                const Color(0xffeee2cc),
                const Color(0xfff4e8cc),
              ],
              [0, 0.5, 1],
            ),
        );
      });
      await add('오후의 태양', (canvas) {
        canvas.drawCircle(
          const Offset(835, 245),
          102,
          Paint()..color = const Color(0xfff9eace),
        );
      });
      await add('먼 산의 능선', (canvas) {
        final back = Path()
          ..moveTo(-20, 520)
          ..cubicTo(140, 485, 210, 368, 345, 394)
          ..cubicTo(475, 420, 498, 308, 635, 360)
          ..cubicTo(766, 410, 822, 358, 943, 427)
          ..cubicTo(1050, 481, 1160, 396, 1240, 445)
          ..lineTo(1240, 940)
          ..lineTo(-20, 940)
          ..close();
        canvas.drawPath(back, Paint()..color = const Color(0xff9daead));
        final front = Path()
          ..moveTo(-20, 592)
          ..cubicTo(151, 485, 263, 628, 417, 542)
          ..cubicTo(580, 453, 640, 483, 775, 516)
          ..cubicTo(930, 554, 1055, 472, 1240, 530)
          ..lineTo(1240, 940)
          ..lineTo(-20, 940)
          ..close();
        canvas.drawPath(
          front,
          Paint()
            ..shader = ui.Gradient.linear(
              const Offset(0, 460),
              const Offset(0, 860),
              [const Color(0xff6f9395), const Color(0xff9db0a5)],
            ),
        );
      });
      await add('사구와 해안', (canvas) {
        final sea = Path()
          ..moveTo(-20, 712)
          ..cubicTo(227, 615, 382, 713, 538, 667)
          ..cubicTo(736, 608, 900, 708, 1240, 620)
          ..lineTo(1240, 930)
          ..lineTo(-20, 930)
          ..close();
        canvas.drawPath(sea, Paint()..color = const Color(0xff4b797d));
        final dune = Path()
          ..moveTo(-20, 624)
          ..cubicTo(169, 640, 222, 782, 447, 783)
          ..cubicTo(708, 783, 884, 701, 1240, 765)
          ..lineTo(1240, 930)
          ..lineTo(-20, 930)
          ..close();
        canvas.drawPath(
          dune,
          Paint()
            ..shader = ui.Gradient.linear(
              const Offset(0, 610),
              const Offset(700, 950),
              [const Color(0xffdfba8c), const Color(0xffecd4b2)],
            ),
        );
        final shadow = Path()
          ..moveTo(-20, 855)
          ..cubicTo(221, 730, 405, 928, 661, 856)
          ..cubicTo(869, 799, 1041, 819, 1240, 881)
          ..lineTo(1240, 930)
          ..lineTo(-20, 930)
          ..close();
        canvas.drawPath(shadow, Paint()..color = const Color(0xffcaa17b));
      });
      await add('빛과 작은 흔적', (canvas) {
        final random = math.Random(19);
        final grain = Paint();
        for (var index = 0; index < 6500; index++) {
          grain.color = Colors.white.withValues(
            alpha: random.nextDouble() * 0.065,
          );
          canvas.drawCircle(
            Offset(random.nextDouble() * 1200, random.nextDouble() * 900),
            0.6 + random.nextDouble(),
            grain,
          );
        }
        final footsteps = Paint()
          ..color = const Color(0xff9b795e).withValues(alpha: 0.48);
        for (var index = 0; index < 9; index++) {
          final y = 828.0 - index * 11,
              x = 620.0 + index * 5 + (index.isEven ? -3 : 3);
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset(x, y),
              width: 3.2 - index * 0.2,
              height: 5 - index * 0.25,
            ),
            footsteps,
          );
        }
        final birds = Paint()
          ..color = const Color(0xff526d6a)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round;
        canvas.drawPath(
          Path()
            ..moveTo(269, 263)
            ..quadraticBezierTo(278, 256, 285, 262)
            ..quadraticBezierTo(292, 253, 301, 257),
          birds,
        );
        canvas.drawPath(
          Path()
            ..moveTo(314, 283)
            ..quadraticBezierTo(320, 278, 325, 281)
            ..quadraticBezierTo(331, 274, 338, 278),
          birds,
        );
      });
      if (_disposed) return;
      _layers = demo;
      _activeLayerId = demo.last.id;
      _contentChanged();
    } finally {
      _busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _gpuGeneration++;
    _gpuTimer?.cancel();
    _gpuImage?.dispose();
    for (final image in _images) {
      image.dispose();
    }
    _images.clear();
    super.dispose();
  }
}

class _Snapshot {
  const _Snapshot(
    this.size,
    this.layers,
    this.activeId,
    this.selection,
    this.path,
    this.kind,
  );
  final Size size;
  final List<EditorLayer> layers;
  final String? activeId;
  final Rect? selection;
  final Path? path;
  final EditorSelectionKind? kind;
}

class _HistoryEntry {
  const _HistoryEntry(this.state, this.label);
  final _Snapshot state;
  final String label;
}

class _StrokePoint {
  const _StrokePoint(this.point, this.pressure);
  final Offset point;
  final double pressure;
}

class _Stroke {
  _Stroke(
    this.layer,
    this.erase,
    this.color,
    this.size,
    this.opacity,
    this.selection, {
    this.cloneSource,
    this.cloneAnchor,
  });
  final EditorLayer layer;
  final bool erase;
  final Color color;
  final double size;
  final double opacity;
  final Path? selection;
  final Offset? cloneSource;
  final Offset? cloneAnchor;
  final List<_StrokePoint> points = [];
}
