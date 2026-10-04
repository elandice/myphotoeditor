import 'dart:ui' as ui;

import 'editor_models.dart';

/// Constraints shared by editing APIs and the versioned project format.
abstract final class EditorProjectSchema {
  static const maxDocumentSide = 4096;
  static const maxLayers = 64;
  static const maxLayerNameLength = 500;
  static const maxTextLength = 100000;
  static const maxFontFamilyLength = 500;
  static const maxDecodedBytes = 256 << 20;
  static const maxProjectBytes = 128 << 20;
  static const maxPngBase64Length = 96 << 20;
  static const maxCoordinate = 1000000.0;
  static const maxRotation = 10000.0;
  static const minScale = .05;
  static const maxScale = 10.0;
  static const minFontSize = 1.0;
  static const maxFontSize = 1000.0;

  static const blendModes = {
    ui.BlendMode.srcOver,
    ui.BlendMode.multiply,
    ui.BlendMode.screen,
    ui.BlendMode.overlay,
    ui.BlendMode.darken,
    ui.BlendMode.lighten,
    ui.BlendMode.difference,
    ui.BlendMode.plus,
  };

  static void validateDocumentSize(int width, int height) {
    if (width < 1 ||
        height < 1 ||
        width > maxDocumentSide ||
        height > maxDocumentSide) {
      throw ArgumentError('문서 크기는 1~4096 픽셀이어야 합니다.');
    }
  }

  static void validateLayerCount(int count) {
    if (count < 0 || count > maxLayers) {
      throw ArgumentError('프로젝트는 최대 64개 레이어를 지원합니다.');
    }
  }

  static void validateDecodedBudget(
    int width,
    int height, {
    required int layerCount,
    int maskCount = 0,
  }) {
    validateDocumentSize(width, height);
    validateLayerCount(layerCount);
    if (maskCount < 0 ||
        maskCount > layerCount ||
        width * height * 4 * (layerCount + maskCount) > maxDecodedBytes) {
      throw ArgumentError('레이어 이미지와 마스크의 메모리 합계는 256MiB 이하여야 합니다.');
    }
  }

  static void validateLayerName(String name) {
    if (name.length > maxLayerNameLength) {
      throw ArgumentError('레이어 이름은 최대 500자까지 입력할 수 있습니다.');
    }
  }

  static void validateText(String text) {
    if (text.length > maxTextLength) {
      throw ArgumentError('텍스트는 최대 100,000자까지 입력할 수 있습니다.');
    }
  }

  static void validateFontFamily(String family) {
    if (family.length > maxFontFamilyLength) {
      throw ArgumentError('글꼴 이름은 최대 500자까지 입력할 수 있습니다.');
    }
  }

  static void validateNumber(
    double value,
    String label,
    double min,
    double max,
  ) {
    if (!value.isFinite || value < min || value > max) {
      throw ArgumentError('$label 값은 $min~$max 범위여야 합니다.');
    }
  }

  static void validatePoint(ui.Offset point, {String label = '좌표'}) {
    validateNumber(point.dx, label, -maxCoordinate, maxCoordinate);
    validateNumber(point.dy, label, -maxCoordinate, maxCoordinate);
  }

  static void validateTransform({
    ui.Offset? offset,
    double? rotation,
    double? scale,
  }) {
    if (offset != null) validatePoint(offset);
    if (rotation != null) {
      validateNumber(rotation, '회전', -maxRotation, maxRotation);
    }
    if (scale != null) validateNumber(scale, '배율', minScale, maxScale);
  }

  static void validateFontSize(double size) =>
      validateNumber(size, '글자 크기', minFontSize, maxFontSize);

  static void validateBlendMode(ui.BlendMode mode) {
    if (!blendModes.contains(mode)) {
      throw ArgumentError('지원하지 않는 블렌드 모드입니다.');
    }
  }

  static void validateLayer(
    EditorLayer layer, {
    required int width,
    required int height,
  }) {
    validateLayerName(layer.name);
    if (layer.text != null) validateText(layer.text!);
    validateFontFamily(layer.fontFamily);
    validateFontSize(layer.fontSize);
    validateTransform(
      offset: layer.offset,
      rotation: layer.rotation,
      scale: layer.scale,
    );
    validatePoint(layer.textPosition, label: '텍스트 좌표');
    validateNumber(layer.opacity, '투명도', 0, 1);
    validateNumber(layer.brightness, '밝기', -1, 1);
    validateNumber(layer.contrast, '대비', 0, 2);
    validateNumber(layer.saturation, '채도', 0, 2);
    validateBlendMode(layer.blendMode);
    if (layer.image.width != width ||
        layer.image.height != height ||
        (layer.mask != null &&
            (layer.mask!.width != width || layer.mask!.height != height))) {
      throw ArgumentError('레이어와 문서의 크기가 다릅니다.');
    }
  }
}
