import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editor_controller.dart';

/// The document-to-screen transform, shared by the canvas and zoom controls.
class ViewportController extends ChangeNotifier {
  double _zoom = 1;
  Offset _origin = Offset.zero;
  Size _viewportSize = Size.zero;
  Size _documentSize = Size.zero;
  bool _initialized = false;

  double get zoom => _zoom;
  Offset get pan => _origin;

  Offset documentToViewport(Offset point) => _origin + point * _zoom;
  Offset viewportToDocument(Offset point) => (point - _origin) / _zoom;

  void zoomIn() => zoomAt(_viewportSize.center(Offset.zero), _zoom * 1.2);
  void zoomOut() => zoomAt(_viewportSize.center(Offset.zero), _zoom / 1.2);

  /// Zooms around a point expressed in viewport logical pixels.
  void zoomAt(Offset anchor, double value) {
    final documentAnchor = viewportToDocument(anchor);
    final nextZoom = value.clamp(.05, 8.0).toDouble();
    _setView(nextZoom, anchor - documentAnchor * nextZoom);
  }

  void fit() {
    if (_viewportSize.isEmpty || _documentSize.isEmpty) return;
    final margin = _viewportSize.width < 600 ? 28.0 : 64.0;
    final available = Size(
      math.max(1, _viewportSize.width - margin * 2),
      math.max(1, _viewportSize.height - margin * 2),
    );
    final fitted = math
        .min(
          available.width / _documentSize.width,
          available.height / _documentSize.height,
        )
        .clamp(.05, 8.0)
        .toDouble();
    _setView(
      fitted,
      _viewportSize.center(Offset.zero) -
          _documentSize.center(Offset.zero) * fitted,
    );
  }

  void reset() {
    _setView(
      1,
      _viewportSize.center(Offset.zero) - _documentSize.center(Offset.zero),
    );
  }

  void _setView(double zoom, Offset origin, {bool notify = true}) {
    if (_zoom == zoom && _origin == origin) return;
    _zoom = zoom;
    _origin = origin;
    if (notify) notifyListeners();
  }

  void _reportLayout() => notifyListeners();

  // Layout may happen during a parent build. Report the new fit after the frame.
  bool _layout(Size viewport, Size document) {
    final needsFit = !_initialized || document != _documentSize;
    final previousSize = _viewportSize;
    if (viewport == _viewportSize && document == _documentSize) return false;
    _viewportSize = viewport;
    _documentSize = document;
    if (needsFit) {
      _initialized = true;
      final margin = viewport.width < 600 ? 28.0 : 64.0;
      final fitted = math
          .min(
            math.max(1, viewport.width - margin * 2) / document.width,
            math.max(1, viewport.height - margin * 2) / document.height,
          )
          .clamp(.05, 8.0)
          .toDouble();
      _setView(
        fitted,
        viewport.center(Offset.zero) - document.center(Offset.zero) * fitted,
        notify: false,
      );
    } else {
      _origin +=
          viewport.center(Offset.zero) - previousSize.center(Offset.zero);
    }
    return true;
  }
}

class EditorViewport extends StatefulWidget {
  const EditorViewport({
    super.key,
    required this.controller,
    required this.viewportController,
    this.showGrid = false,
  });

  final EditorController controller;
  final ViewportController viewportController;
  final bool showGrid;

  @override
  State<EditorViewport> createState() => _EditorViewportState();
}

enum _Interaction {
  none,
  paint,
  pan,
  marquee,
  ellipseSelection,
  lasso,
  clickTool,
  gradient,
  shape,
  cloneSource,
  move,
  scale,
  rotate,
  text,
}

class _ToolPreview {
  const _ToolPreview(this.tool, this.start, this.end, {this.points = const []});
  final EditorTool tool;
  final Offset start;
  final Offset end;
  final List<Offset> points;
}

