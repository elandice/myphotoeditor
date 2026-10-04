part of 'editor_controller.dart';

extension EditorOperations on EditorController {
  void setSecondaryColor(Color color) {
    _secondaryColor = color;
    _notify();
  }

  void setShapeFilled(bool value) {
    _shapeFilled = value;
    _notify();
  }

  void setMagicWandTolerance(double value) {
    _magicWandTolerance = value.clamp(0, 1);
    _notify();
  }

  void setCloneSourcePickMode(bool value) {
    _cloneSourcePickMode = value;
    _notify();
  }

  void setCloneSource(Offset point) {
    if ((Offset.zero & documentSize).contains(point)) _cloneSource = point;
    _cloneSourcePickMode = false;
    _notify();
  }

  void setSelectionPath(Path? path, {EditorSelectionKind? kind}) {
    if (!_prepareOperation()) return;
    final bounds = Offset.zero & documentSize;
    final clipped = path == null
        ? null
        : Path.combine(PathOperation.intersect, path, Path()..addRect(bounds));
    _selectionPath = clipped == null || clipped.getBounds().isEmpty
        ? null
        : clipped;
    _selection = _selectionPath?.getBounds();
    _selectionKind = _selectionPath == null
        ? null
        : kind ?? EditorSelectionKind.lasso;
    _notify();
  }

  void setEllipseSelection(Rect rect) => setSelectionPath(
    Path()..addOval(rect),
    kind: EditorSelectionKind.ellipse,
  );
  void setLassoSelection(List<Offset> points) => setSelectionPath(
    points.length < 3 ? null : (Path()..addPolygon(points, true)),
    kind: EditorSelectionKind.lasso,
  );
  void selectAll() => setSelection(Offset.zero & documentSize);
  void invertSelection() {
    if (!_prepareOperation()) return;
    setSelectionPath(
      _selectionPath == null
          ? (Path()..addRect(Offset.zero & documentSize))
          : Path.combine(
              PathOperation.difference,
              Path()..addRect(Offset.zero & documentSize),
              _selectionPath!,
            ),
      kind: EditorSelectionKind.inverted,
    );
  }

  Float64List _inverseLayerMatrix(EditorLayer layer) {
    final center = documentSize.center(Offset.zero);
    final c = math.cos(layer.rotation) / layer.scale,
        s = math.sin(layer.rotation) / layer.scale;
    final origin = center + layer.offset;
    return Float64List.fromList([
      c,
      -s,
      0,
      0,
      s,
      c,
      0,
      0,
      0,
      0,
      1,
      0,
      center.dx - c * origin.dx - s * origin.dy,
      center.dy + s * origin.dx - c * origin.dy,
      0,
      1,
    ]);
  }

  Path _documentPathToLayer(Path path, EditorLayer layer) =>
      path.transform(_inverseLayerMatrix(layer));

