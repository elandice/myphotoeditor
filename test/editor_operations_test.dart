import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';

Future<Uint8List> _pixels(EditorController editor) async {
  final codec = await ui.instantiateImageCodec(await editor.exportPng());
  final image = (await codec.getNextFrame()).image;
  try {
    final bytes = (await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!;
    return Uint8List.fromList(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  } finally {
    image.dispose();
    codec.dispose();
  }
}

List<int> _at(Uint8List pixels, int x, int y, {int width = 32}) =>
    pixels.sublist((y * width + x) * 4, (y * width + x) * 4 + 4);

void _scenario(String name, Future<void> Function(EditorController) body) {
  testWidgets(name, (tester) async {
    await tester.runAsync(() async {
      final editor = EditorController();
      try {
        await editor.newDocument(32, 32);
        await body(editor);
      } finally {
        editor.dispose();
      }
    });
  });
}

void main() {
  _scenario('ellipse and lasso clip actual painted pixels', (editor) async {
    editor.setBrushColor(Colors.red);
    editor.setEllipseSelection(const Rect.fromLTWH(4, 4, 24, 24));
    await editor.fillSelection();
    var pixels = await _pixels(editor);
    expect(_at(pixels, 16, 16), [244, 67, 54, 255]);
    expect(_at(pixels, 5, 5)[3], 0);
    editor.undo();
    editor.setLassoSelection([
      const Offset(2, 2),
      const Offset(30, 2),
      const Offset(2, 30),
    ]);
    editor.setBrushColor(const Color(0xFF0000FF));
    await editor.fillSelection();
    pixels = await _pixels(editor);
    expect(_at(pixels, 6, 6), [0, 0, 255, 255]);
    expect(_at(pixels, 26, 26)[3], 0);
  });

  _scenario(
    'cut and paste preserve selected transparency and undo independently',
    (editor) async {
      await editor.fillSelection(color: const Color(0xFFFF0000));
      editor.setSelection(const Rect.fromLTWH(8, 8, 16, 16));
      final history = editor.historyLength;
      await editor.cutSelection();
      expect(_at(await _pixels(editor), 16, 16)[3], 0);
      expect(_at(await _pixels(editor), 2, 2), [255, 0, 0, 255]);
      await editor.pasteSelection();
      expect(editor.layers.length, 2);
      expect(editor.historyLength, history + 2);
      final image = editor.activeLayer!.image;
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!.buffer.asUint8List();
      expect(_at(bytes, 16, 16), [255, 0, 0, 255]);
      expect(_at(bytes, 2, 2)[3], 0);
      editor.undo();
      expect(editor.layers.length, 1);
      expect(_at(await _pixels(editor), 16, 16)[3], 0);
      editor.undo();
      expect(_at(await _pixels(editor), 16, 16), [255, 0, 0, 255]);
    },
  );

  _scenario(
    'mask hides pixels without deleting them and supports invert and undo',
    (editor) async {
      await editor.fillSelection(color: const Color(0xFFFF0000));
      editor.setEllipseSelection(const Rect.fromLTWH(6, 6, 20, 20));
      await editor.createMaskFromSelection();
      var pixels = await _pixels(editor);
      expect(_at(pixels, 16, 16), [255, 0, 0, 255]);
      expect(_at(pixels, 2, 2)[3], 0);
      final source = (await editor.activeLayer!.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!.buffer.asUint8List();
      expect(_at(source, 2, 2), [255, 0, 0, 255]);
      await editor.invertActiveMask();
      pixels = await _pixels(editor);
      expect(_at(pixels, 16, 16)[3], 0);
      expect(_at(pixels, 2, 2), [255, 0, 0, 255]);
      editor.undo();
      expect(_at(await _pixels(editor), 16, 16), [255, 0, 0, 255]);
      editor.toggleActiveMask();
      expect(_at(await _pixels(editor), 2, 2), [255, 0, 0, 255]);
    },
  );

  _scenario('wand and bucket respect connected regions and current selection', (
    editor,
  ) async {
    await editor.fillSelection(color: Colors.white);
    editor.setBrushColor(Colors.black);
    await editor.drawShape(const Rect.fromLTWH(14, 0, 4, 32), ellipse: false);
    await editor.magicWand(const Offset(4, 16), tolerance: 0);
    expect(editor.selectionPath!.contains(const Offset(4, 16)), isTrue);
    expect(editor.selectionPath!.contains(const Offset(26, 16)), isFalse);
    editor.setBrushColor(const Color(0xFF0000FF));
    await editor.floodFill(const Offset(26, 16), tolerance: 0);
    expect(_at(await _pixels(editor), 26, 16), [255, 255, 255, 255]);
    editor.clearSelection();
    await editor.floodFill(const Offset(26, 16), tolerance: 0);
    final pixels = await _pixels(editor);
    expect(_at(pixels, 26, 16), [0, 0, 255, 255]);
    expect(_at(pixels, 4, 16), [255, 255, 255, 255]);
    expect(_at(pixels, 16, 16), [0, 0, 0, 255]);
  });

  _scenario('clone stamp maps source and target through layer transforms', (
    editor,
  ) async {
    editor.setBrushColor(const Color(0xFFFF0000));
    await editor.drawShape(const Rect.fromLTWH(3, 3, 10, 10), ellipse: false);
    editor.setLayerTransform(
      offset: const Offset(3, 2),
      rotation: .2,
      scale: 1.1,
    );
    final source = editor.layerToDocument(
      const Offset(8, 8),
      editor.activeLayer!,
    );
    final target = editor.layerToDocument(
      const Offset(21, 21),
      editor.activeLayer!,
    );
    editor.setCloneSource(source);
    editor.setTool(EditorTool.cloneStamp);
    editor.setBrushSize(6);
    editor.beginStroke(target);
    await editor.endStroke();
    final bytes = (await editor.activeLayer!.image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!.buffer.asUint8List();
    expect(_at(bytes, 21, 21), [255, 0, 0, 255]);
    editor.undo();
    final previous = (await editor.activeLayer!.image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!.buffer.asUint8List();
    expect(_at(previous, 21, 21)[3], 0);
  });

  _scenario('resize rotate and crop change geometry with recoverable pixels', (
    editor,
  ) async {
    await editor.newDocument(32, 24);
    editor.setBrushColor(const Color(0xFFFF0000));
    await editor.drawShape(const Rect.fromLTWH(0, 0, 16, 24), ellipse: false);
    await editor.resizeDocument(64, 48);
    expect(editor.documentSize, const Size(64, 48));
    expect(_at(await _pixels(editor), 12, 12, width: 64), [255, 0, 0, 255]);
    expect(_at(await _pixels(editor), 48, 12, width: 64)[3], 0);
    editor.undo();
    await editor.rotateDocument();
    expect(editor.documentSize, const Size(24, 32));
    expect(_at(await _pixels(editor), 12, 8, width: 24), [255, 0, 0, 255]);
    expect(_at(await _pixels(editor), 12, 24, width: 24)[3], 0);
    editor.undo();
    editor.setSelection(const Rect.fromLTWH(8, 4, 12, 10));
    await editor.cropToSelection();
    expect(editor.documentSize, const Size(12, 10));
    expect(_at(await _pixels(editor), 2, 2, width: 12), [255, 0, 0, 255]);
    expect(_at(await _pixels(editor), 10, 2, width: 12)[3], 0);
    editor.undo();
    expect(editor.documentSize, const Size(32, 24));
    expect(editor.selection, const Rect.fromLTWH(8, 4, 12, 10));
  });

  _scenario('filters honor selection and retain partially transparent colors', (
    editor,
  ) async {
    await editor.fillSelection(color: const Color(0xFF204080));
    editor.setSelection(const Rect.fromLTWH(0, 0, 16, 32));
    await editor.applyFilter(EditorFilter.invert);
    var pixels = await _pixels(editor);
    expect(_at(pixels, 8, 8), [223, 191, 127, 255]);
    expect(_at(pixels, 24, 8), [32, 64, 128, 255]);
    editor.undo();
    editor.clearSelection();
    await editor.applyFilter(EditorFilter.grayscale);
    final gray = _at(await _pixels(editor), 8, 8);
    expect(gray[0], gray[1]);
    expect(gray[1], gray[2]);
    await editor.newDocument(32, 32);
    await editor.fillSelection(color: const Color(0x80FF0000));
    await editor.applyFilter(EditorFilter.invert);
    pixels = await _pixels(editor);
    final translucent = _at(pixels, 8, 8);
    expect(translucent[0], 0);
    expect(translucent[1], greaterThanOrEqualTo(253));
    expect(translucent[2], greaterThanOrEqualTo(253));
    expect(translucent[3], 128);
  });

  _scenario(
    'merge and flatten retain visible composite and undo layer structure',
    (editor) async {
      await editor.fillSelection(color: const Color(0xFFFF0000));
      await editor.addLayer();
      await editor.fillSelection(color: const Color(0xFF0000FF));
      editor.setLayerOpacity(.5);
      final composite = await _pixels(editor);
      await editor.mergeDown();
      expect(editor.layers.length, 1);
      expect(await _pixels(editor), composite);
      editor.undo();
      expect(editor.layers.length, 2);
      editor.toggleLayerVisibility(editor.activeLayerId!);
      final visible = await _pixels(editor);
      await editor.flattenDocument();
      expect(editor.layers.length, 1);
      expect(await _pixels(editor), visible);
      editor.undo();
      expect(editor.layers.length, 2);
      expect(editor.activeLayer!.visible, isFalse);
    },
  );

  _scenario(
    'editable project round trip retains masks text transforms and pixels',
    (editor) async {
      await editor.fillSelection(color: const Color(0xFFFF0000));
      editor.setSelection(const Rect.fromLTWH(4, 4, 24, 24));
      await editor.createMaskFromSelection();
      editor.clearSelection();
      editor.setLayerTransform(
        offset: const Offset(1, 2),
        rotation: .12,
        scale: .8,
      );
      editor.setLayerOpacity(.7);
      await editor.addText(
        'A',
        fontSize: 16,
        color: Colors.blue,
        position: const Offset(8, 8),
      );
      final project = await editor.exportProject();
      final expected = await _pixels(editor);
      final restored = EditorController();
      try {
        await restored.newDocument(16, 16);
        await restored.importProject(project);
        expect(restored.documentSize, const Size(32, 32));
        expect(restored.layers.length, 2);
        expect(restored.layers.first.mask, isNotNull);
        expect(restored.layers.first.offset, const Offset(1, 2));
        expect(restored.layers.first.rotation, .12);
        expect(restored.layers.first.scale, .8);
        expect(restored.layers.first.opacity, .7);
        expect(restored.activeLayer!.text, 'A');
        expect(await _pixels(restored), expected);
        restored.undo();
        expect(restored.documentSize, const Size(16, 16));
        expect(restored.layers.length, 1);
      } finally {
        restored.dispose();
      }
    },
  );

  _scenario('merge prevents blend changes and flatten preserves the backdrop', (
    editor,
  ) async {
    await editor.fillSelection(color: const Color(0xFFFF0000));
    await editor.addLayer();
    await editor.fillSelection(color: const Color(0xFFFFFFFF));
    editor.setLayerBlendMode(ui.BlendMode.multiply);
    await editor.addLayer();
    await editor.fillSelection(color: const Color(0xFF0000FF));
    editor.setLayerOpacity(.5);
    final before = await _pixels(editor);
    await expectLater(editor.mergeDown(), throwsStateError);
    expect(editor.layers.length, 3);
    expect(await _pixels(editor), before);
    await editor.flattenDocument();
    expect(editor.layers.length, 1);
    expect(await _pixels(editor), before);
    editor.undo();
    expect(editor.layers.length, 3);
    expect(await _pixels(editor), before);
  });

  _scenario('clipboard preserves pixel size on a differently sized document', (
    editor,
  ) async {
    editor.setSelection(const Rect.fromLTWH(8, 8, 10, 10));
    await editor.fillSelection(color: const Color(0xFFFF0000));
    await editor.copySelection();
    await editor.newDocument(64, 64);
    await editor.pasteSelection();
    final pixels = await _pixels(editor);
    expect(_at(pixels, 9, 9, width: 64), [255, 0, 0, 255]);
    expect(_at(pixels, 19, 9, width: 64)[3], 0);
    expect(_at(pixels, 25, 25, width: 64)[3], 0);
  });

  _scenario(
    'async cut keeps its layer and selection when UI changes are attempted',
    (editor) async {
      await editor.fillSelection(color: const Color(0xFFFF0000));
      final first = editor.activeLayerId!;
      await editor.addLayer();
      await editor.fillSelection(color: const Color(0xFF0000FF));
      final second = editor.activeLayerId!;
      editor.selectLayer(first);
      editor.setSelection(const Rect.fromLTWH(8, 8, 16, 16));
      final cutting = editor.cutSelection();
      expect(editor.isBusy, isTrue);
      editor.selectLayer(second);
      editor.clearSelection();
      expect(editor.activeLayerId, first);
      expect(editor.selection, const Rect.fromLTWH(8, 8, 16, 16));
      await cutting;
      final firstBytes = (await editor.activeLayer!.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      ))!.buffer.asUint8List();
      expect(_at(firstBytes, 16, 16)[3], 0);
      expect(_at(firstBytes, 2, 2), [255, 0, 0, 255]);
      editor.selectLayer(second);
      expect(_at(await _pixels(editor), 16, 16), [0, 0, 255, 255]);
    },
  );

  _scenario('corrupt project rejects atomically and leaves the editor usable', (
    editor,
  ) async {
    await editor.fillSelection(color: const Color(0xFFFF0000));
    final before = await _pixels(editor);
    final encoded = await editor.exportProject();
    final project = jsonDecode(utf8.decode(encoded)) as Map<String, dynamic>;
    (project['layers'] as List).first['scale'] = 'broken';
    await expectLater(
      editor.importProject(
        Uint8List.fromList(utf8.encode(jsonEncode(project))),
      ),
      throwsFormatException,
    );
    expect(editor.isBusy, isFalse);
    expect(editor.layers.length, 1);
    expect(await _pixels(editor), before);
    await expectLater(
      editor.importProject(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    await editor.fillSelection(color: const Color(0xFF0000FF));
    expect(_at(await _pixels(editor), 16, 16), [0, 0, 255, 255]);
  });
}
