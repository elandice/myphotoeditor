import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';
import 'package:myphotoeditor/editor/editor_viewport.dart';
import 'package:myphotoeditor/main.dart';
import 'package:myphotoeditor/services/editor_recovery.dart';

Future<EditorController> openEditor(
  WidgetTester tester,
  Size size, {
  EditorRecoveryStore? recoveryStore,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MyApp(recoveryStore: recoveryStore ?? MemoryEditorRecoveryStore()),
  );
  // Picture.toImage runs outside the widget-test fake clock.
  for (var attempt = 0; attempt < 60; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.byType(EditorViewport).evaluate().isNotEmpty) break;
  }
  expect(find.byType(EditorViewport), findsOneWidget);
  await tester.pump(const Duration(milliseconds: 200));
  expect(tester.takeException(), isNull);
  return tester.widget<EditorViewport>(find.byType(EditorViewport)).controller;
}

void main() {
  for (final viewport in <String, Size>{
    'small phone': const Size(320, 700),
    'phone': const Size(390, 844),
    'landscape': const Size(844, 390),
    'narrow tablet': const Size(600, 900),
    'small tablet': const Size(700, 900),
    'tablet': const Size(800, 1024),
    'small desktop': const Size(1000, 800),
    'desktop': const Size(1440, 900),
  }.entries) {
    testWidgets('${viewport.key} opens the editor without layout overflow', (
      tester,
    ) async {
      final editor = await openEditor(tester, viewport.value);
      expect(find.text('luma'), findsOneWidget);
      expect(editor.documentSize, const Size(1200, 900));
      expect(editor.layers, hasLength(1));
      expect(editor.isDirty, isFalse);
      expect(
        tester.getSize(find.byType(EditorViewport)).height,
        greaterThan(100),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('startup is a clean transparent canvas ready for drawing', (
    tester,
  ) async {
    final store = MemoryEditorRecoveryStore();
    final editor = await openEditor(
      tester,
      const Size(1440, 900),
      recoveryStore: store,
    );
    expect(find.text('이름 없는 작업'), findsWidgets);
    expect(editor.documentSize, const Size(1200, 900));
    expect(editor.layers, hasLength(1));
    expect(editor.activeLayer!.name, '레이어 1');
    expect(editor.activeLayer!.visible, isTrue);
    expect(editor.activeLayer!.locked, isFalse);
    expect(editor.isDirty, isFalse);
    expect(editor.historyLength, 0);
    expect(editor.canUndo, isFalse);
    final initialImage = editor.activeLayer!.image;
    final data = await tester.runAsync(
      () => initialImage.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
    );
    expect(data, isNotNull);
    final pixels = data!.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    expect(pixels.every((value) => value == 0), isTrue);
    expect(await store.read(), isNull);

    editor.beginStroke(const Offset(600, 450));
    editor.appendStroke(const Offset(620, 450));
    expect(editor.isStroking, isTrue);
    await tester.runAsync(editor.endStroke);
    expect(editor.isDirty, isTrue);
    expect(editor.historyLength, 1);
    expect(identical(editor.activeLayer!.image, initialImage), isFalse);
    final painted = await tester.runAsync(
      () => editor.activeLayer!.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ),
    );
    expect(painted!.getUint8((450 * 1200 + 610) * 4 + 3), greaterThan(0));
    editor.undo();
    expect(identical(editor.activeLayer!.image, initialImage), isTrue);
    expect(editor.isDirty, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop layers and adjustment drag have working grouped undo', (
    tester,
  ) async {
    final editor = await openEditor(tester, const Size(1440, 900));
    final originalCount = editor.layers.length;
    await tester.tap(find.byTooltip('새 레이어'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(editor.layers.length, originalCount + 1);
    await tester.tap(find.byTooltip('레이어 숨기기').first);
    await tester.pump(const Duration(milliseconds: 350));
    expect(editor.activeLayer!.visible, isFalse);
    await tester.tap(find.byTooltip('레이어 표시').first);
    await tester.pump(const Duration(milliseconds: 350));
    expect(editor.activeLayer!.visible, isTrue);
    await tester.tap(find.text('조정'));
    await tester.pump();
    final brightness = find.byWidgetPredicate(
      (widget) => widget is Slider && widget.min == -1 && widget.max == 1,
    );
    expect(brightness, findsOneWidget);
    final beforeHistory = editor.historyLength;
    final gesture = await tester.startGesture(tester.getCenter(brightness));
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(editor.activeLayer!.brightness, greaterThan(.1));
    expect(editor.historyLength, beforeHistory + 1);
    await tester.tap(find.byTooltip('실행 취소 (Ctrl/⌘ Z)'));
    await tester.pump();
    expect(editor.activeLayer!.brightness, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('small phone opens a usable layer panel', (tester) async {
    final editor = await openEditor(tester, const Size(320, 700));
    await tester.tap(find.text('레이어 ${editor.layers.length}'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('새 레이어'), findsOneWidget);
    await tester.tap(find.byTooltip('레이어 숨기기').first);
    await tester.pump(const Duration(milliseconds: 350));
    expect(editor.activeLayer!.visible, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop tool shortcuts work without stealing text input', (
    tester,
  ) async {
    final editor = await openEditor(tester, const Size(1440, 900));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(editor.tool, EditorTool.marquee);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    expect(editor.tool, EditorTool.text);
    final canvas = tester.widget<EditorViewport>(find.byType(EditorViewport));
    final topLeft = tester.getTopLeft(find.byType(EditorViewport));
    final position =
        topLeft +
        canvas.viewportController.documentToViewport(
          editor.documentSize.center(Offset.zero),
        );
    await tester.tapAt(position);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsWidgets);
    await tester.tap(find.byType(TextField).first);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(editor.tool, EditorTool.text);
    await tester.enterText(find.byType(TextField).first, 'My photo B H V');
    expect(find.text('My photo B H V'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
