import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';
import 'package:myphotoeditor/editor/editor_project_schema.dart';

Uint8List _changedProject(
  Uint8List bytes,
  void Function(Map<String, dynamic>) update,
) {
  final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  update(data);
  return Uint8List.fromList(utf8.encode(jsonEncode(data)));
}

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
  _scenario('accepted name boundary and empty documents round trip', (
    editor,
  ) async {
    final name = List.filled(
      EditorProjectSchema.maxLayerNameLength,
      '가',
    ).join();
    editor.renameLayer(editor.activeLayer!.id, name);
    final restored = EditorController();
    try {
      await restored.importProject(await editor.exportProject());
      expect(restored.activeLayer!.name, name);
      final before = editor.historyLength;
      expect(
        () => editor.renameLayer(editor.activeLayer!.id, '$name가'),
        throwsArgumentError,
      );
      expect(editor.activeLayer!.name, name);
      expect(editor.historyLength, before);
      editor.removeActiveLayer();
      await restored.importProject(await editor.exportProject());
      expect(restored.documentSize, const Size(32, 32));
      expect(restored.layers, isEmpty);
      expect(restored.activeLayer, isNull);
    } finally {
      restored.dispose();
    }
  });

  _scenario(
    'rejected text and transform values do not enter document history',
    (editor) async {
      final history = editor.historyLength;
      await expectLater(
        editor.addText(
          List.filled(EditorProjectSchema.maxTextLength + 1, 'a').join(),
        ),
        throwsArgumentError,
      );
      await expectLater(
        editor.addText('A', fontSize: double.nan),
        throwsArgumentError,
      );
      expect(editor.layers, hasLength(1));
      expect(editor.historyLength, history);
      expect(editor.isBusy, isFalse);
      expect(
        () => editor.setLayerBlendMode(ui.BlendMode.dstOut),
        throwsArgumentError,
      );
    },
  );

  _scenario(
    'invalid JSON keeps an active layer transform and its transaction',
    (editor) async {
      expect(editor.beginTransform(), isTrue);
      editor.setActiveTransform(offset: const Offset(7, 3), rotation: .2);
      final history = editor.historyLength;
      await expectLater(
        editor.importProject(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      expect(editor.hasActiveTransform, isTrue);
      expect(editor.activeLayer!.offset, const Offset(7, 3));
      expect(editor.activeLayer!.rotation, .2);
      expect(editor.historyLength, history);
      expect(editor.isBusy, isFalse);
      await editor.commitTransform();
      expect(editor.historyLength, history + 1);
    },
  );

  _scenario(
    'failure after decoding an earlier layer preserves the current preview',
    (editor) async {
      await editor.addLayer();
      final valid = await editor.exportProject();
      final invalid = _changedProject(valid, (root) {
        (root['layers'] as List).last['png'] = base64Encode([1, 2, 3]);
      });
      editor.setSelection(const Rect.fromLTWH(2, 2, 8, 8));
      expect(editor.beginTransform(), isTrue);
      editor.setActiveTransform(offset: const Offset(4, 6));
      final selection = editor.selection;
      final image = editor.activeLayer!.image;
      final memory = editor.historyBytes;
      final history = editor.historyLength;
      await expectLater(editor.importProject(invalid), throwsFormatException);
      expect(editor.hasActiveTransform, isTrue);
      expect(editor.selection, selection);
      expect(identical(editor.activeLayer!.image, image), isTrue);
      expect(editor.layers, hasLength(2));
      expect(editor.historyBytes, memory);
      expect(editor.historyLength, history);
      expect(editor.isBusy, isFalse);
      editor.cancelTransform();
      await editor.fillSelection(color: Colors.red);
      expect(editor.historyLength, history + 1);
      // The images decoded before the error are never retained by the document.
      await editor.importProject(valid);
      expect(editor.hasActiveTransform, isFalse);
      expect(editor.layers, hasLength(2));
    },
  );

  _scenario(
    'project metadata boundaries reject without replacing the document',
    (editor) async {
      final valid = await editor.exportProject();
      final image = editor.activeLayer!.image;
      final invalidProperties = <String, Object>{
        'name': List.filled(
          EditorProjectSchema.maxLayerNameLength + 1,
          'a',
        ).join(),
        'text': List.filled(EditorProjectSchema.maxTextLength + 1, 'a').join(),
        'fontFamily': List.filled(
          EditorProjectSchema.maxFontFamilyLength + 1,
          'a',
        ).join(),
        'opacity': 1.01,
        'brightness': -1.01,
        'contrast': 2.01,
        'saturation': -.01,
        'scale': .049,
        'rotation': EditorProjectSchema.maxRotation + 1,
        'offset': [EditorProjectSchema.maxCoordinate + 1, 0],
        'fontSize': EditorProjectSchema.maxFontSize + 1,
        'blendMode': 'dstOut',
        'png': 'not-base64!',
      };
      for (final entry in invalidProperties.entries) {
        final invalid = _changedProject(valid, (root) {
          (root['layers'] as List).first[entry.key] = entry.value;
        });
        await expectLater(editor.importProject(invalid), throwsFormatException);
        expect(
          identical(editor.activeLayer!.image, image),
          isTrue,
          reason: entry.key,
        );
        expect(editor.isBusy, isFalse, reason: entry.key);
      }
      for (final update in <void Function(Map<String, dynamic>)>[
        (root) => root['width'] = EditorProjectSchema.maxDocumentSide + 1,
        (root) => root['width'] = 31,
        (root) {
          final first = (root['layers'] as List).first;
          (root['layers'] as List).add(Map<String, dynamic>.from(first as Map));
        },
      ]) {
        await expectLater(
          editor.importProject(_changedProject(valid, update)),
          throwsFormatException,
        );
        expect(identical(editor.activeLayer!.image, image), isTrue);
        expect(editor.isBusy, isFalse);
      }
    },
  );

  _scenario('accepted metadata extremes remain readable after saving', (
    editor,
  ) async {
    final valid = await editor.exportProject();
    final boundary = _changedProject(valid, (root) {
      final layer = (root['layers'] as List).first as Map<String, dynamic>;
      layer.addAll(<String, dynamic>{
        'text': List.filled(EditorProjectSchema.maxTextLength, 'a').join(),
        'fontFamily': List.filled(
          EditorProjectSchema.maxFontFamilyLength,
          'a',
        ).join(),
        'offset': [
          -EditorProjectSchema.maxCoordinate,
          EditorProjectSchema.maxCoordinate,
        ],
        'textPosition': [
          EditorProjectSchema.maxCoordinate,
          -EditorProjectSchema.maxCoordinate,
        ],
        'rotation': EditorProjectSchema.maxRotation,
        'scale': EditorProjectSchema.maxScale,
        'fontSize': EditorProjectSchema.maxFontSize,
        'opacity': 0,
        'brightness': -1,
        'contrast': 2,
        'saturation': 0,
        'blendMode': 'plus',
      });
    });
    await editor.importProject(boundary);
    final saved = await editor.exportProject();
    final restored = EditorController();
    try {
      await restored.importProject(saved);
      final layer = restored.activeLayer!;
      expect(layer.text!.length, EditorProjectSchema.maxTextLength);
      expect(layer.fontSize, EditorProjectSchema.maxFontSize);
      expect(layer.scale, EditorProjectSchema.maxScale);
      expect(layer.rotation, EditorProjectSchema.maxRotation);
      expect(layer.blendMode, ui.BlendMode.plus);
      expect(layer.offset.dx, -EditorProjectSchema.maxCoordinate);
      expect(layer.offset.dy, EditorProjectSchema.maxCoordinate);
    } finally {
      restored.dispose();
    }
  });

  test('schema validates decoded budgets without allocating large images', () {
    EditorProjectSchema.validateDecodedBudget(4096, 4096, layerCount: 4);
    expect(
      () =>
          EditorProjectSchema.validateDecodedBudget(4096, 4096, layerCount: 5),
      throwsArgumentError,
    );
    EditorProjectSchema.validateDecodedBudget(
      4096,
      4096,
      layerCount: 2,
      maskCount: 2,
    );
    expect(
      () => EditorProjectSchema.validateDecodedBudget(
        4096,
        4096,
        layerCount: 3,
        maskCount: 2,
      ),
      throwsArgumentError,
    );
  });
}
