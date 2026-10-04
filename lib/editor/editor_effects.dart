part of 'editor_controller.dart';

enum EditorFilter {
  invert,
  grayscale,
  sepia,
  gaussianBlur,
  sharpen,
  posterize,
  threshold,
  autoContrast,
}

extension EditorEffects on EditorController {
  EditorLayer _baked(EditorLayer layer, ui.Image image) => layer.copyWith(
    image: image,
    offset: Offset.zero,
    rotation: 0,
    scale: 1,
    brightness: 0,
    contrast: 1,
    saturation: 1,
    clearText: true,
    clearMask: true,
  );

  Future<void> applyFilter(EditorFilter filter, {double? amount}) async {
    if (!_prepareOperation(settleTransaction: true)) return;
    final layer = activeLayer;
    final selectedPath = selectionPath;
    if (_busy ||
        layer == null ||
        layer.locked ||
        !layer.visible ||
        _disposed ||
        _stroke != null) {
      return;
    }
    _busy = true;
    _notify();
    ui.Image? source, filtered;
    try {
      source = await _raster(
        (canvas) => _paintLayer(canvas, layer, applyComposite: false),
      );
      if (filter == EditorFilter.gaussianBlur) {
        final radius = (amount ?? 4).clamp(.1, 40).toDouble();
        final original = source;
        filtered = await _raster((canvas) {
          canvas.saveLayer(
            Offset.zero & documentSize,
            Paint()
              ..imageFilter = ui.ImageFilter.blur(
                sigmaX: radius,
                sigmaY: radius,
                tileMode: ui.TileMode.clamp,
              ),
          );
          canvas.drawImage(original, Offset.zero, Paint());
          canvas.restore();
        });
      } else {
        final data = await source.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (data == null) throw StateError('레이어 픽셀을 읽을 수 없습니다.');
        final args = <String, Object>{
          'pixels': data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          ),
          'width': documentSize.width.toInt(),
          'height': documentSize.height.toInt(),
          'filter': filter.name,
          'amount':
              amount ??
              switch (filter) {
                EditorFilter.sharpen => 1.0,
                EditorFilter.posterize => 6.0,
                EditorFilter.threshold => .5,
                _ => 1.0,
              },
        };
        final workerResult = await filterPixelsWeb(args);
        final Uint8List pixels;
        if (workerResult != null) {
          pixels = workerResult;
        } else {
          pixels = await compute<Map<String, Object>, Uint8List>(
            _filterPixels,
            args,
          );
        }
        final completion = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          pixels,
          documentSize.width.toInt(),
          documentSize.height.toInt(),
          ui.PixelFormat.rgba8888,
          completion.complete,
        );
        filtered = await completion.future;
      }
      final original = source, result = filtered;
      final image = await _raster((canvas) {
        canvas.drawImage(original, Offset.zero, Paint());
        canvas.save();
        if (selectedPath != null) canvas.clipPath(selectedPath);
        canvas.drawImage(
          result,
          Offset.zero,
          Paint()..blendMode = ui.BlendMode.src,
        );
        canvas.restore();
      });
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      final label = switch (filter) {
        EditorFilter.invert => '색상 반전',
        EditorFilter.grayscale => '흑백',
        EditorFilter.sepia => '세피아',
        EditorFilter.gaussianBlur => '가우시안 흐림',
        EditorFilter.sharpen => '선명하게',
        EditorFilter.posterize => '포스터화',
        EditorFilter.threshold => '임계값',
        EditorFilter.autoContrast => '자동 대비',
      };
      _edit('필터: $label', () {
        _layers[_layers.indexOf(layer)] = _baked(layer, image);
      });
    } finally {
      source?.dispose();
      filtered?.dispose();
      _busy = false;
      _notify();
    }
  }

  Future<void> _changeGeometry(
    String label,
    Size size,
    void Function(Canvas) transform,
  ) async {
    if (!_canStartOperation) return;
    EditorProjectSchema.validateDocumentSize(
      size.width.toInt(),
      size.height.toInt(),
    );
    EditorProjectSchema.validateDecodedBudget(
      size.width.toInt(),
      size.height.toInt(),
      layerCount: _layers.length,
    );
    if (!_prepareOperation(settleTransaction: true)) return;
    _busy = true;
    _notify();
    final pending = <ui.Image>[];
    try {
      final updated = <EditorLayer>[];
      for (final layer in _layers) {
        final image = await _raster((canvas) {
          transform(canvas);
          _paintLayer(canvas, layer, applyComposite: false);
        }, size: size);
        pending.add(image);
        updated.add(_baked(layer, image));
      }
      if (_disposed) return;
      _images.addAll(pending);
      _edit(label, () {
        _layers = updated;
        _documentSize = size;
        _selection = null;
        _selectionPath = null;
        _selectionKind = null;
        _cloneSource = null;
        _cloneSourcePickMode = false;
      });
      pending.clear();
    } finally {
      for (final image in pending) {
        image.dispose();
      }
      _busy = false;
      _notify();
    }
  }

  Future<void> cropToSelection() async {
    if (!_prepareOperation(settleTransaction: true)) return;
    final rect = _selection?.intersect(Offset.zero & documentSize);
    if (rect == null || rect.isEmpty) return;
    final crop = Rect.fromLTRB(
      rect.left.floorToDouble(),
      rect.top.floorToDouble(),
      rect.right.ceilToDouble(),
      rect.bottom.ceilToDouble(),
    );
    await _changeGeometry(
      '캔버스 자르기',
      crop.size,
      (canvas) => canvas.translate(-crop.left, -crop.top),
    );
  }

  Future<void> resizeDocument(int width, int height) {
    final previous = documentSize;
    return _changeGeometry(
      '이미지 크기 변경',
      Size(width.toDouble(), height.toDouble()),
      (canvas) =>
          canvas.scale(width / previous.width, height / previous.height),
    );
  }

  Future<void> rotateDocument({bool clockwise = true}) {
    final size = documentSize;
    return _changeGeometry('캔버스 90° 회전', Size(size.height, size.width), (
      canvas,
    ) {
      canvas.translate(clockwise ? size.height : 0, clockwise ? 0 : size.width);
      canvas.rotate(clockwise ? math.pi / 2 : -math.pi / 2);
    });
  }

  Future<void> flipActiveLayer({bool horizontal = true}) async {
    if (!_prepareOperation(settleTransaction: true)) return;
    final layer = activeLayer;
    if (_busy ||
        layer == null ||
        layer.locked ||
        _disposed ||
        _stroke != null) {
      return;
    }
    _busy = true;
    _notify();
    try {
      final image = await _raster((canvas) {
        canvas.translate(
          horizontal ? documentSize.width : 0,
          horizontal ? 0 : documentSize.height,
        );
        canvas.scale(horizontal ? -1 : 1, horizontal ? 1 : -1);
        _paintLayer(canvas, layer, applyComposite: false);
      });
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      _edit(horizontal ? '레이어 좌우 반전' : '레이어 상하 반전', () {
        _layers[_layers.indexOf(layer)] = _baked(layer, image);
      });
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> mergeDown() async {
    if (!_prepareOperation(settleTransaction: true)) return;
    final index = _layers.indexWhere((layer) => layer.id == _activeLayerId);
    if (_busy || index < 1 || _disposed || _stroke != null) return;
    final top = _layers[index], bottom = _layers[index - 1];
    if (top.blendMode != ui.BlendMode.srcOver ||
        bottom.blendMode != ui.BlendMode.srcOver) {
      throw StateError('블렌드 모드 레이어는 보이는 레이어 합성을 사용하면 현재 색상을 유지할 수 있습니다.');
    }
    if (top.locked || bottom.locked || !top.visible || !bottom.visible) return;
    _busy = true;
    _notify();
    try {
      final image = await _raster((canvas) {
        _paintLayer(canvas, bottom);
        _paintLayer(canvas, top);
      });
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      final merged = EditorLayer(
        id: bottom.id,
        name:
            '${bottom.name} + ${top.name}'.length <=
                EditorProjectSchema.maxLayerNameLength
            ? '${bottom.name} + ${top.name}'
            : '병합한 레이어',
        image: image,
      );
      _edit('아래 레이어와 병합', () {
        _layers.replaceRange(index - 1, index + 1, [merged]);
        _activeLayerId = merged.id;
      });
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> flattenDocument() async {
    if (!_prepareOperation(settleTransaction: true) || _layers.isEmpty) return;
    _busy = true;
    _notify();
    try {
      final image = await _raster(
        (canvas) => paintDocument(canvas, includeStroke: false),
      );
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      final layer = EditorLayer(id: _id(), name: '합성 이미지', image: image);
      _edit('보이는 레이어 합성', () {
        _layers = [layer];
        _activeLayerId = layer.id;
      });
    } finally {
      _busy = false;
      _notify();
    }
  }
}

Uint8List _filterPixels(Map<String, Object> args) {
  final input = args['pixels'] as Uint8List,
      width = args['width'] as int,
      height = args['height'] as int;
  final filter = args['filter'] as String, amount = args['amount'] as double;
  final output = Uint8List(input.length);
  var low = 255.0, high = 0.0;
  if (filter == 'autoContrast') {
    final histogram = List<int>.filled(256, 0);
    var count = 0;
    for (var i = 0; i < input.length; i += 4) {
      if (input[i + 3] == 0) continue;
      histogram[(.2126 * input[i] + .7152 * input[i + 1] + .0722 * input[i + 2])
          .round()]++;
      count++;
    }
    final clip = (count * .01).floor();
    var sum = 0;
    for (var i = 0; i < 256; i++) {
      sum += histogram[i];
      if (sum > clip) {
        low = i.toDouble();
        break;
      }
    }
    sum = 0;
    for (var i = 255; i >= 0; i--) {
      sum += histogram[i];
      if (sum > clip) {
        high = i.toDouble();
        break;
      }
    }
  }
  for (var i = 0; i < input.length; i += 4) {
    final r = input[i].toDouble(),
        g = input[i + 1].toDouble(),
        b = input[i + 2].toDouble();
    var rr = r, gg = g, bb = b;
    if (filter == 'invert') {
      rr = 255 - r;
      gg = 255 - g;
      bb = 255 - b;
    } else if (filter == 'grayscale') {
      rr = gg = bb = .2126 * r + .7152 * g + .0722 * b;
    } else if (filter == 'sepia') {
      rr = .393 * r + .769 * g + .189 * b;
      gg = .349 * r + .686 * g + .168 * b;
      bb = .272 * r + .534 * g + .131 * b;
    } else if (filter == 'posterize') {
      final levels = amount.round().clamp(2, 32) - 1;
      rr = (r / 255 * levels).round() * 255 / levels;
      gg = (g / 255 * levels).round() * 255 / levels;
      bb = (b / 255 * levels).round() * 255 / levels;
    } else if (filter == 'threshold') {
      rr = gg = bb =
          (.2126 * r + .7152 * g + .0722 * b) >= amount.clamp(0, 1) * 255
          ? 255
          : 0;
    } else if (filter == 'autoContrast' && high > low) {
      rr = (r - low) * 255 / (high - low);
      gg = (g - low) * 255 / (high - low);
      bb = (b - low) * 255 / (high - low);
    } else if (filter == 'sharpen') {
      final pixel = i ~/ 4,
          x = pixel % width,
          y = pixel ~/ width,
          a = amount.clamp(0, 3);
      double sharpen(int channel) {
        final center = input[i + channel].toDouble();
        var sum = 0.0;
        for (final p in [
          y * width + math.max(0, x - 1),
          y * width + math.min(width - 1, x + 1),
          math.max(0, y - 1) * width + x,
          math.min(height - 1, y + 1) * width + x,
        ]) {
          // Transparent neighbors carry no color, avoiding black edge halos.
          sum += input[p.toInt() * 4 + 3] == 0
              ? center
              : input[p.toInt() * 4 + channel];
        }
        return center * (1 + 4 * a) - sum * a;
      }

      rr = sharpen(0);
      gg = sharpen(1);
      bb = sharpen(2);
    }
    final alpha = input[i + 3];
    output[i] = (rr.clamp(0, 255) * alpha / 255).round();
    output[i + 1] = (gg.clamp(0, 255) * alpha / 255).round();
    output[i + 2] = (bb.clamp(0, 255) * alpha / 255).round();
    output[i + 3] = alpha;
  }
  return output;
}
