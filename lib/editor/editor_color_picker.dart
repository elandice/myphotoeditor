import 'package:flutter/material.dart';

const paintColorPalette = <Color>[
  Color(0xff000000),
  Color(0xff7f7f7f),
  Color(0xff880015),
  Color(0xffff0000),
  Color(0xffff7f27),
  Color(0xfffff200),
  Color(0xff22b14c),
  Color(0xff00a2e8),
  Color(0xff3f48cc),
  Color(0xffa349a4),
  Color(0xffffffff),
  Color(0xffc3c3c3),
  Color(0xffb97a57),
  Color(0xffffaec9),
  Color(0xffffc90e),
  Color(0xffefe4b0),
  Color(0xffb5e61d),
  Color(0xff99d9ea),
  Color(0xff7092be),
  Color(0xffc8bfe7),
];

const _colorNames = <String>[
  '검정',
  '회색',
  '진한 빨강',
  '빨강',
  '주황',
  '노랑',
  '초록',
  '하늘색',
  '파랑',
  '보라',
  '흰색',
  '밝은 회색',
  '갈색',
  '분홍',
  '금색',
  '크림색',
  '연두',
  '밝은 하늘색',
  '연한 파랑',
  '연보라',
];

String _hex(Color color) => (color.toARGB32() & 0xffffff)
    .toRadixString(16)
    .padLeft(6, '0')
    .toUpperCase();

int _channel(Color color, int shift) => (color.toARGB32() >> shift) & 0xff;

class EditorColorSelection {
  EditorColorSelection({required this.color, required List<Color> customColors})
    : customColors = List.unmodifiable(customColors);

  final Color color;
  final List<Color> customColors;
}

class EditorColorPalette extends StatelessWidget {
  const EditorColorPalette({
    super.key,
    required this.color,
    this.customColors = const [],
    required this.onSelected,
    required this.onEdit,
  });

  final Color color;
  final List<Color> customColors;
  final ValueChanged<Color> onSelected;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Semantics(
            label: '현재 색 #${_hex(color)}',
            child: Container(
              key: const ValueKey('paint-current-color'),
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color,
                border: Border.all(color: const Color(0xff737780)),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '현재 색\n#${_hex(color)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          TextButton(
            key: const ValueKey('paint-edit-color'),
            onPressed: onEdit,
            child: const Text('색 편집'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _BasicColorGrid(
        color: color,
        onSelected: onSelected,
        keyPrefix: 'paint-basic',
      ),
      if (customColors.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text('최근 / 사용자 지정 색', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 5),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (
              var index = 0;
              index < customColors.length && index < 16;
              index++
            )
              SizedBox(
                width: 26,
                height: 26,
                child: _ColorSwatch(
                  key: ValueKey('paint-custom-$index'),
                  color: customColors[index],
                  selected: color.toARGB32() == customColors[index].toARGB32(),
                  label:
                      '사용자 지정 색 ${index + 1} (#${_hex(customColors[index])})',
                  onTap: () => onSelected(customColors[index]),
                ),
              ),
          ],
        ),
      ],
    ],
  );
}

