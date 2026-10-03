import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_controller.dart';
import 'package:myphotoeditor/editor/editor_viewport.dart';

import 'widget_test.dart' show openEditor;

class _ProjectSavePicker extends FilePicker {
  int saves = 0;
  String? name;
  List<String>? extensions;
  Uint8List? data;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saves++;
    name = fileName;
    extensions = allowedExtensions;
    data = bytes;
    return null;
  }
}

Future<void> _routes(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _work(WidgetTester tester, EditorController editor) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
    if (!editor.isBusy) break;
  }
  expect(editor.isBusy, isFalse);
  expect(tester.takeException(), isNull);
}

Offset _canvasPoint(WidgetTester tester, Offset document) {
  final finder = find.byType(EditorViewport);
  final canvas = tester.widget<EditorViewport>(finder);
  return tester.getTopLeft(finder) +
      canvas.viewportController.documentToViewport(document);
}

Future<List<int>> _pixel(
  WidgetTester tester,
  EditorController editor,
  int x,
  int y,
) async {
  final image = editor.activeLayer!.image;
  final bytes = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
  );
  final offset = (y * image.width + x) * 4;
  return bytes!.buffer
      .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes)
      .sublist(offset, offset + 4);
}

Future<void> _selectTool(WidgetTester tester, String name) async {
  await tester.tap(find.byTooltip('모든 편집 도구'));
  await _routes(tester);
  final target = find.descendant(
    of: find.byType(BottomSheet),
    matching: find.text(name),
  );
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _routes(tester);
}

