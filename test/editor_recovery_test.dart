import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';
import 'package:myphotoeditor/editor/editor_viewport.dart';
import 'package:myphotoeditor/main.dart';
import 'package:myphotoeditor/services/editor_recovery.dart';
import 'package:myphotoeditor/services/editor_recovery_io.dart';

import 'widget_test.dart' show openEditor;

class _SavePicker extends FilePicker {
  String? savedPath;
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => savedPath;
}

Future<void> _finish(WidgetTester tester, EditorController editor) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  for (var index = 0; index < 60; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
    if (!editor.isBusy) break;
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _newMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('문서 메뉴'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('새 캔버스'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester, EditorController editor) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await _finish(tester, editor);
}

void main() {
  testWidgets('cancelling app exit resumes recovery of the dirty document', (
    tester,
  ) async {
    final store = MemoryEditorRecoveryStore();
    final editor = await openEditor(
      tester,
      const Size(1440, 900),
      recoveryStore: store,
    );
    await tester.runAsync(() => editor.newDocument(32, 32));
    editor.renameLayer(editor.activeLayerId!, 'exit-cancelled');
    final exit = tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않은 변경'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(await exit, ui.AppExitResponse.cancel);
    await tester.pump(const Duration(seconds: 5));
    await _finish(tester, editor);
    expect(await store.read(), isNotNull);
    expect(editor.isDirty, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'new-document dialog pauses recovery until replacement completes',
    (tester) async {
      final store = MemoryEditorRecoveryStore();
      final editor = await openEditor(
        tester,
        const Size(1440, 900),
        recoveryStore: store,
      );
      await tester.runAsync(() => editor.newDocument(32, 32));
      editor.renameLayer(editor.activeLayerId!, 'old');
      await tester.pump();
      await _newMenu(tester);
      await tester.tap(find.text('저장하지 않고 계속'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('새 캔버스'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(await store.read(), isNull);
      await tester.enterText(find.byType(TextField).at(0), '128');
      await tester.enterText(find.byType(TextField).at(1), '128');
      await tester.tap(find.text('만들기'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await _finish(tester, editor);
      expect(editor.documentSize, const Size(128, 128));
      expect(editor.isDirty, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test('recovery file replacement preserves the last complete slot', () async {
    final root = await Directory.systemTemp.createTemp('luma-recovery-test-');
    final store = FileEditorRecoveryStore(directory: () async => root);
    try {
      expect(await store.read(), isNull);
      await store.write(Uint8List.fromList([1, 2, 3]));
      await store.write(Uint8List.fromList([4, 5, 6, 7]));
      expect(await store.read(), [4, 5, 6, 7]);
      await File('${root.path}/draft-0.bin').writeAsBytes([0, 1]);
      await File('${root.path}/draft-1.bin.pending').writeAsBytes([9]);
      expect(await store.read(), [1, 2, 3]);
      await store.write(Uint8List.fromList([8, 9]));
      expect(await store.read(), [8, 9]);
      await store.clear();
      expect(await store.read(), isNull);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('recovery serializes overlapping save and clear requests', () async {
    final root = await Directory.systemTemp.createTemp('luma-recovery-test-');
    final store = FileEditorRecoveryStore(directory: () async => root);
    try {
      final write = store.write(Uint8List.fromList([1, 2, 3]));
      final clear = store.clear();
      await Future.wait([write, clear]);
      expect(await store.read(), isNull);
      await expectLater(store.write(Uint8List(0)), throwsArgumentError);
      await store.write(Uint8List.fromList([7]));
      expect(await store.read(), [7]);
    } finally {
      await root.delete(recursive: true);
    }
  });

  testWidgets('cancelled save keeps dirty state and blocks replacement', (
    tester,
  ) async {
    FilePicker.platform = _SavePicker();
    final editor = await openEditor(tester, const Size(1440, 900));
    await tester.runAsync(() => editor.newDocument(32, 32));
    editor.renameLayer(editor.activeLayerId!, 'unsaved');
    await tester.pump();
    await _save(tester, editor);
    expect(editor.isDirty, isTrue);
    await _newMenu(tester);
    expect(find.text('저장하지 않은 변경'), findsOneWidget);
    await tester.tap(find.text('프로젝트 저장'));
    await _finish(tester, editor);
    expect(find.text('새 캔버스'), findsNothing);
    expect(editor.activeLayer!.name, 'unsaved');
    expect(editor.isDirty, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'explicit save clears dirty state and Undo tracks the saved content',
    (tester) async {
      FilePicker.platform = _SavePicker()..savedPath = 'saved.luma';
      final editor = await openEditor(tester, const Size(1440, 900));
      await tester.runAsync(() => editor.newDocument(32, 32));
      editor.renameLayer(editor.activeLayerId!, 'saved');
      await tester.pump();
      await _save(tester, editor);
      expect(editor.isDirty, isFalse);
      editor.setLayerOpacity(.5);
      expect(editor.isDirty, isTrue);
      editor.undo();
      expect(editor.isDirty, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'idle recovery stores the project without claiming it was saved',
    (tester) async {
      final store = MemoryEditorRecoveryStore();
      final editor = await openEditor(
        tester,
        const Size(1440, 900),
        recoveryStore: store,
      );
      await tester.runAsync(() => editor.newDocument(32, 32));
      editor.renameLayer(editor.activeLayerId!, 'draft');
      await tester.pump(const Duration(seconds: 5));
      await _finish(tester, editor);
      final bytes = await store.read();
      expect(bytes, isNotNull);
      expect(editor.isDirty, isTrue);
      final restored = EditorController();
      await tester.runAsync(() => restored.importProject(bytes!));
      expect(restored.activeLayer!.name, 'draft');
      restored.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('startup recovery restores draft as unsaved work', (
    tester,
  ) async {
    final source = EditorController();
    final store = MemoryEditorRecoveryStore();
    await tester.runAsync(() async {
      await source.newDocument(32, 32);
      source.renameLayer(source.activeLayerId!, 'recovered');
      await store.write(await source.exportProject());
      source.dispose();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MyApp(recoveryStore: store));
    for (var index = 0; index < 60; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.text('이전 작업 복구').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('복구'));
    final editor = tester
        .widget<EditorViewport>(find.byType(EditorViewport))
        .controller;
    await _finish(tester, editor);
    expect(editor.activeLayer!.name, 'recovered');
    expect(editor.isDirty, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
