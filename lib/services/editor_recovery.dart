import 'dart:typed_data';

import 'editor_recovery_stub.dart'
    if (dart.library.io) 'editor_recovery_io.dart'
    if (dart.library.js_interop) 'editor_recovery_web.dart'
    as platform;

/// Recovery is local to this device and does not replace an explicit save.
abstract class EditorRecoveryStore {
  Future<Uint8List?> read();
  Future<void> write(Uint8List project);
  Future<void> clear();
}

EditorRecoveryStore createEditorRecoveryStore() =>
    platform.createRecoveryStore();

abstract class EditorCloseGuard {
  void update(bool dirty);
  void dispose();
}

EditorCloseGuard createEditorCloseGuard() => platform.createCloseGuard();

class MemoryEditorRecoveryStore implements EditorRecoveryStore {
  Uint8List? _project;

  @override
  Future<Uint8List?> read() async =>
      _project == null ? null : Uint8List.fromList(_project!);

  @override
  Future<void> write(Uint8List project) async {
    _project = Uint8List.fromList(project);
  }

  @override
  Future<void> clear() async {
    _project = null;
  }
}
