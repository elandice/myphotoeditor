import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../editor/editor_project_schema.dart';
import 'editor_recovery.dart';
import 'editor_recovery_stub.dart' as stub;

EditorRecoveryStore createRecoveryStore() => FileEditorRecoveryStore(
  directory: () async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}luma-recovery');
  },
);

EditorCloseGuard createCloseGuard() => stub.createCloseGuard();

/// Alternating slots keep the previous complete draft if a write is interrupted.
class FileEditorRecoveryStore implements EditorRecoveryStore {
  FileEditorRecoveryStore({required this.directory});

  final Future<Directory> Function() directory;
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  File _slot(Directory root, int index) =>
      File('${root.path}${Platform.pathSeparator}draft-$index.bin');

  Future<(int, Uint8List)?> _readSlot(File file) async {
    try {
      if (!await file.exists()) return null;
      final size = await file.length();
      if (size < 16 || size > EditorProjectSchema.maxProjectBytes + 16) {
        return null;
      }
      final data = await file.readAsBytes();
      if (data.length != size || data.length < 16) return null;
      final header = ByteData.sublistView(data, 0, 16);
      if (header.getUint32(0) != 0x4c524331 ||
          header.getUint32(12) != data.length - 16) {
        return null;
      }
      return (header.getUint64(4), Uint8List.sublistView(data, 16));
    } on FileSystemException {
      return null;
    }
  }

  Future<(int, Uint8List)?> _latest(Directory root) async {
    final slots = await Future.wait([
      _readSlot(_slot(root, 0)),
      _readSlot(_slot(root, 1)),
    ]);
    final valid = slots.whereType<(int, Uint8List)>().toList()
      ..sort((a, b) => b.$1.compareTo(a.$1));
    return valid.isEmpty ? null : valid.first;
  }

  @override
  Future<Uint8List?> read() => _serial(() async {
    final latest = await _latest(await directory());
    return latest == null || latest.$2.isEmpty ? null : latest.$2;
  });

  @override
  Future<void> write(Uint8List project) => _serial(() async {
    if (project.isEmpty ||
        project.length > EditorProjectSchema.maxProjectBytes) {
      throw ArgumentError('복구 파일의 크기가 올바르지 않습니다.');
    }
    final root = await directory();
    await root.create(recursive: true);
    await _writeSlot(root, project);
  });

  Future<int> _writeSlot(Directory root, Uint8List project) async {
    final generation = ((await _latest(root))?.$1 ?? 0) + 1;
    final target = _slot(root, generation % 2);
    final pending = File('${target.path}.pending');
    final header = ByteData(16)
      ..setUint32(0, 0x4c524331)
      ..setUint64(4, generation)
      ..setUint32(12, project.length);
    final handle = await pending.open(mode: FileMode.write);
    try {
      await handle.writeFrom(header.buffer.asUint8List());
      await handle.writeFrom(project);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await pending.rename(target.path);
    return generation % 2;
  }

  @override
  Future<void> clear() => _serial(() async {
    final root = await directory();
    if (!await root.exists()) return;
    // A complete tombstone outranks both drafts before old files are deleted.
    final tombstone = await _writeSlot(root, Uint8List(0));
    for (var index = 0; index < 2; index++) {
      final slot = _slot(root, index);
      for (final file in [
        if (index != tombstone) slot,
        File('${slot.path}.pending'),
      ]) {
        if (await file.exists()) await file.delete();
      }
    }
  });
}
