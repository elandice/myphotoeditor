import 'dart:js_interop';
import 'dart:typed_data';

import 'editor_recovery.dart';

@JS('lumaRecovery.read')
external JSPromise<JSUint8Array?> _read();
@JS('lumaRecovery.write')
external JSPromise<JSAny?> _write(JSUint8Array project);
@JS('lumaRecovery.clear')
external JSPromise<JSAny?> _clear();
@JS('lumaRecovery.setDirty')
external void _setDirty(JSBoolean dirty);

EditorRecoveryStore createRecoveryStore() => _BrowserRecoveryStore();
EditorCloseGuard createCloseGuard() => _BrowserCloseGuard();

class _BrowserRecoveryStore implements EditorRecoveryStore {
  @override
  Future<Uint8List?> read() async => (await _read().toDart)?.toDart;
  @override
  Future<void> write(Uint8List project) async {
    await _write(project.toJS).toDart;
  }

  @override
  Future<void> clear() async {
    await _clear().toDart;
  }
}

class _BrowserCloseGuard implements EditorCloseGuard {
  @override
  void update(bool dirty) {
    try {
      _setDirty(dirty.toJS);
    } catch (_) {
      /* Test hosts have no browser. */
    }
  }

  @override
  void dispose() => update(false);
}
