import 'editor_recovery.dart';

EditorRecoveryStore createRecoveryStore() => MemoryEditorRecoveryStore();
EditorCloseGuard createCloseGuard() => _NoopCloseGuard();

class _NoopCloseGuard implements EditorCloseGuard {
  @override
  void update(bool dirty) {}
  @override
  void dispose() {}
}
