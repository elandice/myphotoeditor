import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';
import 'package:myphotoeditor/editor/editor_viewport.dart';

void main() {
  test(
    'zoom preserves the document point underneath the cursor and clamps',
    () {
      final viewport = ViewportController();
      const anchor = Offset(345, 210);
      final documentPoint = viewport.viewportToDocument(anchor);
      viewport.zoomAt(anchor, 2.5);
      expect(viewport.viewportToDocument(anchor), documentPoint);
      viewport.zoomAt(anchor, 100);
      expect(viewport.zoom, 8);
      viewport.zoomAt(anchor, .001);
      expect(viewport.zoom, .05);
      expect(
        (viewport.viewportToDocument(anchor) - documentPoint).distance,
        lessThan(.000001),
      );
      viewport.dispose();
    },
  );

  Future<void> mount(
    WidgetTester tester,
    EditorController editor,
    ViewportController viewport,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorViewport(
            controller: editor,
            viewportController: viewport,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> unmount(
    WidgetTester tester,
    EditorController editor,
    ViewportController viewport,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    editor.dispose();
    viewport.dispose();
  }

  Future<void> finishRaster(
    WidgetTester tester,
    EditorController editor,
  ) async {
    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
      if (!editor.isBusy) break;
    }
    expect(editor.isBusy, isFalse);
  }

  Future<Color> pixel(
    WidgetTester tester,
    EditorController editor,
    int x,
    int y,
  ) async {
    final image = editor.activeLayer!.image;
    final bytes = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    final offset = (y * image.width + x) * 4;
    return Color.fromARGB(
      bytes!.getUint8(offset + 3),
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
    );
  }

  testWidgets('ellipse marquee and lasso select their actual paths', (
    tester,
  ) async {
    final editor = EditorController();
    final viewport = ViewportController();
    await tester.runAsync(() => editor.newDocument(120, 90));
    editor.setTool(EditorTool.ellipticalMarquee);
    await mount(tester, editor, viewport);
    var gesture = await tester.startGesture(
      viewport.documentToViewport(const Offset(20, 15)),
    );
    await gesture.moveTo(viewport.documentToViewport(const Offset(100, 75)));
    await gesture.up();
    await tester.pump();
    expect(editor.selectionKind, EditorSelectionKind.ellipse);
    expect(editor.selectionPath!.contains(const Offset(60, 45)), isTrue);
    expect(editor.selectionPath!.contains(const Offset(21, 16)), isFalse);
    editor.setTool(EditorTool.lasso);
    gesture = await tester.startGesture(
      viewport.documentToViewport(const Offset(10, 10)),
    );
    for (final point in [
      const Offset(100, 10),
      const Offset(10, 80),
      const Offset(10, 10),
    ]) {
      await gesture.moveTo(viewport.documentToViewport(point));
    }
    await gesture.up();
    await tester.pump();
    expect(editor.selectionKind, EditorSelectionKind.lasso);
    expect(editor.selectionPath!.contains(const Offset(25, 25)), isTrue);
    expect(editor.selectionPath!.contains(const Offset(95, 75)), isFalse);
    await unmount(tester, editor, viewport);
  });

  testWidgets('pinch cancels a selection drag and restores an inverted path', (
    tester,
  ) async {
    final editor = EditorController();
    final viewport = ViewportController();
    await tester.runAsync(() => editor.newDocument(120, 90));
    editor.setEllipseSelection(const Rect.fromLTWH(40, 20, 40, 40));
    editor.invertSelection();
    editor.setTool(EditorTool.lasso);
    await mount(tester, editor, viewport);
    final first = await tester.startGesture(
      viewport.documentToViewport(const Offset(10, 10)),
      pointer: 1,
    );
    await first.moveTo(viewport.documentToViewport(const Offset(50, 10)));
    await first.moveTo(viewport.documentToViewport(const Offset(30, 50)));
    final second = await tester.startGesture(
      viewport.documentToViewport(const Offset(100, 50)),
      pointer: 2,
    );
    expect(editor.selectionKind, EditorSelectionKind.inverted);
    expect(editor.selectionPath!.contains(const Offset(60, 40)), isFalse);
    expect(editor.selectionPath!.contains(const Offset(5, 5)), isTrue);
    await second.up();
    await first.up();
    await unmount(tester, editor, viewport);
  });

  testWidgets(
    'eyedropper samples and bucket fills only the clicked connected area',
    (tester) async {
      final editor = EditorController();
      final viewport = ViewportController();
      await tester.runAsync(() async {
        await editor.newDocument(64, 64);
        editor.setBrushColor(const Color(0xFFFF0000));
        await editor.drawShape(
          const Rect.fromLTWH(0, 0, 32, 64),
          ellipse: false,
        );
      });
      editor.setBrushColor(const Color(0xFF00FF00));
      editor.setTool(EditorTool.eyedropper);
      await mount(tester, editor, viewport);
      await tester.tapAt(viewport.documentToViewport(const Offset(10, 10)));
      await finishRaster(tester, editor);
      expect(editor.brushColor.toARGB32(), 0xFFFF0000);
      editor.setBrushColor(const Color(0xFF0000FF));
      editor.setTool(EditorTool.fill);
      await tester.tapAt(viewport.documentToViewport(const Offset(48, 20)));
      await finishRaster(tester, editor);
      expect((await pixel(tester, editor, 10, 20)).toARGB32(), 0xFFFF0000);
      expect((await pixel(tester, editor, 48, 20)).toARGB32(), 0xFF0000FF);
      await unmount(tester, editor, viewport);
    },
  );

  testWidgets(
    'gradient drag commits once and a two finger preview commits nothing',
    (tester) async {
      final editor = EditorController();
      final viewport = ViewportController();
      await tester.runAsync(() => editor.newDocument(64, 64));
      editor.setBrushColor(const Color(0xFFFF0000));
      editor.setSecondaryColor(const Color(0xFF0000FF));
      editor.setTool(EditorTool.gradient);
      await mount(tester, editor, viewport);
      final start = viewport.documentToViewport(const Offset(1, 32));
      final end = viewport.documentToViewport(const Offset(63, 32));
      var gesture = await tester.startGesture(start);
      await gesture.moveTo(end);
      expect(editor.historyLength, 0);
      await gesture.up();
      await finishRaster(tester, editor);
      expect(editor.historyLength, 1);
      final left = await pixel(tester, editor, 2, 32);
      final right = await pixel(tester, editor, 61, 32);
      expect(left.r, greaterThan(left.b));
      expect(right.b, greaterThan(right.r));
      gesture = await tester.startGesture(start, pointer: 1);
      await gesture.moveTo(end);
      final second = await tester.startGesture(
        viewport.documentToViewport(const Offset(30, 10)),
        pointer: 2,
      );
      await second.up();
      await gesture.up();
      await tester.pump();
      expect(editor.historyLength, 1);
      await unmount(tester, editor, viewport);
    },
  );

  testWidgets(
    'clone source is chosen with Alt or mobile source mode without painting',
    (tester) async {
      final editor = EditorController();
      final viewport = ViewportController();
      await tester.runAsync(() => editor.newDocument(120, 90));
      editor.setTool(EditorTool.cloneStamp);
      await mount(tester, editor, viewport);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tapAt(viewport.documentToViewport(const Offset(20, 20)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(
        (editor.cloneSource! - const Offset(20, 20)).distance,
        lessThan(.001),
      );
      expect(editor.isStroking, isFalse);
      expect(editor.historyLength, 0);
      editor.setCloneSourcePickMode(true);
      await tester.tapAt(viewport.documentToViewport(const Offset(70, 60)));
      expect(
        (editor.cloneSource! - const Offset(70, 60)).distance,
        lessThan(.001),
      );
      expect(editor.cloneSourcePickMode, isFalse);
      expect(editor.historyLength, 0);
      await unmount(tester, editor, viewport);
    },
  );

  testWidgets('rectangle fill and ellipse outline follow the dragged bounds', (
    tester,
  ) async {
    final editor = EditorController();
    final viewport = ViewportController();
    await tester.runAsync(() => editor.newDocument(64, 64));
    editor.setBrushColor(const Color(0xFFFF0000));
    editor.setTool(EditorTool.rectangle);
    editor.setShapeFilled(true);
    await mount(tester, editor, viewport);
    var gesture = await tester.startGesture(
      viewport.documentToViewport(const Offset(10, 10)),
    );
    await gesture.moveTo(viewport.documentToViewport(const Offset(50, 50)));
    expect(editor.historyLength, 0);
    await gesture.up();
    await finishRaster(tester, editor);
    expect((await pixel(tester, editor, 30, 30)).toARGB32(), 0xFFFF0000);
    expect((await pixel(tester, editor, 5, 5)).a, 0);
    editor.undo();
    editor.setTool(EditorTool.ellipse);
    editor.setShapeFilled(false);
    editor.setBrushSize(4);
    gesture = await tester.startGesture(
      viewport.documentToViewport(const Offset(10, 10)),
    );
    await gesture.moveTo(viewport.documentToViewport(const Offset(50, 50)));
    await gesture.up();
    await finishRaster(tester, editor);
    expect((await pixel(tester, editor, 30, 30)).a, 0);
    expect((await pixel(tester, editor, 10, 30)).a, greaterThan(.9));
    await unmount(tester, editor, viewport);
  });

  testWidgets('marquee drag clips its rectangle to document bounds', (
    tester,
  ) async {
    final editor = EditorController()..setTool(EditorTool.marquee);
    final viewport = ViewportController();
    await mount(tester, editor, viewport);
    final start = viewport.documentToViewport(const Offset(300, 200));
    final outside = viewport.documentToViewport(const Offset(1700, 1200));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(outside);
    await gesture.up();
    await tester.pump();
    expect(editor.selection!.left, closeTo(300, .000001));
    expect(editor.selection!.top, closeTo(200, .000001));
    expect(editor.selection!.right, 1200);
    expect(editor.selection!.bottom, 900);
    await unmount(tester, editor, viewport);
  });

  testWidgets(
    'second finger cancels paint and the remaining finger cannot paint',
    (tester) async {
      final editor = EditorController();
      final viewport = ViewportController();
      await tester.runAsync(() => editor.newDocument(120, 90));
      await mount(tester, editor, viewport);
      final firstPoint = viewport.documentToViewport(const Offset(40, 40));
      final secondPoint = viewport.documentToViewport(const Offset(80, 40));
      final beforeZoom = viewport.zoom;
      final beforeRevision = editor.revision;
      final first = await tester.startGesture(
        firstPoint,
        pointer: 1,
        kind: PointerDeviceKind.touch,
      );
      expect(editor.isStroking, isTrue);
      await first.moveBy(const Offset(-8, 0));
      final second = await tester.startGesture(
        secondPoint,
        pointer: 2,
        kind: PointerDeviceKind.touch,
      );
      expect(editor.isStroking, isFalse);
      await second.moveBy(const Offset(40, 0));
      expect(viewport.zoom, greaterThan(beforeZoom));
      await second.up();
      await first.moveBy(const Offset(12, 10));
      expect(editor.isStroking, isFalse);
      await first.up();
      expect(editor.canUndo, isFalse);
      // A cancelled stroke may invalidate a cached composite, but creates no history.
      expect(editor.revision, greaterThanOrEqualTo(beforeRevision));
      await unmount(tester, editor, viewport);
    },
  );

  testWidgets(
    'rotation handle outside the paper rotates and commits one undo',
    (tester) async {
      final editor = EditorController();
      final viewport = ViewportController();
      await tester.runAsync(() => editor.newDocument(120, 90));
      editor.setTool(EditorTool.transform);
      await mount(tester, editor, viewport);
      final top = viewport.documentToViewport(const Offset(60, 0));
      final center = viewport.documentToViewport(const Offset(60, 45));
      final handle = top - const Offset(0, 34);
      final radius = (handle - center).distance;
      final destination =
          center + Offset(radius * math.sin(.3), -radius * math.cos(.3));
      final gesture = await tester.startGesture(
        handle,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(destination);
      await gesture.up();
      expect(editor.activeLayer!.rotation, closeTo(.3, .00001));
      expect(editor.historyLength, 1);
      editor.undo();
      expect(editor.activeLayer!.rotation, 0);
      await unmount(tester, editor, viewport);
    },
  );
}
