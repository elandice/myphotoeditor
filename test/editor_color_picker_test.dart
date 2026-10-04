import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/editor/editor_color_picker.dart';

Finder _key(String value) => find.byKey(ValueKey(value));

String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(_key(key)).controller!.text;

Future<void> _input(WidgetTester tester, String key, String text) async {
  await tester.ensureVisible(_key(key));
  await tester.enterText(_key(key), text);
  await tester.pump();
}

Future<void> _open(
  WidgetTester tester, {
  Color initial = const Color(0xff112233),
  List<Color> customColors = const [],
  required ValueChanged<EditorColorSelection?> onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async => onResult(
                await showDialog<EditorColorSelection>(
                  context: context,
                  builder: (_) => EditorColorPickerDialog(
                    initialColor: initial,
                    customColors: customColors,
                  ),
                ),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'RGB and HEX edits synchronize and apply one complete selection',
    (tester) async {
      EditorColorSelection? result;
      await _open(
        tester,
        initial: const Color(0x00112233),
        onResult: (value) => result = value,
      );
      expect(_text(tester, 'color-hex'), '112233');
      await _input(tester, 'color-red', '255');
      await _input(tester, 'color-green', '128');
      await _input(tester, 'color-blue', '0');
      expect(_text(tester, 'color-hex'), 'FF8000');
      expect(result, isNull);

      await _input(tester, 'color-hex', '0080FF');
      expect(_text(tester, 'color-red'), '0');
      expect(_text(tester, 'color-green'), '128');
      expect(_text(tester, 'color-blue'), '255');
      await tester.tap(_key('color-picker-apply'));
      await tester.pumpAndSettle();
      expect(result!.color, const Color(0xff0080ff));
      expect(result!.color.a, 1);
      expect(result!.customColors, contains(const Color(0xff0080ff)));
    },
  );

  testWidgets(
    'incomplete and out-of-range values prevent apply until corrected',
    (tester) async {
      await _open(tester, onResult: (_) {});
      await _input(tester, 'color-red', '');
      expect(
        tester.widget<FilledButton>(_key('color-picker-apply')).onPressed,
        isNull,
      );
      expect(find.text('0~255 정수'), findsOneWidget);
      await _input(tester, 'color-red', '999');
      expect(
        tester.widget<FilledButton>(_key('color-picker-apply')).onPressed,
        isNull,
      );
      await _input(tester, 'color-red', '100');
      await _input(tester, 'color-hex', '12');
      expect(find.text('6자리 HEX 색상을 입력하세요.'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_key('color-picker-apply')).onPressed,
        isNull,
      );
      await _input(tester, 'color-hex', 'GG0000');
      expect(
        tester.widget<FilledButton>(_key('color-picker-apply')).onPressed,
        isNull,
      );
      await _input(tester, 'color-hex', '#00ff10');
      expect(_text(tester, 'color-green'), '255');
      expect(
        tester.widget<FilledButton>(_key('color-picker-apply')).onPressed,
        isNotNull,
      );
      await tester.tap(_key('color-picker-cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'rainbow selection from black reveals color and brightness remains adjustable',
    (tester) async {
      EditorColorSelection? result;
      await _open(
        tester,
        initial: const Color(0xff000000),
        onResult: (value) => result = value,
      );
      await tester.ensureVisible(_key('color-surface'));
      var surface = tester.getRect(_key('color-surface'));
      await tester.tapAt(
        surface.topLeft + Offset(surface.width / 3, surface.height * .05),
      );
      await tester.pump();
      expect(int.parse(_text(tester, 'color-green')), greaterThan(245));
      expect(int.parse(_text(tester, 'color-red')), lessThan(20));

      final brightness = tester.getRect(_key('color-brightness'));
      await tester.tapAt(brightness.center);
      await tester.pump();
      expect(
        int.parse(_text(tester, 'color-green')),
        inInclusiveRange(126, 129),
      );
      surface = tester.getRect(_key('color-surface'));
      await tester.tapAt(
        surface.topLeft + Offset(surface.width * 2 / 3, surface.height * .05),
      );
      await tester.pump();
      expect(
        int.parse(_text(tester, 'color-blue')),
        inInclusiveRange(126, 129),
      );
      await tester.tap(_key('color-picker-apply'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect((result!.color.toARGB32() & 0xff), inInclusiveRange(126, 129));
    },
  );

  testWidgets('cancel rolls back draft color and added custom colors', (
    tester,
  ) async {
    const initial = Color(0xff112233);
    final custom = <Color>[const Color(0xffabcdef)];
    EditorColorSelection? result;
    var completed = false;
    await _open(
      tester,
      initial: initial,
      customColors: custom,
      onResult: (value) {
        result = value;
        completed = true;
      },
    );
    await _input(tester, 'color-hex', '00FF00');
    await tester.ensureVisible(_key('color-picker-add-custom'));
    await tester.tap(_key('color-picker-add-custom'));
    await tester.pump();
    expect(_key('color-picker-custom-1'), findsOneWidget);
    expect(custom, [const Color(0xffabcdef)]);
    await tester.tap(_key('color-picker-cancel'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
    expect(custom, [const Color(0xffabcdef)]);
  });

  testWidgets(
    'palette presents two rows of basic colors and selects custom colors at 236px',
    (tester) async {
      Color? selected;
      var edits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 236,
                child: EditorColorPalette(
                  color: const Color(0xff000000),
                  customColors: const [Color(0xff123456)],
                  onSelected: (value) => selected = value,
                  onEdit: () => edits++,
                ),
              ),
            ),
          ),
        ),
      );
      expect(paintColorPalette, hasLength(20));
      final first = tester.getRect(_key('paint-basic-0'));
      final secondRow = tester.getRect(_key('paint-basic-10'));
      expect(secondRow.left, first.left);
      expect(secondRow.top, greaterThan(first.bottom));
      await tester.tap(_key('paint-basic-3'));
      expect(selected, const Color(0xffff0000));
      await tester.tap(_key('paint-custom-0'));
      expect(selected, const Color(0xff123456));
      await tester.tap(_key('paint-edit-color'));
      expect(edits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(320, 640), const Size(568, 240)]) {
    testWidgets(
      'dialog scrolls and applies basic/custom colors at ${size.width}x${size.height}',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        EditorColorSelection? result;
        await _open(
          tester,
          customColors: const [Color(0xff123456)],
          onResult: (value) => result = value,
        );
        expect(find.text('기본 색'), findsOneWidget);
        await tester.ensureVisible(_key('color-picker-basic-3'));
        await tester.tap(_key('color-picker-basic-3'));
        await tester.pump();
        expect(_text(tester, 'color-hex'), 'FF0000');
        await tester.ensureVisible(_key('color-picker-custom-0'));
        await tester.tap(_key('color-picker-custom-0'));
        await tester.pump();
        expect(_text(tester, 'color-hex'), '123456');
        await _input(tester, 'color-hex', '654321');
        await tester.ensureVisible(_key('color-picker-add-custom'));
        await tester.tap(_key('color-picker-add-custom'));
        await tester.pump();
        await tester.tap(_key('color-picker-apply'));
        await tester.pumpAndSettle();
        expect(result!.color, const Color(0xff654321));
        expect(
          result!.customColors,
          containsAll([const Color(0xff123456), const Color(0xff654321)]),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('custom colors are deduplicated and bounded to sixteen entries', (
    tester,
  ) async {
    final custom = [for (var i = 0; i < 16; i++) Color(0xff010000 | i)];
    EditorColorSelection? result;
    await _open(
      tester,
      customColors: custom,
      onResult: (value) => result = value,
    );
    await _input(tester, 'color-hex', '01000F');
    await tester.ensureVisible(_key('color-picker-add-custom'));
    await tester.tap(_key('color-picker-add-custom'));
    await tester.pump();
    await _input(tester, 'color-hex', 'ABCDEF');
    await tester.tap(_key('color-picker-apply'));
    await tester.pumpAndSettle();
    expect(result!.customColors, hasLength(16));
    expect(result!.customColors, contains(const Color(0xffabcdef)));
    expect(result!.customColors, isNot(contains(custom.first)));
    expect(custom, hasLength(16));
  });
}
