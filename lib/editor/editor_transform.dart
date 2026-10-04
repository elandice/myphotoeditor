part of 'editor_controller.dart';

/// The selection is cut from the active layer only. A session keeps immutable
/// source images for synchronous previews and rasterizes once on commit.
extension EditorTransforms on EditorController {
  bool get hasActiveTransform => _transform != null;
  bool get isTransformingSelection => _transform?.path != null;

  Offset get activeTransformOffset =>
      _transform?.offset ??
      (_selectionPath == null
          ? activeLayer?.offset ?? Offset.zero
          : Offset.zero);
  double get activeTransformRotation =>
      _transform?.rotation ??
      (_selectionPath == null ? activeLayer?.rotation ?? 0 : 0);
  double get activeTransformScale =>
      _transform?.scale ??
      (_selectionPath == null ? activeLayer?.scale ?? 1 : 1);

  Rect get transformBounds =>
      _transform?.bounds ??
      _selectionPath?.getBounds() ??
      (Offset.zero & documentSize);
  Offset get transformCenter => transformPoint(transformBounds.center);

  Offset transformPoint(Offset point) {
    final transform = _transform;
    if (transform?.path != null) {
      final center = transform!.bounds.center;
      final relative = (point - center) * transform.scale;
      final c = math.cos(transform.rotation), s = math.sin(transform.rotation);
      return center +
          transform.offset +
          Offset(
            relative.dx * c - relative.dy * s,
            relative.dx * s + relative.dy * c,
          );
    }
    if (_selectionPath != null) return point;
    final layer = activeLayer;
    return layer == null ? point : layerToDocument(point, layer);
  }

  bool beginTransform() {
    final layer = activeLayer;
    if (!_canStartOperation ||
        layer == null ||
        layer.locked ||
        !layer.visible) {
      return false;
    }
    if (_transform != null) return true;
    commitTransaction();
    final path = selectionPath;
    beginTransaction(path == null ? '레이어 변형' : '선택 영역 변형');
    _transform = _TransformSession(
      layer,
      path,
      path?.getBounds() ?? (Offset.zero & documentSize),
    );
    // A settled GPU composite must never hide a transient cut-and-move preview.
    _contentChanged();
    return true;
  }

  void setActiveTransform({Offset? offset, double? rotation, double? scale}) {
    if (_busy || _disposed) return;
    EditorProjectSchema.validateTransform(
      offset: offset,
      rotation: rotation,
      scale: scale,
    );
    if (_transform == null && !beginTransform()) return;
    final transform = _transform!;
    transform.offset = offset ?? transform.offset;
    transform.rotation = rotation ?? transform.rotation;
    transform.scale = scale?.clamp(.05, 10) ?? transform.scale;
    if (transform.path != null) {
      _selectionPath = transform.path!.transform(
        _selectionTransformMatrix(transform),
      );
      _selection = _selectionPath!.getBounds();
      _transactionChanged = !transform.isIdentity;
    } else {
      final index = _layers.indexWhere(
        (layer) => layer.id == transform.layer.id,
      );
      if (index < 0) {
        cancelTransform();
        return;
      }
      _layers[index] = transform.layer.copyWith(
        offset: transform.offset,
        rotation: transform.rotation,
        scale: transform.scale,
      );
      _transactionChanged =
          transform.offset != transform.layer.offset ||
          transform.rotation != transform.layer.rotation ||
          transform.scale != transform.layer.scale;
    }
    _contentChanged();
  }

  Float64List _selectionTransformMatrix(_TransformSession transform) {
    final center = transform.bounds.center;
    final c = math.cos(transform.rotation) * transform.scale,
        s = math.sin(transform.rotation) * transform.scale;
    return Float64List.fromList([
      c,
      s,
      0,
      0,
      -s,
      c,
      0,
      0,
      0,
      0,
      1,
      0,
      center.dx + transform.offset.dx - c * center.dx + s * center.dy,
      center.dy + transform.offset.dy - s * center.dx - c * center.dy,
      0,
      1,
    ]);
  }