class _EditorViewportState extends State<EditorViewport>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ants = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  final FocusNode _focus = FocusNode(debugLabel: 'Photo canvas');
  final ValueNotifier<Offset?> _hover = ValueNotifier(null);
  final ValueNotifier<_ToolPreview?> _preview = ValueNotifier(null);
  final ValueNotifier<Offset?> _cloneCursor = ValueNotifier(null);
  final Map<int, Offset> _pointers = {};
  _Interaction _interaction = _Interaction.none;
  int? _primaryPointer;
  bool _spacePan = false;
  bool _pinching = false;
  bool _textDialogOpen = false;
  Offset _startPoint = Offset.zero;
  Offset _startDocument = Offset.zero;
  Offset _startOrigin = Offset.zero;
  Offset _startLayerOffset = Offset.zero;
  Offset _transformCenter = Offset.zero;
  double _startRotation = 0;
  double _startScale = 1;
  double _startAngle = 0;
  double _startDistance = 1;
  double _pinchZoom = 1;
  double _pinchDistance = 1;
  double _strokePressure = 1;
  Offset _pinchDocumentAnchor = Offset.zero;
  Path? _previousSelection;
  EditorSelectionKind? _previousSelectionKind;
  EditorTool _gestureTool = EditorTool.brush;
  final List<Offset> _lassoPoints = [];
  Offset? _strokeCloneSource;

  EditorController get editor => widget.controller;
  ViewportController get viewport => widget.viewportController;
  Rect get _documentRect => Offset.zero & editor.documentSize;

  @override
  void initState() {
    super.initState();
    editor.addListener(_syncAnimation);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant EditorViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != editor) {
      oldWidget.controller.removeListener(_syncAnimation);
      editor.addListener(_syncAnimation);
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (editor.selection != null && !editor.selection!.isEmpty) {
      if (!_ants.isAnimating) _ants.repeat();
    } else {
      _ants.stop();
    }
  }

  @override
  void dispose() {
    editor.removeListener(_syncAnimation);
    _cancelInteraction();
    _ants.dispose();
    _focus.dispose();
    _hover.dispose();
    _preview.dispose();
    _cloneCursor.dispose();
    super.dispose();
  }

  Offset _clipPoint(Offset point) => Offset(
    point.dx.clamp(0, editor.documentSize.width).toDouble(),
    point.dy.clamp(0, editor.documentSize.height).toDouble(),
  );

  double _pressure(PointerEvent event) {
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return 1;
    }
    if (event.pressureMax <= 0) return 1;
    return (event.pressure / event.pressureMax).clamp(.05, 1.0).toDouble();
  }

  void _pointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons & (kPrimaryMouseButton | kMiddleMouseButton) == 0) {
      return;
    }
    _focus.requestFocus();
    _pointers[event.pointer] = event.localPosition;
    _hover.value = event.kind == PointerDeviceKind.touch
        ? null
        : event.localPosition;

    if (_pointers.length > 1) {
      if (!_pinching) _cancelInteraction();
      _pinching = true;
      _initializePinch();
      setState(() {});
      return;
    }
    // Once a pinch ends, the remaining finger stays inert until it is lifted.
    if (_pinching) return;

    _primaryPointer = event.pointer;
    _startPoint = event.localPosition;
    _startDocument = viewport.viewportToDocument(_startPoint);
    _gestureTool = editor.tool;
    _startOrigin = viewport.pan;
    if (_spacePan ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.space,
        ) ||
        editor.tool == EditorTool.hand ||
        event.buttons & kMiddleMouseButton != 0) {
      _interaction = _Interaction.pan;
      setState(() {});
      return;
    }
    if (editor.isBusy) return;
    if (editor.tool == EditorTool.transform) {
      _beginTransform(event);
      return;
    }
    if (!_documentRect.contains(_startDocument)) return;

    switch (editor.tool) {
      case EditorTool.brush:
      case EditorTool.eraser:
      case EditorTool.cloneStamp:
        if (editor.activeLayer == null ||
            editor.activeLayer!.locked ||
            !editor.activeLayer!.visible) {
          return;
        }
        if (editor.tool == EditorTool.cloneStamp) {
          if (HardwareKeyboard.instance.isAltPressed ||
              editor.cloneSourcePickMode) {
            _interaction = _Interaction.cloneSource;
            return;
          }
          if (editor.cloneSource == null) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                content: Text('Alt 키를 누른 채 클릭하거나 원본 지정 버튼으로 복제할 위치를 선택하세요.'),
              ),
            );
            return;
          }
          _strokeCloneSource = editor.cloneSource;
          _cloneCursor.value = _strokeCloneSource;
        }
        _interaction = _Interaction.paint;
        _strokePressure = _pressure(event);
        editor.beginStroke(_startDocument, pressure: _strokePressure);
      case EditorTool.marquee:
      case EditorTool.ellipticalMarquee:
      case EditorTool.lasso:
        _previousSelection = editor.selectionPath;
        _previousSelectionKind = editor.selectionKind;
        if (editor.tool == EditorTool.lasso) {
          _interaction = _Interaction.lasso;
          _lassoPoints
            ..clear()
            ..add(_startDocument);
          editor.clearSelection();
          _updatePreview(_startDocument);
        } else if (editor.tool == EditorTool.ellipticalMarquee) {
          _interaction = _Interaction.ellipseSelection;
          editor.setEllipseSelection(
            Rect.fromPoints(_startDocument, _startDocument),
          );
        } else {
          _interaction = _Interaction.marquee;
          editor.setSelection(Rect.fromPoints(_startDocument, _startDocument));
        }
      case EditorTool.magicWand:
      case EditorTool.eyedropper:
      case EditorTool.fill:
        _interaction = _Interaction.clickTool;
      case EditorTool.gradient:
        _interaction = _Interaction.gradient;
        _updatePreview(_startDocument);
      case EditorTool.rectangle:
      case EditorTool.ellipse:
        _interaction = _Interaction.shape;
        _updatePreview(_startDocument);
      case EditorTool.transform:
        _beginTransform(event);
      case EditorTool.text:
        _interaction = _Interaction.text;
      case EditorTool.hand:
        break;
    }
  }

  void _updatePreview(Offset point) {
    _preview.value = _ToolPreview(
      _gestureTool,
      _startDocument,
      _clipPoint(point),
      points: List.of(_lassoPoints),
    );
  }

  void _appendLassoPoint(Offset point) {
    final clipped = _clipPoint(point);
    if (_lassoPoints.isEmpty ||
        (clipped - _lassoPoints.last).distance * viewport.zoom >= 1) {
      _lassoPoints.add(clipped);
      if (_lassoPoints.length >= 3) editor.setLassoSelection(_lassoPoints);
    }
    _updatePreview(clipped);
  }

  void _beginTransform(PointerDownEvent event) {
    final layer = editor.activeLayer;
    if (layer == null || layer.locked || !layer.visible) return;
    final shape = _transformShape(editor, viewport);
    final radius = event.kind == PointerDeviceKind.touch ? 28.0 : 17.0;
    final polygon = shape == null
        ? null
        : (Path()..addPolygon(shape.corners, true));
    // Small selections need a move target even when corner hit areas overlap.
    // Reserve the interior nearest the center; exact and outside corners retain
    // their larger mouse/touch resize targets.
    final preferMove =
        editor.selection != null &&
        shape != null &&
        polygon!.contains(event.localPosition) &&
        (event.localPosition - (shape.corners[0] + shape.corners[2]) / 2)
                .distance <
            shape.corners
                .map((point) => (point - event.localPosition).distance)
                .reduce(math.min);
    if (shape != null &&
        (shape.rotationHandle - event.localPosition).distance <= radius) {
      _interaction = _Interaction.rotate;
    } else if (!preferMove &&
        shape != null &&
        shape.corners.any(
          (point) => (point - event.localPosition).distance <= radius,
        )) {
      _interaction = _Interaction.scale;
    } else {
      if (polygon == null || !polygon.contains(event.localPosition)) {
        return;
      }
      _interaction = _Interaction.move;
    }
    _startLayerOffset = editor.activeTransformOffset;
    _startRotation = editor.activeTransformRotation;
    _startScale = editor.activeTransformScale;
    _transformCenter = editor.transformCenter;
    if (!editor.beginTransform()) {
      _interaction = _Interaction.none;
      return;
    }
    final relative = _startDocument - _transformCenter;
    _startAngle = math.atan2(relative.dy, relative.dx);
    _startDistance = math.max(1, relative.distance);
  }

  void _initializePinch() {
    if (_pointers.length < 2) return;
    final points = _pointers.values.take(2).toList();
    _pinchZoom = viewport.zoom;
    _pinchDistance = math.max(1, (points[1] - points[0]).distance);
    _pinchDocumentAnchor = viewport.viewportToDocument(
      (points[0] + points[1]) / 2,
    );
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    _hover.value = event.kind == PointerDeviceKind.touch
        ? null
        : event.localPosition;
    if (_pinching) {
      if (_pointers.length < 2) return;
      final points = _pointers.values.take(2).toList();
      final midpoint = (points[0] + points[1]) / 2;
      final zoom =
          (_pinchZoom * (points[1] - points[0]).distance / _pinchDistance)
              .clamp(.05, 8.0)
              .toDouble();
      viewport._setView(zoom, midpoint - _pinchDocumentAnchor * zoom);
      return;
    }
    if (event.pointer != _primaryPointer) return;
    if ((_interaction == _Interaction.move ||
            _interaction == _Interaction.scale ||
            _interaction == _Interaction.rotate) &&
        !editor.hasActiveTransform) {
      _cancelInteraction();
      return;
    }
    final point = viewport.viewportToDocument(event.localPosition);
    switch (_interaction) {
      case _Interaction.paint:
        _strokePressure = _pressure(event);
        editor.appendStroke(point, pressure: _strokePressure);
        if (_gestureTool == EditorTool.cloneStamp &&
            _strokeCloneSource != null) {
          _cloneCursor.value = _strokeCloneSource! + point - _startDocument;
        }
      case _Interaction.pan:
        viewport._setView(
          viewport.zoom,
          _startOrigin + event.localPosition - _startPoint,
        );
      case _Interaction.marquee:
        editor.setSelection(Rect.fromPoints(_startDocument, _clipPoint(point)));
      case _Interaction.ellipseSelection:
        editor.setEllipseSelection(
          Rect.fromPoints(_startDocument, _clipPoint(point)),
        );
      case _Interaction.lasso:
        _appendLassoPoint(point);
      case _Interaction.gradient:
      case _Interaction.shape:
        _updatePreview(point);
      case _Interaction.move:
        editor.setActiveTransform(
          offset: _startLayerOffset + point - _startDocument,
        );
      case _Interaction.scale:
        final scale =
            (_startScale * (point - _transformCenter).distance / _startDistance)
                .clamp(.05, 10.0)
                .toDouble();
        editor.setActiveTransform(scale: scale);
      case _Interaction.rotate:
        final relative = point - _transformCenter;
        var angle =
            _startRotation + math.atan2(relative.dy, relative.dx) - _startAngle;
        if (HardwareKeyboard.instance.isShiftPressed) {
          angle = (angle / (math.pi / 12)).round() * (math.pi / 12);
        }
        editor.setActiveTransform(rotation: angle);
      case _Interaction.none:
      case _Interaction.text:
      case _Interaction.clickTool:
      case _Interaction.cloneSource:
        break;
    }
  }

  void _pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_pinching) {
      if (_pointers.length >= 2) _initializePinch();
      if (_pointers.isEmpty) {
        _pinching = false;
        _primaryPointer = null;
        setState(() {});
      }
      return;
    }
    if (event.pointer != _primaryPointer) return;
    final completed = _interaction;
    final end = _clipPoint(viewport.viewportToDocument(event.localPosition));
    _interaction = _Interaction.none;
    _primaryPointer = null;
    switch (completed) {
      case _Interaction.paint:
        editor.appendStroke(
          viewport.viewportToDocument(event.localPosition),
          pressure: _strokePressure,
        );
        unawaited(_endStroke());
      case _Interaction.marquee:
        editor.setSelection(Rect.fromPoints(_startDocument, end));
        _finishSelection();
      case _Interaction.ellipseSelection:
        editor.setEllipseSelection(Rect.fromPoints(_startDocument, end));
        _finishSelection();
      case _Interaction.lasso:
        _appendLassoPoint(end);
        _finishSelection();
      case _Interaction.clickTool:
        if ((event.localPosition - _startPoint).distance <= 12) {
          unawaited(_applyClickTool(_gestureTool, _startDocument));
        }
      case _Interaction.cloneSource:
        if ((event.localPosition - _startPoint).distance <= 12) {
          editor.setCloneSource(_startDocument);
          editor.setCloneSourcePickMode(false);
        }
      case _Interaction.gradient:
        if ((end - _startDocument).distance * viewport.zoom >= 3) {
          unawaited(
            _runTool(
              () => editor.applyGradient(
                _startDocument,
                end,
                endColor: editor.secondaryColor,
              ),
            ),
          );
        }
      case _Interaction.shape:
        final bounds = Rect.fromPoints(_startDocument, end);
        if (bounds.width * viewport.zoom >= 2 &&
            bounds.height * viewport.zoom >= 2) {
          unawaited(
            _runTool(
              () => editor.drawShape(
                bounds,
                ellipse: _gestureTool == EditorTool.ellipse,
                filled: editor.shapeFilled,
              ),
            ),
          );
        }
      case _Interaction.move:
      case _Interaction.scale:
      case _Interaction.rotate:
        unawaited(_runTool(editor.commitTransform));
      case _Interaction.text:
        if ((event.localPosition - _startPoint).distance < 10) {
          unawaited(_editText(_startDocument));
        }
      case _Interaction.pan:
      case _Interaction.none:
        break;
    }
    _preview.value = null;
    _cloneCursor.value = null;
    setState(() {});
  }

  void _finishSelection() {
    final selection = editor.selection;
    if (selection != null && (selection.width < 1 || selection.height < 1)) {
      editor.clearSelection();
    }
  }

  Future<void> _applyClickTool(EditorTool tool, Offset point) =>
      _runTool(() async {
        switch (tool) {
          case EditorTool.magicWand:
            await editor.magicWand(point, tolerance: editor.magicWandTolerance);
          case EditorTool.eyedropper:
            await editor.sampleColor(point);
          case EditorTool.fill:
            await editor.floodFill(point, tolerance: editor.magicWandTolerance);
          default:
            break;
        }
      });

  Future<void> _runTool(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('도구 작업을 완료하지 못했습니다. 다시 시도해 주세요.')),
      );
    }
  }

  Future<void> _endStroke() async {
    try {
      await editor.endStroke();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('브러시 작업을 완료하지 못했습니다. 다시 시도해 주세요.')),
      );
    }
  }

  void _cancelInteraction() {
    switch (_interaction) {
      case _Interaction.paint:
        editor.cancelStroke();
      case _Interaction.marquee:
      case _Interaction.ellipseSelection:
      case _Interaction.lasso:
        editor.setSelectionPath(
          _previousSelection,
          kind: _previousSelectionKind,
        );
      case _Interaction.move:
      case _Interaction.scale:
      case _Interaction.rotate:
        editor.cancelTransform();
      default:
        break;
    }
    _interaction = _Interaction.none;
    _primaryPointer = null;
    _preview.value = null;
    _cloneCursor.value = null;
  }

  void _pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _cancelInteraction();
    if (_pointers.isEmpty) _pinching = false;
    setState(() {});
  }

  void _pointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _pointers.isNotEmpty) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      viewport.zoomAt(
        event.localPosition,
        viewport.zoom * math.exp(-event.scrollDelta.dy * .0018),
      );
    });
  }

  Future<void> _editText(Offset position) async {
    if (_textDialogOpen) return;
    _textDialogOpen = true;
    final layer = editor.activeLayer;
    final editing = layer != null && layer.isText;
    try {
      final result = await showDialog<_TextResult>(
        context: context,
        builder: (context) => _TextLayerDialog(
          initialText: editing ? layer.text ?? '' : '',
          initialSize: editing ? layer.fontSize : 84,
          editing: editing,
        ),
      );
      if (result == null || !mounted) return;
      if (editing && !result.createNew) {
        await editor.updateText(result.text, fontSize: result.fontSize);
      } else {
        await editor.addText(
          result.text,
          fontSize: result.fontSize,
          color: editor.brushColor,
          position: position,
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('텍스트를 적용하지 못했습니다. 다시 시도해 주세요.')),
      );
    } finally {
      _textDialogOpen = false;
    }
  }

  MouseCursor get _mouseCursor {
    if (_interaction == _Interaction.pan || _pinching) {
      return SystemMouseCursors.grabbing;
    }
    if (_spacePan || editor.tool == EditorTool.hand) {
      return SystemMouseCursors.grab;
    }
    return switch (editor.tool) {
      EditorTool.text => SystemMouseCursors.text,
      EditorTool.transform => SystemMouseCursors.move,
      _ => SystemMouseCursors.precise,
    };
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([editor, viewport]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (viewport._layout(size, editor.documentSize)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) viewport._reportLayout();
            });
          }
          return Focus(
            focusNode: _focus,
            onFocusChange: (focused) {
              if (!focused && _spacePan) setState(() => _spacePan = false);
            },
            onKeyEvent: (_, event) {
              if (event.logicalKey == LogicalKeyboardKey.space) {
                setState(() => _spacePan = event is! KeyUpEvent);
                return KeyEventResult.handled;
              }
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                final wasTransforming =
                    _interaction == _Interaction.move ||
                    _interaction == _Interaction.scale ||
                    _interaction == _Interaction.rotate;
                _cancelInteraction();
                if (!wasTransforming) editor.clearSelection();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Semantics(
              label: '사진 편집 캔버스. 마우스 휠로 확대하고 두 손가락으로 이동합니다.',
              child: ClipRect(
                child: MouseRegion(
                  cursor: _mouseCursor,
                  onHover: (event) => _hover.value = event.localPosition,
                  onExit: (_) => _hover.value = null,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _pointerDown,
                    onPointerMove: _pointerMove,
                    onPointerUp: _pointerUp,
                    onPointerCancel: _pointerCancel,
                    onPointerSignal: _pointerSignal,
                    onPointerPanZoomStart: (_) {
                      _cancelInteraction();
                      _startOrigin = viewport.pan;
                      _pinchZoom = viewport.zoom;
                    },
                    onPointerPanZoomUpdate: (event) {
                      final zoom = (_pinchZoom * event.scale)
                          .clamp(.05, 8.0)
                          .toDouble();
                      final anchor =
                          (event.localPosition - _startOrigin) / _pinchZoom;
                      viewport._setView(
                        zoom,
                        event.localPosition + event.pan - anchor * zoom,
                      );
                    },
                    child: RepaintBoundary(
                      child: CustomPaint(
                        size: size,
                        painter: _ViewportPainter(
                          editor: editor,
                          viewport: viewport,
                          ants: _ants,
                          hover: _hover,
                          preview: _preview,
                          cloneCursor: _cloneCursor,
                          showGrid: widget.showGrid,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TransformShape {
  const _TransformShape(this.corners, this.rotationHandle);
  final List<Offset> corners;
  final Offset rotationHandle;
}

_TransformShape? _transformShape(
  EditorController editor,
  ViewportController viewport,
) {
  final layer = editor.activeLayer;
  if (layer == null || !layer.visible) return null;
  final rect = editor.transformBounds;
  if (rect.isEmpty) return null;
  final corners =
      [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]
          .map(
            (point) =>
                viewport.documentToViewport(editor.transformPoint(point)),
          )
          .toList();
  final top = (corners[0] + corners[1]) / 2;
  final center = (corners[0] + corners[2]) / 2;
  final vector = top - center;
  final direction = vector.distance > 0
      ? vector / vector.distance
      : const Offset(0, -1);
  return _TransformShape(corners, top + direction * 34);
}

class _ViewportPainter extends CustomPainter {
  _ViewportPainter({
    required this.editor,
    required this.viewport,
    required this.ants,
    required this.hover,
    required this.preview,
    required this.cloneCursor,
    required this.showGrid,
  }) : super(
         repaint: Listenable.merge([
           editor,
           viewport,
           ants,
           hover,
           preview,
           cloneCursor,
         ]),
       );

  final EditorController editor;
  final ViewportController viewport;
  final Animation<double> ants;
  final ValueNotifier<Offset?> hover;
  final ValueNotifier<_ToolPreview?> preview;
  final ValueNotifier<Offset?> cloneCursor;
  final bool showGrid;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xFFEEF0F4), BlendMode.src);
    final paper = Rect.fromLTWH(
      viewport.pan.dx,
      viewport.pan.dy,
      editor.documentSize.width * viewport.zoom,
      editor.documentSize.height * viewport.zoom,
    );
    canvas.drawShadow(
      Path()..addRect(paper),
      const Color(0x320C1427),
      12,
      false,
    );
    canvas.save();
    canvas.clipRect(paper);
    canvas.drawRect(paper, Paint()..color = Colors.white);
    final visible = paper.intersect(Offset.zero & size);
    if (!visible.isEmpty) {
      const cell = 10.0;
      final startX = ((visible.left - paper.left) / cell).floor();
      final startY = ((visible.top - paper.top) / cell).floor();
      final endX = ((visible.right - paper.left) / cell).ceil();
      final endY = ((visible.bottom - paper.top) / cell).ceil();
      final checker = Paint()..color = const Color(0xFFF0F1F5);
      for (var y = startY; y < endY; y++) {
        for (var x = startX; x < endX; x++) {
          if ((x + y).isEven) {
            canvas.drawRect(
              Rect.fromLTWH(
                paper.left + x * cell,
                paper.top + y * cell,
                cell,
                cell,
              ),
              checker,
            );
          }
        }
      }
    }
    canvas.translate(viewport.pan.dx, viewport.pan.dy);
    canvas.scale(viewport.zoom);
    editor.paintDocument(canvas);
    _paintToolPreview(canvas);
    if (showGrid) {
      var step = 100.0;
      while (step * viewport.zoom < 28) {
        step *= 2;
      }
      final grid = Paint()
        ..color = const Color(0x286C7290)
        ..strokeWidth = 1 / viewport.zoom;
      for (var x = step; x < editor.documentSize.width; x += step) {
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, editor.documentSize.height),
          grid,
        );
      }
      for (var y = step; y < editor.documentSize.height; y += step) {
        canvas.drawLine(
          Offset(0, y),
          Offset(editor.documentSize.width, y),
          grid,
        );
      }
    }
    canvas.restore();
    canvas.drawRect(
      paper,
      Paint()
        ..color = const Color(0x180D1733)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final selection = editor.selectionPath;
    if (selection != null) {
      canvas.save();
      canvas.clipRect(paper.inflate(1));
      final path = _screenPath(selection);
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      _drawDashes(canvas, path, ants.value * 12);
      canvas.restore();
    }
    if (editor.tool == EditorTool.transform) _paintTransform(canvas);
    _paintGradientGuide(canvas);
    _paintCloneSource(canvas);
    if (size.width >= 720) _paintRulers(canvas, size);
    _paintBrushCursor(canvas, paper);
  }

  Path _screenPath(Path path) => path.transform(
    Float64List.fromList([
      viewport.zoom,
      0,
      0,
      0,
      0,
      viewport.zoom,
      0,
      0,
      0,
      0,
      1,
      0,
      viewport.pan.dx,
      viewport.pan.dy,
      0,
      1,
    ]),
  );

  void _paintToolPreview(Canvas canvas) {
    final value = preview.value;
    if (value == null) return;
    if (value.tool == EditorTool.lasso) {
      if (value.points.length < 2) return;
      final path = Path()..addPolygon(value.points, false);
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF7865E9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / viewport.zoom,
      );
      return;
    }
    final color = editor.brushColor.withValues(
      alpha: editor.brushColor.a * editor.brushOpacity * .75,
    );
    canvas.save();
    final selection = editor.selectionPath;
    if (selection != null) canvas.clipPath(selection);
    if (value.tool == EditorTool.gradient) {
      if ((value.end - value.start).distance > .01) {
        canvas.drawRect(
          Offset.zero & editor.documentSize,
          Paint()
            ..shader = ui.Gradient.linear(value.start, value.end, [
              color,
              editor.secondaryColor.withValues(
                alpha: editor.secondaryColor.a * editor.brushOpacity * .75,
              ),
            ]),
        );
      }
    } else if (value.tool == EditorTool.rectangle ||
        value.tool == EditorTool.ellipse) {
      final rect = Rect.fromPoints(value.start, value.end);
      final paint = Paint()
        ..color = color
        ..style = editor.shapeFilled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = editor.brushSize;
      if (value.tool == EditorTool.ellipse) {
        canvas.drawOval(rect, paint);
      } else {
        canvas.drawRect(rect, paint);
      }
    }
    canvas.restore();
  }

  void _paintGradientGuide(Canvas canvas) {
    final value = preview.value;
    if (value == null || value.tool != EditorTool.gradient) return;
    final start = viewport.documentToViewport(value.start);
    final end = viewport.documentToViewport(value.end);
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 3,
    );
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = const Color(0xFF7865E9)
        ..strokeWidth = 1.5,
    );
    for (final point in [start, end]) {
      canvas.drawCircle(point, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        point,
        5,
        Paint()
          ..color = const Color(0xFF7865E9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  void _paintCloneSource(Canvas canvas) {
    if (editor.tool != EditorTool.cloneStamp || editor.cloneSource == null) {
      return;
    }
    final source = viewport.documentToViewport(
      cloneCursor.value ?? editor.cloneSource!,
    );
    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final accent = Paint()
      ..color = const Color(0xFF7865E9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final paint in [white, accent]) {
      canvas.drawCircle(source, 7, paint);
      canvas.drawLine(
        source - const Offset(11, 0),
        source + const Offset(11, 0),
        paint,
      );
      canvas.drawLine(
        source - const Offset(0, 11),
        source + const Offset(0, 11),
        paint,
      );
    }
  }

  void _paintTransform(Canvas canvas) {
    final shape = _transformShape(editor, viewport);
    if (shape == null) return;
    final color = editor.activeLayer!.locked
        ? const Color(0xFF9298A8)
        : const Color(0xFF6C5CE7);
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final path = Path()..addPolygon(shape.corners, true);
    canvas.drawPath(path, line);
    final top = (shape.corners[0] + shape.corners[1]) / 2;
    canvas.drawLine(top, shape.rotationHandle, line);
    for (final point in shape.corners) {
      final handle = RRect.fromRectAndRadius(
        Rect.fromCenter(center: point, width: 10, height: 10),
        const Radius.circular(2),
      );
      canvas.drawRRect(handle, Paint()..color = Colors.white);
      canvas.drawRRect(handle, line);
    }
    canvas.drawCircle(shape.rotationHandle, 6, Paint()..color = Colors.white);
    canvas.drawCircle(shape.rotationHandle, 6, line);
  }

  void _paintBrushCursor(Canvas canvas, Rect paper) {
    final point = hover.value;
    if (point == null ||
        !paper.contains(point) ||
        (editor.tool != EditorTool.brush &&
            editor.tool != EditorTool.eraser &&
            (editor.tool != EditorTool.cloneStamp ||
                editor.cloneSourcePickMode))) {
      return;
    }
    final radius = math.max(2.0, editor.brushSize * viewport.zoom / 2);
    canvas.drawCircle(
      point,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: .9),
    );
    canvas.drawCircle(
      point,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xB330374A),
    );
  }

  void _paintRulers(Canvas canvas, Size size) {
    const thickness = 22.0;
    final fill = Paint()..color = const Color(0xFFF8F9FB);
    final line = Paint()
      ..color = const Color(0xFFD6DAE3)
      ..strokeWidth = 1;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, thickness), fill);
    canvas.drawRect(Rect.fromLTWH(0, 0, thickness, size.height), fill);
    canvas.drawLine(
      const Offset(0, thickness),
      Offset(size.width, thickness),
      line,
    );
    canvas.drawLine(
      const Offset(thickness, 0),
      Offset(thickness, size.height),
      line,
    );
    var step = 100.0;
    while (step * viewport.zoom < 58) {
      step *= 2;
    }
    while (step * viewport.zoom > 160) {
      step /= 2;
    }
    void ticks(bool vertical) {
      final origin = vertical ? viewport.pan.dy : viewport.pan.dx;
      final extent = vertical ? size.height : size.width;
      final start = ((thickness - origin) / (step * viewport.zoom)).floor();
      final end = ((extent - origin) / (step * viewport.zoom)).ceil();
      for (var tick = start; tick <= end; tick++) {
        final position = origin + tick * step * viewport.zoom;
        if (position < thickness) continue;
        canvas.drawLine(
          vertical ? Offset(16, position) : Offset(position, 16),
          vertical ? Offset(22, position) : Offset(position, 22),
          line,
        );
        final text = TextPainter(
          text: TextSpan(
            text: (tick * step).round().toString(),
            style: const TextStyle(fontSize: 9, color: Color(0xFF9CA3B3)),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        if (vertical) {
          canvas.save();
          canvas.translate(5, position - 4);
          canvas.rotate(-math.pi / 2);
          text.paint(canvas, Offset.zero);
          canvas.restore();
        } else {
          text.paint(canvas, Offset(position + 4, 4));
        }
        text.dispose();
      }
    }

    ticks(false);
    ticks(true);
    canvas.drawRect(const Rect.fromLTWH(0, 0, thickness, thickness), fill);
  }

  void _drawDashes(Canvas canvas, Path path, double phase) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (var start = -phase; start < metric.length; start += 12) {
        final from = math.max(0.0, start);
        final to = math.min(metric.length, start + 6);
        if (to > from) canvas.drawPath(metric.extractPath(from, to), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ViewportPainter oldDelegate) =>
      editor != oldDelegate.editor ||
      viewport != oldDelegate.viewport ||
      showGrid != oldDelegate.showGrid;
}

class _TextResult {
  const _TextResult(this.text, this.fontSize, this.createNew);
  final String text;
  final double fontSize;
  final bool createNew;
}

class _TextLayerDialog extends StatefulWidget {
  const _TextLayerDialog({
    required this.initialText,
    required this.initialSize,
    required this.editing,
  });
  final String initialText;
  final double initialSize;
  final bool editing;

  @override
  State<_TextLayerDialog> createState() => _TextLayerDialogState();
}

class _TextLayerDialogState extends State<_TextLayerDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialText,
  );
  late final TextEditingController _size = TextEditingController(
    text: widget.initialSize.round().toString(),
  );
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    _size.dispose();
    super.dispose();
  }

  void _submit(bool createNew) {
    final size = double.tryParse(_size.text);
    if (_text.text.trim().isEmpty || size == null || size < 8 || size > 800) {
      setState(() => _error = '텍스트와 8~800 사이의 크기를 입력해 주세요.');
      return;
    }
    Navigator.pop(context, _TextResult(_text.text.trim(), size, createNew));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing ? '텍스트 편집' : '텍스트 추가'),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '텍스트',
              hintText: '나만의 이야기를 담아 보세요',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _size,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '글자 크기',
              suffixText: 'px',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      if (widget.editing)
        TextButton(
          onPressed: () => _submit(true),
          child: const Text('새 레이어로 추가'),
        ),
      FilledButton(
        onPressed: () => _submit(!widget.editing),
        child: Text(widget.editing ? '변경 적용' : '추가'),
      ),
    ],
  );
}
