import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';

const _red = Color(0xffff0000);
const _blue = Color(0xff0000ff);
const _source = Rect.fromLTWH(10, 12, 16, 8);
const _outside = Rect.fromLTWH(36, 36, 12, 12);

Future<Uint8List> _pixels(EditorController editor) async {
  final recorder = ui.PictureRecorder();
  editor.paintDocument(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  try {
    final data = (await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!;
    return Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

List<int> _at(Uint8List pixels, int x, int y) =>
    pixels.sublist((y * 64 + x) * 4, (y * 64 + x) * 4 + 4);

Future<void> _fill(EditorController editor, Rect rect, Color color) async {
  editor.setSelection(rect);
  await editor.fillSelection(color: color);
}

void _scenario(String name, Future<void> Function(EditorController) body) {
  testWidgets(name, (tester) async {
    await tester.runAsync(() async {
      final editor = EditorController();
      try {
        await editor.newDocument(64, 64);
        await _fill(editor, _source, _red);
        await _fill(editor, _outside, _blue);
        editor.setSelection(_source);
        editor.setTool(EditorTool.transform);
        await body(editor);
      } finally {
        editor.dispose();
      }
    });
  });
}

void main() {
  _scenario('moving selected pixels preserves outside pixels and one undo', (
    editor,
  ) async {
    final before = await _pixels(editor);
    final history = editor.historyLength;
    final originalImage = editor.activeLayer!.image;
    final memory = editor.historyBytes;
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(12, 6));
    editor.setActiveTransform(offset: const Offset(18, 8));
    expect(editor.selection, _source.shift(const Offset(18, 8)));
    expect(editor.transformPoint(_source.center), const Offset(36, 24));
    expect(identical(editor.activeLayer!.image, originalImage), isTrue);
    expect(editor.historyBytes, memory);
    var pixels = await _pixels(editor);
    expect(_at(pixels, 12, 15)[3], 0);
    expect(_at(pixels, 30, 23), [255, 0, 0, 255]);
    expect(_at(pixels, 40, 40), [0, 0, 255, 255]);
    await editor.commitTransform();
    expect(editor.historyLength, history + 1);
    expect(editor.undoLabel, '선택 영역 변형');
    pixels = await _pixels(editor);
    expect(_at(pixels, 12, 15)[3], 0);
    expect(_at(pixels, 30, 23), [255, 0, 0, 255]);
    expect(_at(pixels, 40, 40), [0, 0, 255, 255]);
    editor.undo();
    expect(await _pixels(editor), before);
    expect(editor.selection, _source);
    editor.redo();
    expect(await _pixels(editor), pixels);
    expect(editor.selection, _source.shift(const Offset(18, 8)));
  });

  _scenario('rotation uses the selection center and carries its path', (
    editor,
  ) async {
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(rotation: math.pi / 2);
    expect(editor.transformCenter, _source.center);
    final point = editor.transformPoint(_source.topLeft);
    expect(point.dx, closeTo(22, .00001));
    expect(point.dy, closeTo(8, .00001));
    expect(editor.selectionPath!.contains(const Offset(18, 9)), isTrue);
    expect(editor.selectionPath!.contains(const Offset(11, 16)), isFalse);
    await editor.commitTransform();
    final pixels = await _pixels(editor);
    expect(_at(pixels, 18, 9), [255, 0, 0, 255]);
    expect(_at(pixels, 11, 16)[3], 0);
    expect(_at(pixels, 40, 40), [0, 0, 255, 255]);
  });

  _scenario('scaling changes only the selected pixels about their center', (
    editor,
  ) async {
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(scale: .5);
    await editor.commitTransform();
    expect(editor.selection, const Rect.fromLTWH(14, 14, 8, 4));
    final pixels = await _pixels(editor);
    expect(_at(pixels, 18, 16), [255, 0, 0, 255]);
    expect(_at(pixels, 11, 16)[3], 0);
    expect(_at(pixels, 24, 16)[3], 0);
    expect(_at(pixels, 40, 40), [0, 0, 255, 255]);
  });

  _scenario('lasso transforms the actual path rather than its rectangle', (
    editor,
  ) async {
    editor.clearSelection();
    await editor.fillSelection(color: _red);
    editor.setLassoSelection([
      const Offset(4, 4),
      const Offset(20, 4),
      const Offset(4, 20),
    ]);
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(24, 0));
    await editor.commitTransform();
    final pixels = await _pixels(editor);
    expect(_at(pixels, 6, 6)[3], 0);
    expect(_at(pixels, 18, 18), [255, 0, 0, 255]);
    expect(_at(pixels, 30, 6), [255, 0, 0, 255]);
    expect(editor.selectionPath!.contains(const Offset(30, 6)), isTrue);
    expect(editor.selectionPath!.contains(const Offset(42, 18)), isFalse);
  });

  _scenario('cancel restores the preview and creates no history', (
    editor,
  ) async {
    final before = await _pixels(editor);
    final history = editor.historyLength;
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(18, 8), rotation: .4);
    editor.cancelTransform();
    expect(editor.selection, _source);
    expect(await _pixels(editor), before);
    expect(editor.historyLength, history);
    expect(editor.isTransformingSelection, isFalse);
  });

  _scenario('click without a transform does not rasterize or add history', (
    editor,
  ) async {
    final original = editor.activeLayer!.image;
    final history = editor.historyLength;
    expect(editor.beginTransform(), isTrue);
    await editor.commitTransform();
    expect(identical(editor.activeLayer!.image, original), isTrue);
    expect(editor.historyLength, history);
  });

  _scenario('without a selection the whole layer keeps its editable geometry', (
    editor,
  ) async {
    editor.clearSelection();
    final original = editor.activeLayer!.image;
    final history = editor.historyLength;
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(
      offset: const Offset(3, 4),
      rotation: .2,
      scale: 1.2,
    );
    await editor.commitTransform();
    expect(editor.activeLayer!.offset, const Offset(3, 4));
    expect(editor.activeLayer!.rotation, .2);
    expect(editor.activeLayer!.scale, 1.2);
    expect(identical(editor.activeLayer!.image, original), isTrue);
    expect(editor.historyLength, history + 1);
    editor.undo();
    expect(editor.activeLayer!.offset, Offset.zero);
  });

  _scenario('locked and hidden layers cannot begin a selection transform', (
    editor,
  ) async {
    editor.toggleLayerLock(editor.activeLayerId!);
    expect(editor.beginTransform(), isFalse);
    editor.toggleLayerLock(editor.activeLayerId!);
    editor.toggleLayerVisibility(editor.activeLayerId!);
    expect(editor.beginTransform(), isFalse);
  });

  _scenario('existing layer geometry and adjustments are applied once', (
    editor,
  ) async {
    editor.clearSelection();
    editor.setLayerTransform(offset: const Offset(2, 2), scale: .5);
    editor.setAdjustments(brightness: .1, contrast: 1.2, saturation: .8);
    editor.setLayerOpacity(.5);
    editor.setSelection(const Rect.fromLTWH(23, 24, 8, 4));
    final before = await _pixels(editor);
    final outsidePixel = _at(before, 38, 38);
    final selectedPixel = _at(before, 26, 25);
    final originalLayer = editor.activeLayer!;
    expect(selectedPixel[3], closeTo(128, 1));
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(0, 10));
    await editor.commitTransform();
    final pixels = await _pixels(editor);
    expect(_at(pixels, 26, 25)[3], 0);
    expect(_at(pixels, 26, 35), selectedPixel);
    expect(_at(pixels, 38, 38), outsidePixel);
    expect(editor.activeLayer!.opacity, originalLayer.opacity);
    expect(editor.activeLayer!.brightness, originalLayer.brightness);
    editor.undo();
    expect(editor.activeLayer!.offset, originalLayer.offset);
    expect(editor.activeLayer!.scale, originalLayer.scale);
    expect(await _pixels(editor), before);
  });

  _scenario('masked selected pixels move with their visible alpha', (
    editor,
  ) async {
    editor.setSelectionPath(
      Path()
        ..addRect(const Rect.fromLTWH(10, 12, 8, 8))
        ..addRect(_outside),
    );
    await editor.createMaskFromSelection();
    editor.setSelection(_source);
    final before = await _pixels(editor);
    expect(_at(before, 12, 15), [255, 0, 0, 255]);
    expect(_at(before, 24, 15)[3], 0);
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(0, 12));
    await editor.commitTransform();
    final pixels = await _pixels(editor);
    expect(_at(pixels, 12, 15)[3], 0);
    expect(_at(pixels, 12, 27), [255, 0, 0, 255]);
    expect(_at(pixels, 24, 27)[3], 0);
    expect(_at(pixels, 40, 40), [0, 0, 255, 255]);
    editor.undo();
    expect(editor.activeLayer!.mask, isNotNull);
    expect(await _pixels(editor), before);
  });

  _scenario('document selection resolves an already rotated layer', (
    editor,
  ) async {
    editor.clearSelection();
    editor.setLayerTransform(rotation: math.pi / 2);
    editor.setSelection(const Rect.fromLTWH(44, 10, 8, 16));
    final before = await _pixels(editor);
    expect(_at(before, 48, 14), [255, 0, 0, 255]);
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(-12, 0));
    await editor.commitTransform();
    final pixels = await _pixels(editor);
    expect(_at(pixels, 48, 14)[3], 0);
    expect(_at(pixels, 36, 14), [255, 0, 0, 255]);
    expect(_at(pixels, 20, 40), _at(before, 20, 40));
    editor.undo();
    expect(editor.activeLayer!.rotation, math.pi / 2);
    expect(await _pixels(editor), before);
  });

  _scenario('overlapping movement cuts the source before placing pixels', (
    editor,
  ) async {
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(2, 0));
    var pixels = await _pixels(editor);
    expect(_at(pixels, 10, 15)[3], 0);
    expect(_at(pixels, 14, 15), [255, 0, 0, 255]);
    expect(_at(pixels, 26, 15), [255, 0, 0, 255]);
    await editor.commitTransform();
    pixels = await _pixels(editor);
    expect(_at(pixels, 10, 15)[3], 0);
    expect(_at(pixels, 14, 15), [255, 0, 0, 255]);
    expect(_at(pixels, 26, 15), [255, 0, 0, 255]);
  });

  _scenario('starting another pixel operation cancels the pending transform', (
    editor,
  ) async {
    final history = editor.historyLength;
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(18, 8));
    await editor.fillSelection(color: _blue);
    expect(editor.isTransformingSelection, isFalse);
    expect(editor.selection, _source);
    final pixels = await _pixels(editor);
    expect(_at(pixels, 12, 15), [0, 0, 255, 255]);
    expect(_at(pixels, 30, 23)[3], 0);
    expect(editor.historyLength, history + 1);
  });

  _scenario('project export commits the displayed transform before encoding', (
    editor,
  ) async {
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(18, 8));
    final project = await editor.exportProject();
    expect(editor.isTransformingSelection, isFalse);
    final restored = EditorController();
    try {
      await restored.importProject(project);
      final pixels = await _pixels(restored);
      expect(_at(pixels, 12, 15)[3], 0);
      expect(_at(pixels, 30, 23), [255, 0, 0, 255]);
      expect(_at(pixels, 40, 40), [0, 0, 255, 255]);
    } finally {
      restored.dispose();
    }
  });

  _scenario('disabled masks keep their geometry when enabled after moving', (
    editor,
  ) async {
    editor.setSelectionPath(
      Path()
        ..addRect(const Rect.fromLTWH(10, 12, 8, 8))
        ..addRect(_outside),
    );
    await editor.createMaskFromSelection();
    editor.toggleActiveMask();
    editor.setSelection(_source);
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(0, 12));
    await editor.commitTransform();
    expect(editor.activeLayer!.mask, isNotNull);
    expect(editor.activeLayer!.maskEnabled, isFalse);
    expect(_at(await _pixels(editor), 24, 27), [255, 0, 0, 255]);
    editor.toggleActiveMask();
    final pixels = await _pixels(editor);
    expect(_at(pixels, 12, 15)[3], 0);
    expect(_at(pixels, 12, 27), [255, 0, 0, 255]);
    expect(_at(pixels, 24, 27)[3], 0);
    expect(_at(pixels, 40, 40), [0, 0, 255, 255]);
  });

  _scenario('returning to the original transform keeps images and history', (
    editor,
  ) async {
    final original = editor.activeLayer!.image;
    final history = editor.historyLength;
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(20, 20), scale: 2);
    editor.setActiveTransform(offset: Offset.zero, scale: 1);
    await editor.commitTransform();
    expect(identical(editor.activeLayer!.image, original), isTrue);
    expect(editor.historyLength, history);
    expect(editor.selection, _source);
  });

  _scenario('cancelling during rasterization discards the pending image', (
    editor,
  ) async {
    final before = await _pixels(editor);
    final history = editor.historyLength;
    final memory = editor.historyBytes;
    expect(editor.beginTransform(), isTrue);
    editor.setActiveTransform(offset: const Offset(18, 8));
    final pending = editor.commitTransform();
    expect(editor.isBusy, isTrue);
    editor.setTool(EditorTool.brush);
    await pending;
    expect(editor.isBusy, isFalse);
    expect(editor.selection, _source);
    expect(editor.historyLength, history);
    expect(editor.historyBytes, memory);
    expect(await _pixels(editor), before);
  });
}
