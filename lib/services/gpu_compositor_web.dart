import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' as ui;

import 'gpu_layer.dart';

@JS('lumaBlend.available')
external JSBoolean _available();

@JS('lumaBlend.begin')
external _JsCompositeSession? _begin(JSNumber width, JSNumber height);

extension type _JsCompositeSession._(JSObject _) implements JSObject {
  external JSBoolean add(_JsGpuLayer layer);
  external JSUint8Array? finish();
  external void dispose();
}

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
  final session = beginWebGlComposite(width: width, height: height);
  if (session == null) return null;
  try {
    for (final layer in layers) {
      if (!session.add(layer)) return null;
    }
    return await session.finish();
  } finally {
    session.dispose();
  }
}

/// Uploads each layer synchronously, so its full-size RGBA buffer can be
/// released before the next layer is rasterized and read back.
GpuCompositeSession? beginWebGlComposite({
  required int width,
  required int height,
}) {
  if (!supportsWebGl || width <= 0 || height <= 0) return null;
  try {
    final session = _begin(width.toJS, height.toJS);
    return session == null
        ? null
        : GpuCompositeSession._(session, width, height);
  } catch (_) {
    return null;
  }
}

class GpuCompositeSession {
  GpuCompositeSession._(this._session, this.width, this.height);
  final _JsCompositeSession _session;
  final int width;
  final int height;
  bool _disposed = false;

  bool add(GpuLayer layer) {
    if (_disposed || layer.rgba.length != width * height * 4) return false;
    try {
      return _session
          .add(
            _JsGpuLayer(
              rgba: layer.rgba.toJS,
              opacity: layer.opacity.clamp(0, 1).toJS,
              blendMode: layer.blendMode.toLowerCase().toJS,
            ),
          )
          .toDart;
    } catch (_) {
      return false;
    }
  }

  Future<ui.Image?> finish() async {
    if (_disposed) return null;
    try {
      final data = _session.finish();
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
    } finally {
      dispose();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _session.dispose();
    } catch (_) {
      // Context loss may invalidate every object owned by the session.
    }
  }
}
