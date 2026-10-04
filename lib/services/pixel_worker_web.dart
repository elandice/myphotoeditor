import 'dart:js_interop';
import 'dart:typed_data';

@JS('lumaPixels.filter')
external JSPromise<JSUint8Array> _filter(_JsPixelsRequest request);

@JS('lumaPixels.region')
external JSPromise<JSInt32Array> _region(_JsPixelsRequest request);

extension type _JsPixelsRequest._(JSObject _) implements JSObject {
  external factory _JsPixelsRequest({
    required JSUint8Array pixels,
    required JSNumber width,
    required JSNumber height,
    JSString filter,
    JSNumber amount,
    JSNumber x,
    JSNumber y,
    JSNumber tolerance,
  });
}

/// Worker failures are nullable so the caller retains its native Dart oracle
/// and Canvas-based fallback. The JS bridge copies input before transferring
/// it, leaving these bytes usable if Worker creation, CSP, or processing fails.
Future<Uint8List?> filterPixelsWeb(Map<String, Object> args) async {
  try {
    final input = args['pixels'] as Uint8List;
    final result = (await _filter(
      _JsPixelsRequest(
        pixels: input.toJS,
        width: (args['width'] as int).toJS,
        height: (args['height'] as int).toJS,
        filter: (args['filter'] as String).toJS,
        amount: (args['amount'] as double).toJS,
      ),
    ).toDart).toDart;
    return result.length == input.length ? result : null;
  } catch (_) {
    return null;
  }
}

Future<List<int>?> connectedColorRegionWeb(Map<String, Object> args) async {
  try {
    final result = (await _region(
      _JsPixelsRequest(
        pixels: (args['pixels'] as Uint8List).toJS,
        width: (args['width'] as int).toJS,
        height: (args['height'] as int).toJS,
        x: (args['x'] as int).toJS,
        y: (args['y'] as int).toJS,
        tolerance: (args['tolerance'] as double).toJS,
      ),
    ).toDart).toDart;
    return result.length % 3 == 0 ? result : null;
  } catch (_) {
    return null;
  }
}