  Future<void> _drawOnActive(String label, void Function(Canvas) draw) async {
    if (!_prepareOperation(settleTransaction: true)) return;
    final layer = activeLayer;
    if (_busy ||
        _disposed ||
        layer == null ||
        layer.locked ||
        !layer.visible ||
        _stroke != null) {
      return;
    }
    _busy = true;
    _notify();
    try {
      final image = await _raster((canvas) {
        canvas.drawImage(layer.image, Offset.zero, Paint());
        canvas.save();
        canvas.transform(_inverseLayerMatrix(layer));
        canvas.clipRect(Offset.zero & documentSize);
        if (_selectionPath != null) canvas.clipPath(_selectionPath!);
        draw(canvas);
        canvas.restore();
      });
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      _edit(label, () {
        final index = _layers.indexWhere((item) => item.id == layer.id);
        _layers[index] = layer.copyWith(image: image, clearText: true);
      });
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> fillSelection({Color? color}) => _drawOnActive(
    '색상 채우기',
    (canvas) => canvas.drawRect(
      Offset.zero & documentSize,
      Paint()
        ..color = (color ?? brushColor).withValues(
          alpha: (color ?? brushColor).a * brushOpacity,
        ),
    ),
  );
  Future<void> deleteSelection() => _drawOnActive(
    '선택 영역 삭제',
    (canvas) => canvas.drawRect(
      Offset.zero & documentSize,
      Paint()..blendMode = ui.BlendMode.clear,
    ),
  );
  Future<void> applyGradient(Offset start, Offset end, {Color? endColor}) {
    if ((end - start).distance < .5) return Future.value();
    return _drawOnActive(
      '그라디언트',
      (canvas) => canvas.drawRect(
        Offset.zero & documentSize,
        Paint()
          ..shader = ui.Gradient.linear(start, end, [
            brushColor.withValues(alpha: brushColor.a * brushOpacity),
            (endColor ?? secondaryColor).withValues(
              alpha: (endColor ?? secondaryColor).a * brushOpacity,
            ),
          ]),
      ),
    );
  }

  Future<void> drawShape(
    Rect rect, {
    required bool ellipse,
    bool filled = true,
  }) => _drawOnActive(ellipse ? '타원 도형' : '사각형 도형', (canvas) {
    final paint = Paint()
      ..color = brushColor.withValues(alpha: brushColor.a * brushOpacity)
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = brushSize;
    if (ellipse) {
      canvas.drawOval(rect, paint);
    } else {
      canvas.drawRect(rect, paint);
    }
  });

  Future<Uint8List> _compositePixels() async {
    final image = await _raster(
      (canvas) => paintDocument(canvas, includeStroke: false),
    );
    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) throw StateError('픽셀을 읽을 수 없습니다.');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  Future<Color?> sampleColor(Offset point) async {
    if (!_prepareOperation(settleTransaction: true) ||
        !(Offset.zero & documentSize).contains(point)) {
      return null;
    }
    _busy = true;
    _notify();
    try {
      final pixels = await _compositePixels();
      if (_disposed) return null;
      final index =
          (point.dy.floor() * documentSize.width.toInt() + point.dx.floor()) *
          4;
      final color = Color.fromARGB(
        pixels[index + 3],
        pixels[index],
        pixels[index + 1],
        pixels[index + 2],
      );
      setBrushColor(color);
      return color;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<Path?> _regionAt(Offset point, double tolerance) async {
    if (!(Offset.zero & documentSize).contains(point)) return null;
    final args = <String, Object>{
      'pixels': await _compositePixels(),
      'width': documentSize.width.toInt(),
      'height': documentSize.height.toInt(),
      'x': point.dx.floor(),
      'y': point.dy.floor(),
      'tolerance': tolerance.clamp(0, 1),
    };
    final workerResult = await connectedColorRegionWeb(args);
    final List<int> spans;
    if (workerResult != null) {
      spans = workerResult;
    } else {
      spans = await compute<Map<String, Object>, List<int>>(
        _connectedColorRegion,
        args,
      );
    }
    final path = Path();
    // Merge identical scanlines into tall rectangles to keep ants and clipping
    // compact for broad flat regions instead of creating one contour per pixel.
    final sorted = <(int, int, int)>[];
    for (var i = 0; i < spans.length; i += 3) {
      sorted.add((spans[i], spans[i + 1], spans[i + 2]));
    }
    sorted.sort(
      (a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1),
    );
    final runs = <String, Rect>{};
    for (final span in sorted) {
      final key = '${span.$1}:${span.$3}';
      final old = runs[key];
      if (old != null && old.bottom == span.$2) {
        runs[key] = Rect.fromLTRB(old.left, old.top, old.right, span.$2 + 1);
      } else {
        if (old != null) path.addRect(old);
        runs[key] = Rect.fromLTWH(
          span.$1.toDouble(),
          span.$2.toDouble(),
          span.$3.toDouble(),
          1,
        );
      }
    }
    for (final rect in runs.values) {
      path.addRect(rect);
    }
    // Simplify touching scanline rectangles to their external boundary.
    return Path.combine(PathOperation.union, path, Path());
  }

  Future<void> magicWand(Offset point, {double tolerance = .12}) async {
    if (!_prepareOperation(settleTransaction: true)) return;
    _busy = true;
    _notify();
    try {
      final path = await _regionAt(point, tolerance);
      if (!_disposed && path != null) {
        _selectionPath = path;
        _selection = path.getBounds().isEmpty ? null : path.getBounds();
        _selectionKind = _selection == null
            ? null
            : EditorSelectionKind.magicWand;
        _notify();
      }
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> floodFill(Offset point, {double tolerance = .12}) async {
    if (!_prepareOperation(settleTransaction: true)) return;
    if (_busy || activeLayer == null || activeLayer!.locked || _disposed) {
      return;
    }
    _busy = true;
    _notify();
    Path? region;
    try {
      region = await _regionAt(point, tolerance);
    } finally {
      _busy = false;
      _notify();
    }
    if (region == null || _disposed) return;
    final path = region;
    await _drawOnActive('페인트 통 채우기', (canvas) {
      canvas.clipPath(path);
      canvas.drawRect(
        Offset.zero & documentSize,
        Paint()
          ..color = brushColor.withValues(alpha: brushColor.a * brushOpacity),
      );
    });
  }

  Future<void> copySelection() async {
    if (!_prepareOperation(settleTransaction: true)) return;
    final layer = activeLayer;
    if (_busy || layer == null || _disposed || _stroke != null) return;
    _busy = true;
    _notify();
    try {
      final image = await _raster((canvas) {
        if (_selectionPath != null) canvas.clipPath(_selectionPath!);
        _paintLayer(canvas, layer, applyComposite: false);
      });
      if (_disposed) {
        image.dispose();
        return;
      }
      _clipboard = image;
      _images.add(image);
      _pruneHistory();
      _notify();
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> cutSelection() async {
    if (activeLayer?.locked ?? true) return;
    await copySelection();
    await deleteSelection();
  }

  Future<void> pasteSelection() async {
    if (!_prepareOperation(settleTransaction: true)) return;
    final clipboard = _clipboard;
    if (_busy || clipboard == null || _disposed) return;
    _validateAdditionalLayers(layers: 1);
    _busy = true;
    _notify();
    try {
      final image = await _raster(
        (canvas) => canvas.drawImage(clipboard, Offset.zero, Paint()),
      );
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      final layer = EditorLayer(id: _id(), name: '복사한 영역', image: image);
      _edit('붙여넣기', () {
        _layers.add(layer);
        _activeLayerId = layer.id;
      });
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> createMaskFromSelection() async {
    if (!_prepareOperation(settleTransaction: true)) return;
    final layer = activeLayer;
    if (_busy || layer == null || layer.locked || _selectionPath == null) {
      return;
    }
    _validateAdditionalLayers(masks: layer.mask == null ? 1 : 0);
    _busy = true;
    _notify();
    try {
      final image = await _raster(
        (canvas) => canvas.drawPath(
          _documentPathToLayer(_selectionPath!, layer),
          Paint()..color = Colors.white,
        ),
      );
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      _edit('선택 영역으로 마스크', () {
        _layers[_layers.indexOf(layer)] = layer.copyWith(
          mask: image,
          maskEnabled: true,
        );
      });
    } finally {
      _busy = false;
      _notify();
    }
  }

  void removeActiveMask() {
    if (_activeLayerId != null) {
      _replaceLayer(
        _activeLayerId!,
        (layer) => layer.copyWith(clearMask: true),
        '마스크 제거',
      );
    }
  }

  void toggleActiveMask() {
    if (_activeLayerId != null && activeLayer?.mask != null) {
      _replaceLayer(
        _activeLayerId!,
        (layer) => layer.copyWith(maskEnabled: !layer.maskEnabled),
        '마스크 표시',
      );
    }
  }

  Future<void> invertActiveMask() async {
    if (!_prepareOperation(settleTransaction: true)) return;
    final layer = activeLayer;
    if (_busy || layer == null || layer.mask == null || layer.locked) return;
    _busy = true;
    _notify();
    try {
      final image = await _raster((canvas) {
        canvas.drawRect(
          Offset.zero & documentSize,
          Paint()..color = Colors.white,
        );
        canvas.drawImage(
          layer.mask!,
          Offset.zero,
          Paint()..blendMode = ui.BlendMode.dstOut,
        );
      });
      if (_disposed) {
        image.dispose();
        return;
      }
      _images.add(image);
      _edit('마스크 반전', () {
        _layers[_layers.indexOf(layer)] = layer.copyWith(mask: image);
      });
    } finally {
      _busy = false;
      _notify();
    }
  }
}

/// Scanline flood selection on the visible composite, including alpha.
List<int> _connectedColorRegion(Map<String, Object> args) {
  final data = args['pixels'] as Uint8List,
      width = args['width'] as int,
      height = args['height'] as int;
  final sx = args['x'] as int,
      sy = args['y'] as int,
      tolerance = args['tolerance'] as double;
  final seed = (sy * width + sx) * 4;
  final visited = Uint8List(width * height),
      stack = <int>[sy * width + sx],
      spans = <int>[];
  final limit = tolerance * 255;
  bool match(int x, int y) {
    if (x < 0 ||
        y < 0 ||
        x >= width ||
        y >= height ||
        visited[y * width + x] != 0) {
      return false;
    }
    final i = (y * width + x) * 4;
    if ((data[i + 3] - data[seed + 3]).abs() > limit) return false;
    if (data[i + 3] == 0 && data[seed + 3] == 0) return true;
    return math.max(
          (data[i] - data[seed]).abs(),
          math.max(
            (data[i + 1] - data[seed + 1]).abs(),
            (data[i + 2] - data[seed + 2]).abs(),
          ),
        ) <=
        limit;
  }

  while (stack.isNotEmpty) {
    final p = stack.removeLast(), y = p ~/ width, x = p % width;
    if (!match(x, y)) continue;
    var left = x, right = x;
    while (match(left - 1, y)) {
      left--;
    }
    while (match(right + 1, y)) {
      right++;
    }
    for (var px = left; px <= right; px++) {
      visited[y * width + px] = 1;
    }
    spans.addAll([left, y, right - left + 1]);
    for (final ny in [y - 1, y + 1]) {
      if (ny < 0 || ny >= height) continue;
      var inside = false;
      for (var px = left; px <= right; px++) {
        final next = match(px, ny);
        if (next && !inside) stack.add(ny * width + px);
        inside = next;
      }
    }
  }
  return spans;
}
