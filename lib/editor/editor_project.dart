part of 'editor_controller.dart';

/// Versioned, editable Luma project. This format is independent of Adobe PSD.
extension EditorProjects on EditorController {
  Future<Uint8List> exportProject() async {
    if (_stroke != null) await endStroke();
    if (hasActiveTransform) await commitTransform();
    if (_busy || _disposed) throw StateError('다른 작업을 처리 중입니다.');
    final estimate = _layers.fold<int>(
      0,
      (bytes, layer) =>
          bytes +
          layer.image.width *
              layer.image.height *
              4 *
              (layer.mask == null ? 1 : 2),
    );
    if (_layers.isEmpty || _layers.length > 64 || estimate > (256 << 20)) {
      throw StateError(
        '프로젝트는 최대 64개 레이어, 이미지·마스크 합계 256MiB까지 저장할 수 있습니다. 레이어를 병합하거나 크기를 줄여 주세요.',
      );
    }
    _busy = true;
    _notify();
    try {
      Future<String> encode(ui.Image image) async {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('레이어를 저장할 수 없습니다.');
        return base64Encode(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }

      final records = <Map<String, Object?>>[];
      for (final layer in _layers) {
        records.add({
          'id': layer.id,
          'name': layer.name,
          'png': await encode(layer.image),
          'visible': layer.visible,
          'locked': layer.locked,
          'opacity': layer.opacity,
          'blendMode': layer.blendMode.name,
          'offset': [layer.offset.dx, layer.offset.dy],
          'rotation': layer.rotation,
          'scale': layer.scale,
          'brightness': layer.brightness,
          'contrast': layer.contrast,
          'saturation': layer.saturation,
          'text': layer.text,
          'fontSize': layer.fontSize,
          'fontFamily': layer.fontFamily,
          'color': layer.color.toARGB32(),
          'textPosition': [layer.textPosition.dx, layer.textPosition.dy],
          'mask': layer.mask == null ? null : await encode(layer.mask!),
          'maskEnabled': layer.maskEnabled,
        });
      }
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'luma-studio',
            'version': 1,
            'width': documentSize.width.toInt(),
            'height': documentSize.height.toInt(),
            'activeLayer': _activeLayerId,
            'layers': records,
          }),
        ),
      );
      if (bytes.length > (128 << 20)) {
        throw StateError('프로젝트 파일이 128MiB를 넘습니다. 레이어를 병합하거나 크기를 줄여 주세요.');
      }
      return bytes;
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> importProject(Uint8List bytes) async {
    if (_busy || _disposed || _stroke != null) {
      throw StateError('다른 작업을 처리 중입니다.');
    }
    if (hasActiveTransform) cancelTransform();
    if (bytes.length > 128 << 20) {
      throw const FormatException('프로젝트 파일은 128MiB 이하여야 합니다.');
    }
    final root = jsonDecode(utf8.decode(bytes));
    if (root is! Map<String, dynamic> ||
        root['format'] != 'luma-studio' ||
        root['version'] != 1) {
      throw const FormatException('지원하지 않는 Luma 프로젝트입니다.');
    }
    final width = root['width'],
        height = root['height'],
        records = root['layers'];
    if (width is! int ||
        height is! int ||
        width < 1 ||
        height < 1 ||
        width > 4096 ||
        height > 4096 ||
        records is! List ||
        records.isEmpty ||
        records.length > 64) {
      throw const FormatException('문서 크기 또는 레이어 수가 올바르지 않습니다.');
    }
    final masks = records
        .where((record) => record is Map && record['mask'] != null)
        .length;
    if (width * height * 4 * (records.length + masks) > 256 << 20) {
      throw const FormatException('레이어 이미지의 메모리 합계는 256MiB 이하여야 합니다.');
    }
    _busy = true;
    _notify();
    final pending = <ui.Image>[];
    try {
      double number(
        Map record,
        String key,
        double fallback,
        double min,
        double max,
      ) {
        final value = record[key] ?? fallback;
        if (value is! num || !value.isFinite || value < min || value > max) {
          throw FormatException('$key 값이 올바르지 않습니다.');
        }
        return value.toDouble();
      }

      bool flag(Map record, String key, bool fallback) {
        final value = record[key] ?? fallback;
        if (value is! bool) throw FormatException('$key 값이 올바르지 않습니다.');
        return value;
      }

      Offset point(Map record, String key) {
        final value = record[key] ?? [0, 0];
        if (value is! List ||
            value.length != 2 ||
            value.any((p) => p is! num || !p.isFinite || p.abs() > 1000000)) {
          throw FormatException('$key 좌표가 올바르지 않습니다.');
        }
        return Offset(
          (value[0] as num).toDouble(),
          (value[1] as num).toDouble(),
        );
      }

      Future<ui.Image> decode(Object? png) async {
        if (png is! String || png.length > 96 << 20) {
          throw const FormatException('레이어 이미지가 올바르지 않습니다.');
        }
        final data = base64Decode(png);
        final buffer = await ui.ImmutableBuffer.fromUint8List(data);
        ui.ImageDescriptor? descriptor;
        ui.Codec? codec;
        try {
          descriptor = await ui.ImageDescriptor.encoded(buffer);
          if (descriptor.width != width || descriptor.height != height) {
            throw const FormatException('레이어와 문서의 크기가 다릅니다.');
          }
          codec = await descriptor.instantiateCodec();
          final image = (await codec.getNextFrame()).image;
          pending.add(image);
          return image;
        } finally {
          codec?.dispose();
          descriptor?.dispose();
          buffer.dispose();
        }
      }

      final layers = <EditorLayer>[];
      final ids = <String>{};
      String? active;
      for (final record in records) {
        if (record is! Map ||
            record['id'] is! String ||
            record['name'] is! String ||
            !ids.add(record['id'] as String) ||
            (record['name'] as String).length > 500 ||
            (record['text'] != null &&
                (record['text'] is! String ||
                    (record['text'] as String).length > 100000))) {
          throw const FormatException('레이어 정보가 올바르지 않습니다.');
        }
        final modeName = record['blendMode'] ?? 'srcOver';
        final modes = ui.BlendMode.values
            .where((mode) => mode.name == modeName)
            .toList();
        if (modes.isEmpty ||
            !const {
              ui.BlendMode.srcOver,
              ui.BlendMode.multiply,
              ui.BlendMode.screen,
              ui.BlendMode.overlay,
              ui.BlendMode.darken,
              ui.BlendMode.lighten,
              ui.BlendMode.difference,
              ui.BlendMode.plus,
            }.contains(modes.single)) {
          throw const FormatException('지원하지 않는 블렌드 모드입니다.');
        }
        final color = record['color'] ?? 0xff7865e9;
        if (color is! int ||
            color < 0 ||
            color > 0xffffffff ||
            (record['fontFamily'] != null && record['fontFamily'] is! String)) {
          throw const FormatException('텍스트 스타일이 올바르지 않습니다.');
        }
        final image = await decode(record['png']);
        final mask = record['mask'] == null
            ? null
            : await decode(record['mask']);
        final id = _id();
        if (record['id'] == root['activeLayer']) active = id;
        layers.add(
          EditorLayer(
            id: id,
            name: record['name'] as String,
            image: image,
            mask: mask,
            maskEnabled: flag(record, 'maskEnabled', true),
            visible: flag(record, 'visible', true),
            locked: flag(record, 'locked', false),
            opacity: number(record, 'opacity', 1, 0, 1),
            blendMode: modes.single,
            offset: point(record, 'offset'),
            rotation: number(record, 'rotation', 0, -10000, 10000),
            scale: number(record, 'scale', 1, .05, 10),
            brightness: number(record, 'brightness', 0, -1, 1),
            contrast: number(record, 'contrast', 1, 0, 2),
            saturation: number(record, 'saturation', 1, 0, 2),
            text: record['text'] as String?,
            fontSize: number(record, 'fontSize', 84, 1, 1000),
            fontFamily: record['fontFamily'] as String? ?? 'sans-serif',
            color: Color(color),
            textPosition: point(record, 'textPosition'),
          ),
        );
      }
      if (_disposed) return;
      _images.addAll(pending);
      _edit('프로젝트 열기', () {
        _documentSize = Size(width.toDouble(), height.toDouble());
        _layers = layers;
        _activeLayerId = active ?? layers.last.id;
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
}