void main() {
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);

  testWidgets('all fifteen tools are reachable in the narrow mobile picker', (
    tester,
  ) async {
    final editor = await openEditor(tester, const Size(320, 700));
    for (final tool in <String, EditorTool>{
      '브러시': EditorTool.brush,
      '지우개': EditorTool.eraser,
      '복제 도장': EditorTool.cloneStamp,
      '스포이드': EditorTool.eyedropper,
      '영역 선택': EditorTool.marquee,
      '타원 선택': EditorTool.ellipticalMarquee,
      '올가미': EditorTool.lasso,
      '자동 선택': EditorTool.magicWand,
      '페인트 통': EditorTool.fill,
      '그라디언트': EditorTool.gradient,
      '사각형 도형': EditorTool.rectangle,
      '타원 도형': EditorTool.ellipse,
      '텍스트': EditorTool.text,
      '화면 이동': EditorTool.hand,
      '변형': EditorTool.transform,
    }.entries) {
      await _selectTool(tester, tool.key);
      expect(editor.tool, tool.value, reason: '${tool.key} should be tappable');
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'mobile picker selects lasso and supports clone source context control',
    (tester) async {
      final editor = await openEditor(tester, const Size(320, 700));
      await _selectTool(tester, '올가미');
      expect(editor.tool, EditorTool.lasso);
      final gesture = await tester.startGesture(
        _canvasPoint(tester, const Offset(300, 200)),
      );
      for (final point in [
        const Offset(900, 200),
        const Offset(300, 700),
        const Offset(300, 200),
      ]) {
        await gesture.moveTo(_canvasPoint(tester, point));
      }
      await gesture.up();
      await tester.pump();
      expect(editor.selectionKind, EditorSelectionKind.lasso);
      expect(editor.selectionPath!.contains(const Offset(400, 300)), isTrue);
      editor.clearSelection();
      await _selectTool(tester, '복제 도장');
      expect(editor.tool, EditorTool.cloneStamp);
      await tester.ensureVisible(find.text('복제 원본 지정'));
      await tester.pump();
      await tester.tap(find.text('복제 원본 지정'));
      await tester.pump();
      expect(editor.cloneSourcePickMode, isTrue);
      await tester.tapAt(_canvasPoint(tester, const Offset(500, 400)));
      await tester.pump();
      expect(
        (editor.cloneSource! - const Offset(500, 400)).distance,
        lessThan(.001),
      );
      expect(editor.cloneSourcePickMode, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'small mobile inspector switches all four tabs without overflow',
    (tester) async {
      final editor = await openEditor(tester, const Size(320, 700));
      await tester.tap(find.text('레이어 ${editor.layers.length}'));
      await _routes(tester);
      for (final title in ['조정', '필터', '기록', '레이어']) {
        final tab = find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text(title),
            )
            .first;
        await tester.tap(tab);
        await tester.pump();
        final content = switch (title) {
          '조정' => '빛과 색상',
          '필터' => '필터 · 효과',
          '기록' => '편집 기록',
          _ => '레이어 변형',
        };
        expect(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.text(content),
          ),
          findsOneWidget,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '$title panel should fit 320px',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'filter panel and parameter apply button change pixels and undo',
    (tester) async {
      final editor = await openEditor(tester, const Size(1440, 900));
      await tester.runAsync(() async {
        await editor.newDocument(32, 32);
        await editor.fillSelection(color: const Color(0xFFFF0000));
      });
      await tester.pump();
      await tester.tap(find.text('필터'));
      await tester.pump();
      await tester.tap(find.text('색상 반전'));
      await _work(tester, editor);
      expect(await _pixel(tester, editor, 16, 16), [0, 255, 255, 255]);
      await tester.tap(find.byTooltip('실행 취소 (Ctrl/⌘ Z)'));
      await tester.pump();
      expect(await _pixel(tester, editor, 16, 16), [255, 0, 0, 255]);
      await tester.ensureVisible(find.text('임계값'));
      await tester.pump();
      await tester.tap(find.text('임계값'));
      await _routes(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '적용'));
      await _routes(tester);
      await _work(tester, editor);
      expect(await _pixel(tester, editor, 16, 16), [0, 0, 0, 255]);
      await tester.tap(find.byTooltip('실행 취소 (Ctrl/⌘ Z)'));
      await tester.pump();
      expect(await _pixel(tester, editor, 16, 16), [255, 0, 0, 255]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'action sheet wires clipboard deletion mask and crop operations',
    (tester) async {
      final editor = await openEditor(tester, const Size(1440, 900));
      await tester.runAsync(() async {
        await editor.newDocument(32, 32);
        await editor.fillSelection(color: const Color(0xFFFF0000));
      });
      editor.setSelection(const Rect.fromLTWH(8, 8, 16, 16));
      await tester.pump();
      await tester.tap(find.byTooltip('선택 · 이미지 · 레이어 작업'));
      await _routes(tester);
      Future<void> action(String name) async {
        final target = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(name),
        );
        await tester.ensureVisible(target);
        await tester.pump();
        await tester.tap(target);
        await _work(tester, editor);
      }

      await action('복사');
      expect(editor.canPaste, isTrue);
      await action('선택 영역 삭제');
      expect((await _pixel(tester, editor, 16, 16))[3], 0);
      await action('붙여넣기');
      expect(editor.layers.length, 2);
      expect(await _pixel(tester, editor, 16, 16), [255, 0, 0, 255]);
      await action('선택 영역으로 마스크 만들기');
      expect(editor.activeLayer!.mask, isNotNull);
      await action('선택 영역으로 자르기');
      await _routes(tester);
      expect(editor.documentSize, const Size(16, 16));
      await tester.tap(find.byTooltip('실행 취소 (Ctrl/⌘ Z)'));
      await tester.pump();
      expect(editor.documentSize, const Size(32, 32));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'project menu is visible and Ctrl S saves editable data outside text input',
    (tester) async {
      final picker = _ProjectSavePicker();
      FilePicker.platform = picker;
      final editor = await openEditor(tester, const Size(1440, 900));
      await tester.runAsync(() => editor.newDocument(32, 32));
      await tester.pump();
      await tester.tap(find.byTooltip('문서 메뉴'));
      await _routes(tester);
      expect(find.text('프로젝트 열기 (.luma)'), findsOneWidget);
      expect(find.text('프로젝트 저장 (Ctrl/⌘ S)'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _routes(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _work(tester, editor);
      expect(picker.saves, 1);
      expect(picker.name, endsWith('.luma'));
      expect(picker.extensions, ['luma']);
      final record =
          jsonDecode(utf8.decode(picker.data!)) as Map<String, dynamic>;
      expect(record['format'], 'luma-studio');
      expect(record['layers'], hasLength(1));
      editor.setTool(EditorTool.text);
      await tester.pump();
      await tester.tapAt(_canvasPoint(tester, const Offset(16, 16)));
      await _routes(tester);
      await tester.enterText(find.byType(TextField).first, 'Editable text');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(picker.saves, 1);
      expect(find.text('Editable text'), findsOneWidget);
      expect(editor.tool, EditorTool.text);
      await tester.tap(find.text('취소'));
      await _routes(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