class _BasicColorGrid extends StatelessWidget {
  const _BasicColorGrid({
    required this.color,
    required this.onSelected,
    required this.keyPrefix,
  });
  final Color color;
  final ValueChanged<Color> onSelected;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var row = 0; row < 2; row++) ...[
        if (row != 0) const SizedBox(height: 4),
        Row(
          children: [
            for (var column = 0; column < 10; column++) ...[
              if (column != 0) const SizedBox(width: 3),
              Expanded(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _ColorSwatch(
                    key: ValueKey('$keyPrefix-${row * 10 + column}'),
                    color: paintColorPalette[row * 10 + column],
                    selected:
                        color.toARGB32() ==
                        paintColorPalette[row * 10 + column].toARGB32(),
                    label:
                        '기본색 ${_colorNames[row * 10 + column]} (#${_hex(paintColorPalette[row * 10 + column])})',
                    onTap: () =>
                        onSelected(paintColorPalette[row * 10 + column]),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    ],
  );
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Semantics(
      label: label,
      button: true,
      selected: selected,
      child: Material(
        color: color,
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : const Color(0xff8b8e96),
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap),
      ),
    ),
  );
}

class EditorColorPickerDialog extends StatefulWidget {
  const EditorColorPickerDialog({
    super.key,
    required this.initialColor,
    this.customColors = const [],
    this.title = '색 편집',
  });

  final Color initialColor;
  final List<Color> customColors;
  final String title;

  @override
  State<EditorColorPickerDialog> createState() =>
      _EditorColorPickerDialogState();
}

class _EditorColorPickerDialogState extends State<EditorColorPickerDialog> {
  // Brush opacity has its own control; this dialog edits opaque RGB colors.
  late HSVColor _hsv = HSVColor.fromColor(widget.initialColor.withAlpha(255));
  late final List<Color> _customColors = _initialCustomColors();
  late final List<TextEditingController> _rgb = [
    for (final shift in [16, 8, 0])
      TextEditingController(
        text: _channel(widget.initialColor, shift).toString(),
      ),
  ];
  late final TextEditingController _hexController = TextEditingController(
    text: _hex(widget.initialColor),
  );
  final List<String?> _rgbErrors = List.filled(3, null);
  String? _hexError;

  Color get _color => _hsv.toColor();
  bool get _valid =>
      _hexError == null && _rgbErrors.every((error) => error == null);

  List<Color> _initialCustomColors() {
    final colors = <Color>[];
    for (final color in widget.customColors) {
      if (!colors.any((item) => item.toARGB32() == color.toARGB32())) {
        colors.add(color);
      }
    }
    return colors.length <= 16 ? colors : colors.sublist(colors.length - 16);
  }

  void _addCustomColor(Color color) {
    if (_customColors.any((item) => item.toARGB32() == color.toARGB32())) {
      return;
    }
    if (_customColors.length == 16) _customColors.removeAt(0);
    _customColors.add(color);
  }

  void _apply() {
    if (!_valid) return;
    if (!paintColorPalette.any(
      (color) => color.toARGB32() == _color.toARGB32(),
    )) {
      _addCustomColor(_color);
    }
    Navigator.pop(
      context,
      EditorColorSelection(color: _color, customColors: _customColors),
    );
  }

  @override
  void dispose() {
    for (final controller in _rgb) {
      controller.dispose();
    }
    _hexController.dispose();
    super.dispose();
  }

  void _text(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _setColor(Color color, {int? editingRgb, bool editingHex = false}) {
    _hsv = HSVColor.fromColor(color.withAlpha(255));
    _syncInputs(editingRgb: editingRgb, editingHex: editingHex);
  }

  void _syncInputs({int? editingRgb, bool editingHex = false}) {
    for (var index = 0; index < 3; index++) {
      _rgbErrors[index] = null;
      if (index != editingRgb) {
        _text(_rgb[index], _channel(_color, [16, 8, 0][index]).toString());
      }
    }
    _hexError = null;
    if (!editingHex) _text(_hexController, _hex(_color));
  }

  void _readRgb(int editing) {
    final channels = <int>[];
    setState(() {
      for (var index = 0; index < 3; index++) {
        final text = _rgb[index].text.trim();
        final parsed = RegExp(r'^\d+$').hasMatch(text)
            ? int.tryParse(text)
            : null;
        _rgbErrors[index] = parsed == null || parsed < 0 || parsed > 255
            ? '0~255 정수'
            : null;
        channels.add(parsed ?? 0);
      }
      if (_rgbErrors.every((error) => error == null)) {
        _setColor(
          Color.fromARGB(
            (_hsv.alpha * 255).round(),
            channels[0],
            channels[1],
            channels[2],
          ),
          editingRgb: editing,
        );
      }
    });
  }

  void _readHex() {
    final text = _hexController.text.trim().replaceFirst(RegExp(r'^#'), '');
    setState(() {
      if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(text)) {
        _hexError = '6자리 HEX 색상을 입력하세요.';
        return;
      }
      final rgb = int.parse(text, radix: 16);
      _setColor(
        Color((_hsv.alpha * 255).round() << 24 | rgb),
        editingHex: true,
      );
    });
  }

  void _chooseSurface(Offset position, Size size) {
    setState(() {
      // Keep hue while value is zero; RGB cannot encode that latent choice.
      _hsv = _hsv
          .withHue((position.dx / size.width).clamp(0.0, 1.0).toDouble() * 360)
          .withSaturation(
            1 - (position.dy / size.height).clamp(0.0, 1.0).toDouble(),
          );
      if (_hsv.value == 0) _hsv = _hsv.withValue(1);
      _syncInputs();
    });
  }

  void _chooseBrightness(Offset position, Size size) {
    setState(() {
      _hsv = _hsv.withValue(
        1 - (position.dy / size.height).clamp(0.0, 1.0).toDouble(),
      );
      _syncInputs();
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    scrollable: true,
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('기본 색'),
          const SizedBox(height: 6),
          _BasicColorGrid(
            color: _color,
            onSelected: (color) => setState(() => _setColor(color)),
            keyPrefix: 'color-picker-basic',
          ),
          const SizedBox(height: 14),
          SizedBox(
            // AlertDialog asks for intrinsic dimensions before layout.
            // The surface has an explicit height and reads its actual
            // RenderBox size only after receiving a pointer event.
            height:
                ((MediaQuery.sizeOf(context).width - 80).clamp(0.0, 460.0) *
                        .55)
                    .clamp(140.0, 220.0)
                    .toDouble(),
            child: Row(
              children: [
                Expanded(
                  child: _ColorDragArea(
                    key: const ValueKey('color-surface'),
                    label: '무지개 색조와 채도 선택',
                    onChanged: _chooseSurface,
                    painter: _HueSaturationPainter(_hsv),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 32,
                  child: _ColorDragArea(
                    key: const ValueKey('color-brightness'),
                    label: '색 밝기 선택',
                    onChanged: _chooseBrightness,
                    painter: _BrightnessPainter(_hsv),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                key: const ValueKey('color-picker-preview'),
                width: 46,
                height: 42,
                decoration: BoxDecoration(
                  color: _color,
                  border: Border.all(color: Colors.grey),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('선택한 색\n#${_hex(_color)}')),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < 3; index++) ...[
                if (index != 0) const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: ValueKey('color-${['red', 'green', 'blue'][index]}'),
                    controller: _rgb[index],
                    keyboardType: TextInputType.number,
                    onChanged: (_) => _readRgb(index),
                    decoration: InputDecoration(
                      labelText: ['R', 'G', 'B'][index],
                      isDense: true,
                      border: const OutlineInputBorder(),
                      errorText: _rgbErrors[index],
                      errorMaxLines: 2,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('color-hex'),
            controller: _hexController,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => _readHex(),
            decoration: InputDecoration(
              labelText: 'HEX',
              prefixText: '#',
              hintText: '000000',
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: _hexError,
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            key: const ValueKey('color-picker-add-custom'),
            onPressed: !_valid
                ? null
                : () => setState(() {
                    _addCustomColor(_color);
                  }),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('사용자 지정 색에 추가'),
          ),
          if (_customColors.isNotEmpty)
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                for (var index = 0; index < _customColors.length; index++)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: _ColorSwatch(
                      key: ValueKey('color-picker-custom-$index'),
                      color: _customColors[index],
                      selected:
                          _color.toARGB32() == _customColors[index].toARGB32(),
                      label:
                          '사용자 지정 색 ${index + 1} (#${_hex(_customColors[index])})',
                      onTap: () =>
                          setState(() => _setColor(_customColors[index])),
                    ),
                  ),
              ],
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('color-picker-cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const ValueKey('color-picker-apply'),
        onPressed: !_valid ? null : _apply,
        child: const Text('적용'),
      ),
    ],
  );
}

class _ColorDragArea extends StatelessWidget {
  const _ColorDragArea({
    super.key,
    required this.label,
    required this.onChanged,
    required this.painter,
  });
  final String label;
  final void Function(Offset, Size) onChanged;
  final CustomPainter painter;

  @override
  Widget build(BuildContext context) {
    void choose(Offset position) {
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || box.size.isEmpty) return;
      onChanged(position, box.size);
    }

    return Semantics(
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => choose(details.localPosition),
        onPanStart: (details) => choose(details.localPosition),
        onPanUpdate: (details) => choose(details.localPosition),
        child: CustomPaint(painter: painter, child: const SizedBox.expand()),
      ),
    );
  }
}

class _HueSaturationPainter extends CustomPainter {
  const _HueSaturationPainter(this.hsv);
  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          colors: [
            for (var hue = 0; hue <= 360; hue += 60)
              HSVColor.fromAHSV(1, hue.toDouble(), 1, 1).toColor(),
          ],
        ).createShader(bounds),
    );
    // The rainbow remains visible even when the selected color is black.
    const gray = Colors.white;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [gray.withValues(alpha: 0), gray],
        ).createShader(bounds),
    );
    final point = Offset(
      hsv.hue / 360 * size.width,
      (1 - hsv.saturation) * size.height,
    );
    canvas.drawCircle(
      point,
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.black,
    );
    canvas.drawCircle(
      point,
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _HueSaturationPainter oldDelegate) =>
      hsv != oldDelegate.hsv;
}

class _BrightnessPainter extends CustomPainter {
  const _BrightnessPainter(this.hsv);
  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [hsv.withAlpha(1).withValue(1).toColor(), Colors.black],
        ).createShader(bounds),
    );
    final y = ((1 - hsv.value) * size.height)
        .clamp(1.5, size.height - 1.5)
        .toDouble();
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = Colors.black
        ..strokeWidth = 4,
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _BrightnessPainter oldDelegate) =>
      hsv != oldDelegate.hsv;
}
