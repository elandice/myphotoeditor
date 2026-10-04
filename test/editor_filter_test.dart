import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';

Future<Uint8List> _pixels(EditorController editor) async {
  final data = await editor.activeLayer!.image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

List<int> _at(Uint8List pixels, int x, int y, {int width = 5}) {
  final offset = (y * width + x) * 4;
  return pixels.sublist(offset, offset + 4);
}

void main() {
  for (final scenario in <(EditorFilter, double?, List<int>)>[
    (EditorFilter.invert, null, [155, 105, 55, 255]),
    (EditorFilter.grayscale, null, [143, 143, 143, 255]),
    (EditorFilter.sepia, null, [192, 171, 134, 255]),
    (EditorFilter.posterize, 4, [85, 170, 170, 255]),
    (EditorFilter.threshold, .5, [255, 255, 255, 255]),
  ]) {
    testWidgets('${scenario.$1.name} uses expected channels within selection', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final editor = EditorController();
        try {
          await editor.newDocument(5, 5);
          await editor.fillSelection(color: const Color(0xff6496c8));
          final before = await _pixels(editor);
          editor.setSelection(const Rect.fromLTWH(1, 1, 2, 2));
          await editor.applyFilter(scenario.$1, amount: scenario.$2);
          final pixels = await _pixels(editor);
          expect(_at(pixels, 1, 1), scenario.$3);
          expect(_at(pixels, 4, 4), [100, 150, 200, 255]);
          editor.undo();
          expect(await _pixels(editor), before);
        } finally {
          editor.dispose();
        }
      });
    });
  }

  testWidgets('auto contrast maps luminance endpoints and preserves alpha', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final editor = EditorController();
      try {
        await editor.newDocument(5, 5);
        await editor.fillSelection(color: const Color(0xff323232));
        editor.setSelection(const Rect.fromLTWH(1, 1, 2, 2));
        await editor.fillSelection(color: const Color(0xffc8c8c8));
        editor.clearSelection();
        final before = await _pixels(editor);
        await editor.applyFilter(EditorFilter.autoContrast);
        final pixels = await _pixels(editor);
        expect(_at(pixels, 0, 0), [0, 0, 0, 255]);
        expect(_at(pixels, 1, 1), [255, 255, 255, 255]);
        editor.undo();
        expect(await _pixels(editor), before);
      } finally {
        editor.dispose();
      }
    });
  });

  testWidgets(
    'sharpen increases an impulse without creating transparent halos',
    (tester) async {
      await tester.runAsync(() async {
        final editor = EditorController();
        try {
          await editor.newDocument(5, 5);
          await editor.fillSelection(color: const Color(0xff646464));
          editor.setSelection(const Rect.fromLTWH(2, 2, 1, 1));
          await editor.fillSelection(color: const Color(0xff787878));
          editor.clearSelection();
          final before = await _pixels(editor);
          await editor.applyFilter(EditorFilter.sharpen, amount: 1);
          final pixels = await _pixels(editor);
          expect(_at(pixels, 2, 2), [200, 200, 200, 255]);
          expect(_at(pixels, 1, 2), [80, 80, 80, 255]);
          expect(_at(pixels, 0, 0), [100, 100, 100, 255]);
          editor.undo();
          expect(await _pixels(editor), before);

          await editor.newDocument(5, 5);
          editor.setSelection(const Rect.fromLTWH(2, 2, 1, 1));
          await editor.fillSelection(color: const Color(0xffff0000));
          editor.clearSelection();
          await editor.applyFilter(EditorFilter.sharpen, amount: 1);
          final sparse = await _pixels(editor);
          expect(_at(sparse, 2, 2), [255, 0, 0, 255]);
          expect(_at(sparse, 1, 2)[3], 0);
        } finally {
          editor.dispose();
        }
      });
    },
  );

  testWidgets('gaussian blur smooths an impulse and undo restores its pixels', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final editor = EditorController();
      try {
        await editor.newDocument(5, 5);
        await editor.fillSelection(color: const Color(0xff646464));
        editor.setSelection(const Rect.fromLTWH(2, 2, 1, 1));
        await editor.fillSelection(color: Colors.white);
        editor.clearSelection();
        final before = await _pixels(editor);
        await editor.applyFilter(EditorFilter.gaussianBlur, amount: 1);
        final pixels = await _pixels(editor);
        expect(_at(pixels, 2, 2)[0], inExclusiveRange(100, 255));
        expect(_at(pixels, 1, 2)[0], greaterThan(100));
        expect(_at(pixels, 2, 2)[3], 255);
        editor.undo();
        expect(await _pixels(editor), before);
      } finally {
        editor.dispose();
      }
    });
  });
}
