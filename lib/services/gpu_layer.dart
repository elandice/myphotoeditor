import 'dart:typed_data';

/// A document-sized layer in straight (unpremultiplied) RGBA, bottom to top.
/// Transform and color adjustment must already have been rasterized.
class GpuLayer {
  const GpuLayer({
    required this.rgba,
    this.opacity = 1,
    this.blendMode = 'normal',
  });

  final Uint8List rgba;
  final double opacity;
  final String blendMode;
}
