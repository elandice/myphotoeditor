import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' as ui;

import 'gpu_layer.dart';

@JS('lumaBlend.available')
external JSBoolean _available();

@JS('lumaBlend.composite')
external JSUint8Array? _composite(
  JSNumber width,
  JSNumber height,
  JSArray<_JsGpuLayer> layers,
);

extension type _JsGpuLayer._(JSObject _) implements JSObject {
  external factory _JsGpuLayer({
    JSUint8Array rgba,
    JSNumber opacity,
    JSString blendMode,
  });
}

bool get supportsWebGl {
  try {
    return _available().toDart;
  } catch (_) {
    // Unit tests, older browsers, context loss, or a blocked script.
    return false;
  }
}

Future<ui.Image?> compositeWebGl({
  required int width,
  required int height,
  required List<GpuLayer> layers,
}) async {
  if (!supportsWebGl || width <= 0 || height <= 0) return null;
  try {
    final data = _composite(
      width.toJS,
      height.toJS,
      layers
          .map(
            (layer) => _JsGpuLayer(
              rgba: layer.rgba.toJS,
              opacity: layer.opacity.clamp(0, 1).toJS,
              blendMode: layer.blendMode.toLowerCase().toJS,
            ),
          )
          .toList()
          .toJS,
    );
    if (data == null) return null;
    final pixels = data.toDart;
    if (pixels.length != width * height * 4) return null;
    // GLSL keeps straight RGB between blend passes. Flutter's raw pixel
    // decoder expects premultiplied RGBA, including partially transparent edges.
    for (var i = 0; i < pixels.length; i += 4) {
      final alpha = pixels[i + 3];
      pixels[i] = (pixels[i] * alpha + 127) ~/ 255;
      pixels[i + 1] = (pixels[i + 1] * alpha + 127) ~/ 255;
      pixels[i + 2] = (pixels[i + 2] * alpha + 127) ~/ 255;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return await completer.future;
  } catch (_) {
    // Renderers may lose their GPU context under memory pressure. The caller
    // retains the normal Canvas composition as the fully functional fallback.
    return null;
  }
}
