import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_color_picker.dart';

import 'widget_test.dart' show openEditor;

Future<void> _routes(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  testWidgets(
    'custom brush color applies to pixels and remains in the palette',
    (tester) async {
      final editor = await openEditor(tester, const Size(1440, 900));
      expect(editor.brushColor, Colors.black);
      await tester.tap(find.byTooltip('색 편집').first);
      await _routes(tester);
      expect(find.byType(EditorColorPickerDialog), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('color-hex')), '17B8CA');
      await tester.pump();
      expect(editor.brushColor, Colors.black);
      await tester.tap(find.text('사용자 지정 색에 추가'));
      await tester.pump();
      await tester.tap(find.text('적용'));
      await _routes(tester);
      const selected = Color(0xff17b8ca);
      expect(editor.brushColor, selected);
      expect(editor.isDirty, isFalse);
      final palette = tester.widget<EditorColorPalette>(
        find.byType(EditorColorPalette),
      );
      expect(palette.customColors, contains(selected));

      editor.beginStroke(const Offset(600, 450));
      editor.appendStroke(const Offset(620, 450));
      await tester.runAsync(editor.endStroke);
      final data = await tester.runAsync(
        () => editor.activeLayer!.image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ),
      );
      final pixels = data!.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final offset = (450 * 1200 + 610) * 4;
      expect(pixels.sublist(offset, offset + 4), [23, 184, 202, 255]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone color editor cancels without changing the brush', (
    tester,
  ) async {
    final editor = await openEditor(tester, const Size(320, 700));
    await tester.tap(find.byTooltip('색 편집').first);
    await _routes(tester);
    expect(find.byType(EditorColorPickerDialog), findsOneWidget);
    final hex = find.byKey(const ValueKey('color-hex'));
    await tester.ensureVisible(hex);
    await tester.enterText(hex, 'FF0000');
    await tester.pump();
    await tester.tap(find.text('취소'));
    await _routes(tester);
    expect(editor.brushColor, Colors.black);
    expect(editor.isDirty, isFalse);
    expect(find.byType(EditorColorPickerDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
