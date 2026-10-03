import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';

Future<Uint8List> pixels(EditorController editor) async {
  final png = await editor.exportPng();
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    codec.dispose();
  }
}

List<int> pixel(Uint8List bytes, int x, int y, {int width = 32}) =>
    bytes.sublist((y * width + x) * 4, (y * width + x) * 4 + 4);

Future<void> dot(
  EditorController editor,
  Color color,
  Offset position, {
  double size = 12,
}) async {
  editor.setTool(EditorTool.brush);
  editor.setBrushColor(color);
  editor.setBrushSize(size);
  editor.beginStroke(position);
  await editor.endStroke();
}

void main() {
  testWidgets(
    'strokes undo and redo exact pixels; new edit discards redo branch',
    (tester) async {
      await tester.runAsync(() async {
        final editor = EditorController();
        try {
          await editor.newDocument(32, 32);
          await dot(editor, const Color(0xffff0000), const Offset(16, 16));
          expect(pixel(await pixels(editor), 16, 16), [255, 0, 0, 255]);
          editor.undo();
          expect(pixel(await pixels(editor), 16, 16)[3], 0);
          editor.redo();
          expect(pixel(await pixels(editor), 16, 16), [255, 0, 0, 255]);
          editor.undo();
          await dot(editor, const Color(0xff0000ff), const Offset(16, 16));
          expect(editor.canRedo, isFalse);
          expect(pixel(await pixels(editor), 16, 16), [0, 0, 255, 255]);
        } finally {
          editor.dispose();
        }
      });
    },
  );

  testWidgets('eraser only clears active layer and reveals the layer beneath', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final editor = EditorController();
      try {
        await editor.newDocument(32, 32);
        await dot(
          editor,
          const Color(0xffff0000),
          const Offset(16, 16),
          size: 30,
        );
        await editor.addLayer();
        await dot(
          editor,
          const Color(0xff0000ff),
          const Offset(16, 16),
          size: 24,
        );
        editor.setTool(EditorTool.eraser);
        editor.setBrushSize(10);
        editor.beginStroke(const Offset(16, 16));
        await editor.endStroke();
        final data = await pixels(editor);
        expect(pixel(data, 16, 16), [255, 0, 0, 255]);
        expect(pixel(data, 23, 16), [0, 0, 255, 255]);
        editor.undo();
        expect(pixel(await pixels(editor), 16, 16), [0, 0, 255, 255]);
      } finally {
        editor.dispose();
      }
    });
  });

  testWidgets('selection clips brush and transformed coordinates round-trip', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final editor = EditorController();
      try {
        await editor.newDocument(32, 32);
        editor.setSelection(const Rect.fromLTWH(12, 8, 8, 16));
        editor.setBrushColor(const Color(0xffff0000));
        editor.setBrushSize(12);
        editor.beginStroke(const Offset(2, 16));
        editor.appendStroke(const Offset(30, 16));
        await editor.endStroke();
        final selected = await pixels(editor);
        expect(pixel(selected, 10, 16)[3], 0);
        expect(pixel(selected, 16, 16), [255, 0, 0, 255]);
        expect(pixel(selected, 22, 16)[3], 0);
        editor.clearSelection();
        editor.setLayerTransform(
          offset: const Offset(4, -2),
          rotation: math.pi / 3,
          scale: 1.7,
        );
        final local = editor.documentToLayer(
          editor.layerToDocument(const Offset(3, 11), editor.activeLayer!),
          editor.activeLayer!,
        );
        expect(local.dx, closeTo(3, 0.00001));
        expect(local.dy, closeTo(11, 0.00001));
        editor.undo();
        expect(editor.activeLayer!.offset, Offset.zero);
      } finally {
        editor.dispose();
      }
    });
  });

  testWidgets(
    'metadata shares image memory and a slider gesture is one undo step',
    (tester) async {
      await tester.runAsync(() async {
        final editor = EditorController();
        try {
          await editor.newDocument(32, 32);
          final original = editor.activeLayer!;
          editor.beginTransaction('opacity gesture');
          editor.setLayerOpacity(0.8);
          editor.setLayerOpacity(0.5);
          editor.setLayerOpacity(0.2);
          editor.commitTransaction();
          expect(editor.historyLength, 1);
          expect(editor.historyBytes, 32 * 32 * 4);
          expect(identical(editor.activeLayer!.image, original.image), isTrue);
          editor.undo();
          expect(editor.activeLayer!.opacity, 1);
          editor.duplicateActiveLayer();
          expect(editor.layers.length, 2);
          expect(editor.historyBytes, 32 * 32 * 4);
          editor.toggleLayerLock(editor.activeLayerId!);
          editor.beginStroke(const Offset(16, 16));
          expect(editor.isStroking, isFalse);
          editor.setLayerOpacity(0.4);
          expect(editor.activeLayer!.opacity, 1);
        } finally {
          editor.dispose();
        }
      });
    },
  );

  testWidgets('snapshot eviction enforces image memory and step budgets', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final editor = EditorController(
        maxHistorySteps: 2,
        maxHistoryBytes: 32 * 32 * 4 * 2,
      );
      try {
        await editor.newDocument(32, 32);
        for (var index = 0; index < 6; index++) {
          await dot(
            editor,
            const Color(0xffff0000),
            Offset(3.0 + index * 4, 16),
            size: 3,
          );
        }
        expect(editor.historyLength, lessThanOrEqualTo(2));
        expect(editor.historyBytes, lessThanOrEqualTo(32 * 32 * 4 * 2));
        editor.undo();
        editor.redo();
        expect(pixel(await pixels(editor), 23, 16)[3], greaterThan(200));
      } finally {
        editor.dispose();
      }
    });
  });

  testWidgets(
    'layer ordering, visibility, blending, adjustments and import affect export',
    (tester) async {
      await tester.runAsync(() async {
        final editor = EditorController();
        final source = EditorController();
        try {
          await editor.newDocument(32, 32);
          await dot(
            editor,
            const Color(0xffff0000),
            const Offset(16, 16),
            size: 30,
          );
          final bottom = editor.activeLayerId!;
          await editor.addLayer();
          await dot(
            editor,
            const Color(0xff0000ff),
            const Offset(16, 16),
            size: 30,
          );
          final top = editor.activeLayerId!;
          editor.setLayerBlendMode(ui.BlendMode.multiply);
          expect(pixel(await pixels(editor), 16, 16), [0, 0, 0, 255]);
          editor.setLayerBlendMode(ui.BlendMode.srcOver);
          editor.toggleLayerVisibility(top);
          expect(pixel(await pixels(editor), 16, 16), [255, 0, 0, 255]);
          editor.toggleLayerVisibility(top);
          editor.moveLayer(bottom, 1);
          expect(pixel(await pixels(editor), 16, 16), [255, 0, 0, 255]);
          editor.selectLayer(bottom);
          editor.setAdjustments(saturation: 0);
          final gray = pixel(await pixels(editor), 16, 16);
          expect(gray[0], closeTo(gray[1], 1));
          expect(gray[1], closeTo(gray[2], 1));
          await source.newDocument(16, 8);
          await dot(source, Colors.green, const Offset(8, 4), size: 40);
          await editor.newDocument(32, 32);
          await editor.importImage(await source.exportPng(), 'wide.png');
          final imported = await pixels(editor);
          expect(pixel(imported, 16, 4)[3], 0);
          expect(pixel(imported, 16, 16)[3], 255);
          expect(editor.activeLayer!.name, 'wide.png');
        } finally {
          source.dispose();
          editor.dispose();
        }
      });
    },
  );

  testWidgets('text content remains editable and undo restores prior text', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final editor = EditorController();
      try {
        await editor.newDocument(120, 80);
        await editor.addText(
          'A',
          fontSize: 32,
          color: const Color(0xffff0000),
          position: const Offset(8, 8),
        );
        final original = editor.activeLayer!.image;
        final originalPixels = await pixels(editor);
        expect(originalPixels.where((byte) => byte > 0), isNotEmpty);
        await editor.updateText(
          'B',
          color: const Color(0xff0000ff),
          fontSize: 40,
        );
        expect(editor.activeLayer!.text, 'B');
        expect(editor.activeLayer!.fontSize, 40);
        expect(identical(editor.activeLayer!.image, original), isFalse);
        expect(await pixels(editor), isNot(equals(originalPixels)));
        editor.undo();
        expect(editor.activeLayer!.text, 'A');
        expect(editor.activeLayer!.color, const Color(0xffff0000));
        expect(identical(editor.activeLayer!.image, original), isTrue);
      } finally {
        editor.dispose();
      }
    });
  });

  testWidgets('document blend modes are independent of viewport background', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final editor = EditorController();
      try {
        await editor.newDocument(32, 32);
        await dot(editor, const Color(0xffff0000), const Offset(16, 16));
        editor.setLayerBlendMode(ui.BlendMode.multiply);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(const Color(0xff0000ff), ui.BlendMode.src);
        editor.paintDocument(canvas);
        final picture = recorder.endRecording();
        final image = await picture.toImage(32, 32);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          ))!.buffer.asUint8List();
          expect(pixel(bytes, 16, 16), [255, 0, 0, 255]);
          expect(pixel(bytes, 0, 0), [0, 0, 255, 255]);
        } finally {
          image.dispose();
          picture.dispose();
        }
      } finally {
        editor.dispose();
      }
    });
  });

  testWidgets('undo and redo safely settle an in-progress slider transaction', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final editor = EditorController();
      final withoutHistory = EditorController(maxHistorySteps: 0);
      try {
        await editor.newDocument(32, 32);
        editor.beginTransaction('opacity');
        editor.setLayerOpacity(0.5);
        expect(editor.canUndo, isTrue);
        editor.undo();
        expect(editor.activeLayer!.opacity, 1);
        expect(editor.canRedo, isTrue);
        editor.beginTransaction('new opacity');
        editor.setLayerOpacity(0.25);
        expect(editor.canRedo, isFalse);
        editor.redo();
        expect(editor.activeLayer!.opacity, 0.25);
        expect(editor.canRedo, isFalse);
        await withoutHistory.newDocument(32, 32);
        withoutHistory.beginTransaction('no budget');
        withoutHistory.setLayerOpacity(0.5);
        withoutHistory.undo();
        expect(withoutHistory.canUndo, isFalse);
      } finally {
        editor.dispose();
        withoutHistory.dispose();
      }
    });
  });

  testWidgets(
    'cancelling a stroke during rasterization discards its completion',
    (tester) async {
      await tester.runAsync(() async {
        final editor = EditorController();
        try {
          await editor.newDocument(32, 32);
          final before = editor.activeLayer!.image;
          editor.beginStroke(const Offset(16, 16));
          final completion = editor.endStroke();
          editor.cancelStroke();
          await completion;
          expect(editor.isBusy, isFalse);
          expect(editor.isStroking, isFalse);
          expect(editor.historyLength, 0);
          expect(identical(editor.activeLayer!.image, before), isTrue);
          expect(pixel(await pixels(editor), 16, 16)[3], 0);
          await dot(editor, const Color(0xffff0000), const Offset(16, 16));
          expect(pixel(await pixels(editor), 16, 16), [255, 0, 0, 255]);
        } finally {
          editor.dispose();
        }
      });
    },
  );

  testWidgets(
    'mounted RawImage owns a clone while a document image is released',
    (tester) async {
      final editor = EditorController();
      await tester.runAsync(() => editor.newDocument(32, 32));
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: AnimatedBuilder(
            animation: editor,
            builder: (context, _) => RawImage(image: editor.activeLayer!.image),
          ),
        ),
      );
      final before = editor.activeLayer!.image;
      await tester.runAsync(() => editor.newDocument(48, 48));
      expect(before.debugDisposed, isTrue);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      editor.dispose();
    },
  );
}
