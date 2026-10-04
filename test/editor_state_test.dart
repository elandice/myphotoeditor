import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';

void _scenario(
  String name,
  Future<void> Function(EditorController editor) check, {
  int maxHistoryBytes = 128 << 20,
}) {
  testWidgets(name, (tester) async {
    await tester.runAsync(() async {
      final editor = EditorController(maxHistoryBytes: maxHistoryBytes);
      try {
        await editor.newDocument(32, 32);
        await check(editor);
      } finally {
        editor.dispose();
      }
    });
  });
}

Future<int> _alpha(EditorController editor, int x, int y) async {
  final bytes = await editor.exportPng();
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  try {
    final pixels = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    return pixels!.getUint8((y * 32 + x) * 4 + 3);
  } finally {
    image.dispose();
    codec.dispose();
  }
}

void main() {
  _scenario('live strokes reject other edits without losing pointer-up', (
    editor,
  ) async {
    await editor.copySelection();
    final layer = editor.activeLayer!;
    editor.beginStroke(const Offset(16, 16));

    // Paste used to acquire busy here, making the subsequent endStroke return
    // before committing and leaving the editor permanently in a live stroke.
    final paste = editor.pasteSelection();
    await editor.addLayer();
    await editor.addText('Another edit');
    await editor.createMaskFromSelection();
    await editor.fillSelection();
    await editor.applyFilter(EditorFilter.invert);
    await editor.magicWand(const Offset(16, 16));
    expect(await editor.sampleColor(const Offset(16, 16)), isNull);
    editor.setLayerOpacity(.5);
    editor.duplicateActiveLayer();
    editor.removeActiveLayer();
    expect(editor.layers, hasLength(1));
    expect(editor.activeLayer!.opacity, 1);
    expect(editor.isBusy, isFalse);

    await editor.endStroke();
    await paste;
    expect(editor.isStroking, isFalse);
    expect(editor.isBusy, isFalse);
    expect(editor.historyLength, 1);
    expect(await _alpha(editor, 16, 16), greaterThan(200));
    editor.undo();
    expect(identical(editor.activeLayer!.image, layer.image), isTrue);
    expect(await _alpha(editor, 16, 16), 0);
    await editor.pasteSelection();
    expect(editor.layers, hasLength(2));
  });

  _scenario('repeated endStroke calls await the same raster commit', (
    editor,
  ) async {
    editor.beginStroke(const Offset(16, 16));
    final first = editor.endStroke();
    final second = editor.endStroke();
    expect(identical(first, second), isTrue);
    await second;
    expect(editor.isBusy, isFalse);
    expect(editor.isStroking, isFalse);
    expect(editor.historyLength, 1);
    expect(await _alpha(editor, 16, 16), greaterThan(200));
  });

  _scenario(
    'over-budget current content retains zero-image-cost metadata Undo',
    (editor) async {
      await editor.addLayer();
      await editor.addLayer();
      final before = editor.historyLength;
      expect(editor.historyBytes, 32 * 32 * 4 * 3);
      editor.setLayerOpacity(.25);
      expect(editor.historyLength, before + 1);
      editor.undo();
      expect(editor.activeLayer!.opacity, 1);
      expect(editor.canRedo, isTrue);
      editor.redo();
      expect(editor.activeLayer!.opacity, .25);

      // Actual old raster allocations are still evicted beyond the baseline.
      editor.beginStroke(const Offset(16, 16));
      await editor.endStroke();
      expect(editor.historyBytes, 32 * 32 * 4 * 3);
      expect(editor.historyLength, 0);
    },
    maxHistoryBytes: 32 * 32 * 4 * 2,
  );

  _scenario('saved content identity survives Undo/Redo and async save races', (
    editor,
  ) async {
    expect(editor.isDirty, isFalse);
    await editor.fillSelection(color: Colors.red);
    expect(editor.isDirty, isTrue);
    final saved = editor.documentToken;
    editor.markSaved(token: saved);
    expect(editor.isDirty, isFalse);
    editor.setSelection(const Rect.fromLTWH(4, 4, 16, 16));
    editor.setTool(EditorTool.hand);
    editor.setBrushColor(Colors.blue);
    expect(editor.documentToken, saved);
    expect(editor.isDirty, isFalse);

    editor.setLayerOpacity(.5);
    final changed = editor.documentToken;
    expect(changed, isNot(saved));
    expect(editor.isDirty, isTrue);
    editor.undo();
    expect(editor.documentToken, saved);
    expect(editor.isDirty, isFalse);
    editor.redo();
    expect(editor.documentToken, changed);
    expect(editor.isDirty, isTrue);
    editor.markSaved(token: saved);
    expect(editor.isDirty, isTrue);
    editor.markSaved(token: changed);
    expect(editor.isDirty, isFalse);
  });

  _scenario('transient transforms and strokes become clean when cancelled', (
    editor,
  ) async {
    final saved = editor.documentToken;
    editor.beginTransform();
    expect(editor.isDirty, isFalse);
    editor.setActiveTransform(offset: const Offset(3, 4));
    expect(editor.isDirty, isTrue);
    editor.cancelTransform();
    expect(editor.documentToken, saved);
    expect(editor.isDirty, isFalse);
    editor.beginTransform();
    editor.setActiveTransform(offset: const Offset(3, 4));
    await editor.commitTransform();
    expect(editor.documentToken, isNot(saved));
    expect(editor.isDirty, isTrue);
    editor.undo();
    expect(editor.isDirty, isFalse);
    editor.beginStroke(const Offset(16, 16));
    expect(editor.isDirty, isTrue);
    editor.cancelStroke();
    expect(editor.isDirty, isFalse);
    editor.markUnsaved();
    expect(editor.isDirty, isTrue);
  });

  _scenario('PNG export serializes content edits and does not mark saved', (
    editor,
  ) async {
    await editor.fillSelection(color: Colors.red);
    final token = editor.documentToken;
    final export = editor.exportPng();
    expect(editor.isBusy, isTrue);
    editor.setLayerOpacity(0);
    await editor.addLayer();
    await export;
    expect(editor.activeLayer!.opacity, 1);
    expect(editor.layers, hasLength(1));
    expect(editor.documentToken, token);
    expect(editor.isDirty, isTrue);
    expect(editor.isBusy, isFalse);
  });

  _scenario('document replacement resets pending history and dirty identity', (
    editor,
  ) async {
    editor.beginTransaction('opacity');
    editor.setLayerOpacity(.5);
    expect(editor.canUndo, isTrue);
    final token = editor.documentToken;
    await editor.newDocument(32, 32);
    expect(editor.documentToken, isNot(token));
    expect(editor.isDirty, isFalse);
    expect(editor.canUndo, isFalse);
    expect(editor.canRedo, isFalse);
    editor.markUnsaved();
    final bytes = await editor.exportProject();
    expect(editor.isDirty, isTrue);
    await editor.importProject(bytes);
    expect(editor.isDirty, isFalse);
  });

  _scenario('invalid edit arguments preserve an active transform preview', (
    editor,
  ) async {
    editor.beginTransform();
    editor.setActiveTransform(offset: const Offset(3, 4));
    await expectLater(
      editor.addText('invalid size', fontSize: 1001),
      throwsArgumentError,
    );
    await expectLater(
      editor.addLayer(name: List.filled(501, 'x').join()),
      throwsArgumentError,
    );
    await expectLater(editor.resizeDocument(4097, 32), throwsArgumentError);
    expect(editor.hasActiveTransform, isTrue);
    expect(editor.activeTransformOffset, const Offset(3, 4));
    expect(editor.isDirty, isTrue);
    editor.cancelTransform();
    expect(editor.isDirty, isFalse);
  });

  _scenario('failed image decoding preserves pending transform and content', (
    editor,
  ) async {
    final original = editor.activeLayer!.image;
    final token = editor.documentToken;
    editor.beginTransform();
    editor.setActiveTransform(offset: const Offset(3, 4));
    await expectLater(
      editor.importImage(Uint8List.fromList([1, 2, 3]), 'broken'),
      throwsA(anything),
    );
    expect(editor.hasActiveTransform, isTrue);
    expect(editor.activeTransformOffset, const Offset(3, 4));
    expect(identical(editor.activeLayer!.image, original), isTrue);
    expect(editor.documentToken, token);
    expect(editor.isBusy, isFalse);
    await editor.commitTransform();
    expect(editor.activeLayer!.offset, const Offset(3, 4));
    expect(editor.documentToken, isNot(token));
  });

  _scenario('text updates do not revive cancelled transform preview geometry', (
    editor,
  ) async {
    await editor.addText('before', fontSize: 16);
    editor.markSaved();
    editor.beginTransform();
    editor.setActiveTransform(offset: const Offset(3, 4));
    await editor.updateText('after');
    expect(editor.activeLayer!.text, 'after');
    expect(editor.activeLayer!.offset, Offset.zero);
    expect(editor.hasActiveTransform, isFalse);
    expect(editor.isDirty, isTrue);
    editor.undo();
    expect(editor.activeLayer!.text, 'before');
    expect(editor.isDirty, isFalse);
  });
}