  void _paintRawLayerInDocument(
    Canvas canvas,
    EditorLayer layer, {
    bool maskOnly = false,
  }) {
    canvas.save();
    final center = documentSize.center(Offset.zero);
    canvas.translate(center.dx + layer.offset.dx, center.dy + layer.offset.dy);
    canvas.rotate(layer.rotation);
    canvas.scale(layer.scale);
    canvas.translate(-center.dx, -center.dy);
    if (maskOnly) {
      canvas.drawImage(layer.mask!, Offset.zero, Paint());
    } else {
      canvas.saveLayer(Offset.zero & documentSize, Paint());
      paintLayerContent(canvas, layer, includeStroke: false);
      canvas.restore();
    }
    canvas.restore();
  }

  void _paintSelectionTransform(
    Canvas canvas,
    _TransformSession transform, {
    bool maskOnly = false,
  }) {
    if (transform.isIdentity) {
      _paintRawLayerInDocument(canvas, transform.layer, maskOnly: maskOnly);
      return;
    }
    final path = transform.path!;
    // Cut on an isolated surface rather than an inverse path clip. Clearing
    // must affect this layer only, so lower layers remain visible through the
    // source hole on both native Skia and the web CanvasKit renderer.
    canvas.saveLayer(Offset.zero & documentSize, Paint());
    _paintRawLayerInDocument(canvas, transform.layer, maskOnly: maskOnly);
    canvas.drawPath(path, Paint()..blendMode = ui.BlendMode.clear);
    canvas.restore();
    canvas.save();
    canvas.transform(_selectionTransformMatrix(transform));
    canvas.clipPath(path);
    _paintRawLayerInDocument(canvas, transform.layer, maskOnly: maskOnly);
    canvas.restore();
  }

  Future<void> commitTransform() async {
    final transform = _transform;
    if (transform == null || _busy || _disposed) return;
    if (!_transactionChanged || transform.path == null) {
      if (_transactionChanged) _documentChanged();
      _transform = null;
      commitTransaction();
      _contentChanged();
      return;
    }
    _busy = true;
    _notify();
    ui.Image? image, mask;
    try {
      image = await _raster(
        (canvas) => _paintSelectionTransform(canvas, transform),
      );
      // Disabled masks stay editable, in the new document-space coordinates.
      if (transform.layer.mask != null && !transform.layer.maskEnabled) {
        mask = await _raster(
          (canvas) =>
              _paintSelectionTransform(canvas, transform, maskOnly: true),
        );
      }
      if (_disposed || _transform != transform) return;
      final index = _layers.indexWhere(
        (layer) => layer.id == transform.layer.id,
      );
      if (index < 0) {
        cancelTransform();
        return;
      }
      final result = transform.layer.copyWith(
        image: image,
        offset: Offset.zero,
        rotation: 0,
        scale: 1,
        clearText: true,
        clearMask: mask == null,
        mask: mask,
      );
      _images.add(image);
      if (mask != null) _images.add(mask);
      image = null;
      mask = null;
      _layers[index] = result;
      _documentChanged();
      _transform = null;
      _contentChanged();
      commitTransaction();
    } catch (_) {
      if (_transform == transform) cancelTransform();
      rethrow;
    } finally {
      image?.dispose();
      mask?.dispose();
      _busy = false;
      _notify();
    }
  }

  void cancelTransform() {
    if (_transform == null) return;
    cancelTransaction();
    _notify();
  }
}

class _TransformSession {
  _TransformSession(this.layer, this.path, this.bounds)
    : offset = path == null ? layer.offset : Offset.zero,
      rotation = path == null ? layer.rotation : 0,
      scale = path == null ? layer.scale : 1;
  final EditorLayer layer;
  final Path? path;
  final Rect bounds;
  Offset offset;
  double rotation;
  double scale;
  bool get isIdentity => offset == Offset.zero && rotation == 0 && scale == 1;
}
