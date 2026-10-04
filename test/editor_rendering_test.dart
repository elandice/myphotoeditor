import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';
import 'package:myphotoeditor/editor/editor_viewport.dart';

class _CountingEditor extends EditorController {
  int documentPaints = 0;

  @override
  void paintDocument(Canvas canvas, {bool includeStroke = true}) {
    documentPaints++;
    super.paintDocument(canvas, includeStroke: includeStroke);
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    _CountingEditor editor,
    ViewportController viewport,
  ) async {
    await tester.runAsync(() => editor.newDocument(32, 32));
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
    _CountingEditor editor,
    ViewportController viewport,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    editor.dispose();
    viewport.dispose();
  }

  testWidgets('selection ants, hover and tool previews retain document paint', (
    tester,
  ) async {
    final editor = _CountingEditor();
    final viewport = ViewportController();
    await mount(tester, editor, viewport);
    final settledPaints = editor.documentPaints;
    expect(settledPaints, greaterThan(0));

    editor.setSelection(const Rect.fromLTWH(4, 4, 16, 16));
    await tester.pump();
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(editor.documentPaints, settledPaints);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: viewport.documentToViewport(const Offset(8, 8)),
    );
    await mouse.moveTo(viewport.documentToViewport(const Offset(12, 12)));
    await tester.pump();
    expect(editor.documentPaints, settledPaints);
    await mouse.removePointer();

    editor.setTool(EditorTool.rectangle);
    final shape = await tester.startGesture(
      viewport.documentToViewport(const Offset(6, 6)),
    );
    await shape.moveTo(viewport.documentToViewport(const Offset(18, 18)));
    await tester.pump();
    expect(editor.documentPaints, settledPaints);
    await shape.cancel();
    await unmount(tester, editor, viewport);
  });

  testWidgets('stroke samples, settled content and zoom repaint the document', (
    tester,
  ) async {
    final editor = _CountingEditor();
    final viewport = ViewportController();
    await mount(tester, editor, viewport);
    var previousPaints = editor.documentPaints;

    editor.beginStroke(const Offset(8, 8));
    await tester.pump();
    expect(editor.documentPaints, greaterThan(previousPaints));
    previousPaints = editor.documentPaints;
    editor.appendStroke(const Offset(12, 12));
    await tester.pump();
    expect(editor.documentPaints, greaterThan(previousPaints));
    editor.cancelStroke();
    await tester.pump();

    previousPaints = editor.documentPaints;
    await tester.runAsync(
      () => editor.fillSelection(color: const Color(0xffff0000)),
    );
    await tester.pump();
    expect(editor.documentPaints, greaterThan(previousPaints));

    previousPaints = editor.documentPaints;
    viewport.zoomAt(const Offset(200, 200), 2);
    await tester.pump();
    expect(editor.documentPaints, greaterThan(previousPaints));

    final pixels = await tester.runAsync(
      () => editor.activeLayer!.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ),
    );
    expect(pixels!.getUint32(0), 0xff0000ff);
    await unmount(tester, editor, viewport);
  });
}
