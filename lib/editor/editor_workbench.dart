part of 'editor_screen.dart';

const _primaryTools = [
  EditorTool.brush,
  EditorTool.eraser,
  EditorTool.marquee,
  EditorTool.transform,
  EditorTool.text,
  EditorTool.hand,
];
const _filterNames = {
  EditorFilter.invert: '색상 반전',
  EditorFilter.grayscale: '흑백',
  EditorFilter.sepia: '세피아',
  EditorFilter.gaussianBlur: '가우시안 흐림',
  EditorFilter.sharpen: '선명하게',
  EditorFilter.posterize: '포스터화',
  EditorFilter.threshold: '임계값',
  EditorFilter.autoContrast: '자동 대비',
};

extension _WorkbenchUI on _EditorScreenState {
  Widget _toolPickerTile(EditorTool tool, BuildContext sheet) => Material(
    color: _editor.tool == tool
        ? const Color(0xFFEDE9FC)
        : const Color(0xFFF5F6FA),
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      onTap: () {
        _editor.setTool(tool);
        Navigator.pop(sheet);
      },
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
        child: Column(
          children: [
            Icon(_toolIcon(tool), size: 24, color: _accent),
            const SizedBox(height: 8),
            Text(
              _displayToolName(tool),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 4),
            Text(
              _toolKey(tool),
              style: const TextStyle(fontSize: 9, color: _muted),
            ),
          ],
        ),
      ),
    ),
  );
  Future<void> _perform(Future<void> Function() action) async {
    if (_loading || _fileBusy || _editor.isBusy) return;
    try {
      await action();
    } catch (error) {
      _showMessage('편집을 적용하지 못했습니다: $error');
    }
  }

  void _handleDocumentMenu(String value) {
    switch (value) {
      case 'new':
        _newDocument();
      case 'import':
        _importImage();
      case 'openProject':
        _openProject();
      case 'saveProject':
        _saveProject();
      case 'tools':
        _openTools();
      case 'actions':
        _openActions();
      case 'filters':
        _openInspector(2);
      case 'history':
        _openInspector(3);
      case 'help':
        _showHelp();
    }
  }

  Future<void> _saveProject() async {
    if (_loading || _fileBusy || _editor.isBusy) return;
    _updateUI(() => _fileBusy = true);
    try {
      final bytes = await _editor.exportProject();
      if (!mounted) return;
      final result = await EditorFiles.saveProject(bytes);
      if (result != ExportResult.cancelled) {
        _showMessage(
          result == ExportResult.saved
              ? '레이어와 마스크를 프로젝트에 저장했습니다.'
              : '프로젝트 다운로드를 시작했습니다.',
        );
      }
    } catch (error) {
      _showMessage('프로젝트를 저장하지 못했습니다: $error');
    } finally {
      _updateUI(() => _fileBusy = false);
    }
  }

  Future<void> _openProject() async {
    if (_loading || _fileBusy || _editor.isBusy) return;
    _updateUI(() => _fileBusy = true);
    try {
      final file = await EditorFiles.pickProject();
      if (file == null || !mounted) return;
      await _editor.importProject(file.bytes);
      _updateUI(
        () => _documentName = file.name.replaceAll(
          RegExp(r'\.luma$', caseSensitive: false),
          '',
        ),
      );
      _viewport.fit();
      _showMessage('프로젝트를 열었습니다. 레이어를 계속 편집할 수 있습니다.');
    } catch (error) {
      _showMessage('프로젝트를 열지 못했습니다: $error');
    } finally {
      _updateUI(() => _fileBusy = false);
    }
  }

  void _openTools() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    builder: (sheet) => SizedBox(
      height: MediaQuery.sizeOf(sheet).height * .78,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '편집 도구',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('목적에 맞는 도구를 선택하세요.', style: TextStyle(color: _muted)),
            const SizedBox(height: 20),
            for (final group in <String, List<EditorTool>>{
              '그리기 · 리터칭': [
                EditorTool.brush,
                EditorTool.eraser,
                EditorTool.cloneStamp,
                EditorTool.eyedropper,
              ],
              '선택': [
                EditorTool.marquee,
                EditorTool.ellipticalMarquee,
                EditorTool.lasso,
                EditorTool.magicWand,
              ],
              '색상 · 도형': [
                EditorTool.fill,
                EditorTool.gradient,
                EditorTool.rectangle,
                EditorTool.ellipse,
                EditorTool.text,
              ],
              '이동 · 변형': [EditorTool.hand, EditorTool.transform],
            }.entries) ...[
              Text(
                group.key,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _muted,
                ),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: group.value
                      .map(
                        (tool) => SizedBox(
                          width: (constraints.maxWidth - 16) / 3,
                          child: _toolPickerTile(tool, sheet),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 22),
            ],
          ],
        ),
      ),
    ),
  );

  List<Widget> _extraToolOptions() {
    final tool = _editor.tool;
    return [
      if (tool == EditorTool.magicWand || tool == EditorTool.fill) ...[
        const SizedBox(width: 20),
        const Text('허용 오차', style: TextStyle(fontSize: 11, color: _muted)),
        SizedBox(
          width: 120,
          child: Slider(
            value: _editor.magicWandTolerance,
            onChanged: _editor.setMagicWandTolerance,
          ),
        ),
        _valuePill('${(_editor.magicWandTolerance * 100).round()}%'),
      ],
      if (tool == EditorTool.gradient) ...[
        const SizedBox(width: 20),
        _colorDot(_editor.brushColor, true, _customColor),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Icon(Icons.arrow_forward, size: 16, color: _muted),
        ),
        _colorDot(_editor.secondaryColor, true, _pickSecondary),
      ],
      if (tool == EditorTool.rectangle || tool == EditorTool.ellipse) ...[
        const SizedBox(width: 16),
        TextButton.icon(
          onPressed: () => _editor.setShapeFilled(!_editor.shapeFilled),
          icon: Icon(
            _editor.shapeFilled
                ? Icons.check_box
                : Icons.check_box_outline_blank,
            size: 18,
          ),
          label: Text(_editor.shapeFilled ? '채운 도형' : '윤곽선 도형'),
        ),
        TextButton(onPressed: _customColor, child: const Text('색상')),
      ],
    ];
  }

  Future<void> _pickSecondary() async {
    final color = await showDialog<Color>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('그라디언트 끝 색상'),
        content: SizedBox(
          width: 280,
          child: Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final color in _swatches)
                _colorDot(
                  color,
                  _editor.secondaryColor == color,
                  () => Navigator.pop(dialog, color),
                  size: 36,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('취소'),
          ),
        ],
      ),
    );
    if (color != null && mounted) _editor.setSecondaryColor(color);
  }

  void _openActions() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    builder: (sheet) => SizedBox(
      height: MediaQuery.sizeOf(sheet).height * .78,
      child: AnimatedBuilder(
        animation: _editor,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '편집 작업',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 20),
              _actionGroup('선택 · 클립보드', [
                ('전체 선택', Icons.select_all, () => _editor.selectAll(), true),
                ('선택 반전', Icons.flip, () => _editor.invertSelection(), true),
                (
                  '선택 해제',
                  Icons.deselect,
                  () => _editor.clearSelection(),
                  _editor.selection != null,
                ),
                (
                  '복사',
                  Icons.copy,
                  () => _perform(_editor.copySelection),
                  _editor.activeLayer != null,
                ),
                (
                  '잘라내기',
                  Icons.content_cut,
                  () => _perform(_editor.cutSelection),
                  _editor.activeLayer != null && !_editor.activeLayer!.locked,
                ),
                (
                  '붙여넣기',
                  Icons.paste,
                  () => _perform(_editor.pasteSelection),
                  _editor.canPaste,
                ),
                (
                  '선택 영역 삭제',
                  Icons.delete_outline,
                  () => _perform(_editor.deleteSelection),
                  _editor.selection != null,
                ),
                (
                  '선택 영역 색상 채우기',
                  Icons.format_color_fill,
                  () => _perform(() => _editor.fillSelection()),
                  _editor.activeLayer != null,
                ),
              ]),
              _actionGroup('이미지', [
                (
                  '선택 영역으로 자르기',
                  Icons.crop,
                  () {
                    Navigator.pop(sheet);
                    _perform(_editor.cropToSelection).then((_) {
                      if (mounted) _viewport.fit();
                    });
                  },
                  _editor.selection != null,
                ),
                (
                  '이미지 크기 변경',
                  Icons.photo_size_select_large,
                  () {
                    Navigator.pop(sheet);
                    _resizeImage();
                  },
                  true,
                ),
                (
                  '시계 방향 90° 회전',
                  Icons.rotate_90_degrees_cw,
                  () => _perform(() => _editor.rotateDocument()),
                  true,
                ),
                (
                  '반시계 방향 90° 회전',
                  Icons.rotate_90_degrees_ccw,
                  () =>
                      _perform(() => _editor.rotateDocument(clockwise: false)),
                  true,
                ),
                (
                  '레이어 좌우 반전',
                  Icons.flip,
                  () => _perform(() => _editor.flipActiveLayer()),
                  _editor.activeLayer != null,
                ),
                (
                  '레이어 상하 반전',
                  Icons.flip_camera_android,
                  () => _perform(
                    () => _editor.flipActiveLayer(horizontal: false),
                  ),
                  _editor.activeLayer != null,
                ),
              ]),
              _actionGroup('레이어 · 마스크', [
                (
                  '아래 레이어와 병합',
                  Icons.merge,
                  () => _perform(_editor.mergeDown),
                  _canMerge,
                ),
                (
                  '보이는 레이어 합성',
                  Icons.layers,
                  () => _perform(_editor.flattenDocument),
                  _editor.layers.length > 1,
                ),
                (
                  '선택 영역으로 마스크 만들기',
                  Icons.tonality,
                  () => _perform(_editor.createMaskFromSelection),
                  _editor.selection != null && _editor.activeLayer != null,
                ),
                (
                  '마스크 반전',
                  Icons.invert_colors,
                  () => _perform(_editor.invertActiveMask),
                  _editor.activeLayer?.mask != null,
                ),
                (
                  '마스크 제거',
                  Icons.layers_clear,
                  () => _editor.removeActiveMask(),
                  _editor.activeLayer?.mask != null,
                ),
              ]),
            ],
          ),
        ),
      ),
    ),
  );
  bool get _canMerge {
    final index = _editor.layers.indexWhere(
      (layer) => layer.id == _editor.activeLayerId,
    );
    return index > 0 &&
        !_editor.layers[index].locked &&
        !_editor.layers[index - 1].locked &&
        _editor.layers[index].visible &&
        _editor.layers[index - 1].visible &&
        _editor.layers[index].blendMode == BlendMode.srcOver &&
        _editor.layers[index - 1].blendMode == BlendMode.srcOver;
  }

  Widget _actionGroup(
    String title,
    List<(String, IconData, VoidCallback, bool)> actions,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 12,
          color: _muted,
        ),
      ),
      const SizedBox(height: 8),
      for (final action in actions)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            action.$2,
            size: 20,
            color: action.$4 ? _accent : _muted,
          ),
          title: Text(action.$1, style: const TextStyle(fontSize: 13)),
          enabled: action.$4 && !_editor.isBusy,
          onTap: action.$3,
        ),
      const Divider(),
      const SizedBox(height: 16),
    ],
  );

  Future<void> _resizeImage() async {
    final width = TextEditingController(
          text: _editor.documentSize.width.round().toString(),
        ),
        height = TextEditingController(
          text: _editor.documentSize.height.round().toString(),
        );
    String? error;
    final size = await showDialog<Size>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('이미지 크기 변경'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '레이어의 픽셀 크기를 변경합니다. 텍스트와 변형은 이미지에 적용됩니다.',
                  style: TextStyle(fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: width,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '너비 (px)'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: height,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '높이 (px)'),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                final w = int.tryParse(width.text) ?? 0,
                    h = int.tryParse(height.text) ?? 0;
                if (w < 1 || h < 1 || w > 4096 || h > 4096) {
                  update(() => error = '1–4096 px 범위로 입력하세요.');
                  return;
                }
                Navigator.pop(dialog, Size(w.toDouble(), h.toDouble()));
              },
              child: const Text('적용'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    width.dispose();
    height.dispose();
    if (size != null && mounted) {
      await _perform(
        () => _editor.resizeDocument(size.width.toInt(), size.height.toInt()),
      );
    }
  }

  Widget _maskControls(EditorLayer layer) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OutlinedButton.icon(
        onPressed: layer.locked
            ? null
            : layer.mask == null
            ? (_editor.selection == null
                  ? null
                  : () => _perform(_editor.createMaskFromSelection))
            : () => _editor.toggleActiveMask(),
        icon: Icon(
          layer.mask == null
              ? Icons.tonality
              : layer.maskEnabled
              ? Icons.visibility
              : Icons.visibility_off,
          size: 18,
        ),
        label: Text(
          layer.mask == null
              ? '선택 영역으로 마스크'
              : layer.maskEnabled
              ? '마스크 적용 중'
              : '마스크 비활성',
        ),
      ),
      if (layer.mask != null)
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: layer.locked
                    ? null
                    : () => _perform(_editor.invertActiveMask),
                child: const Text('마스크 반전'),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: layer.locked ? null : _editor.removeActiveMask,
                child: const Text('제거'),
              ),
            ),
          ],
        ),
      Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: _canMerge ? () => _perform(_editor.mergeDown) : null,
              child: const Text('아래와 병합', style: TextStyle(fontSize: 11)),
            ),
          ),
          Expanded(
            child: TextButton(
              onPressed: _editor.layers.length > 1
                  ? () => _perform(_editor.flattenDocument)
                  : null,
              child: const Text('모두 합성', style: TextStyle(fontSize: 11)),
            ),
          ),
        ],
      ),
    ],
  );
  Widget _filtersPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionHeading('필터 · 효과', Icons.auto_awesome_outlined),
      const SizedBox(height: 12),
      const Text(
        '현재 레이어에 적용됩니다. 선택한 영역이 있으면 그 안에만 효과를 적용합니다.',
        style: TextStyle(fontSize: 11, color: _muted, height: 1.7),
      ),
      const SizedBox(height: 20),
      for (final entry in _filterNames.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            onPressed:
                _editor.activeLayer == null ||
                    _editor.activeLayer!.locked ||
                    _editor.isBusy
                ? null
                : () => _applyFilter(entry.key),
            icon: const Icon(Icons.tune, size: 17),
            label: Text(entry.value),
          ),
        ),
      const SizedBox(height: 20),
      const Text(
        '적용 후 실행 취소로 복원할 수 있습니다. 효과는 현재 레이어의 픽셀에 반영됩니다.',
        style: TextStyle(fontSize: 11, color: _muted, height: 1.7),
      ),
    ],
  );
  Future<void> _applyFilter(EditorFilter filter) async {
    final spec = switch (filter) {
      EditorFilter.gaussianBlur => (.1, 30.0, 4.0, '반경 (px)'),
      EditorFilter.sharpen => (.1, 3.0, 1.0, '강도'),
      EditorFilter.posterize => (2.0, 16.0, 6.0, '색상 단계'),
      EditorFilter.threshold => (0.0, 1.0, .5, '임계값'),
      _ => (0.0, 1.0, 1.0, ''),
    };
    double? amount;
    if (spec.$4.isNotEmpty) {
      var value = spec.$3;
      amount = await showDialog<double>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(_filterNames[filter]!),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${spec.$4} · ${filter == EditorFilter.posterize ? value.round() : value.toStringAsFixed(1)}',
                  ),
                  Slider(
                    value: value,
                    min: spec.$1,
                    max: spec.$2,
                    divisions: filter == EditorFilter.posterize ? 14 : null,
                    onChanged: (next) => update(() => value = next),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, value),
                child: const Text('적용'),
              ),
            ],
          ),
        ),
      );
      if (amount == null || !mounted) return;
    }
    await _perform(() => _editor.applyFilter(filter, amount: amount));
  }

  Widget _historyPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionHeading('편집 기록', Icons.history),
      const SizedBox(height: 16),
      Text(
        '${_editor.historyLength} / ${_editor.maxHistorySteps} 단계 · ${(_editor.historyBytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
        style: const TextStyle(fontSize: 11, color: _muted),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _editor.canUndo ? _editor.undo : null,
              child: const Text('실행 취소'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: _editor.canRedo ? _editor.redo : null,
              child: const Text('다시 실행'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      if (_editor.historyLabels.isEmpty)
        const Text(
          '편집을 시작하면 작업 기록이 표시됩니다.',
          style: TextStyle(fontSize: 12, color: _muted),
        ),
      for (final (index, label) in _editor.historyLabels.indexed)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            index == 0 ? Icons.radio_button_checked : Icons.history,
            size: 16,
            color: index == 0 ? _accent : _muted,
          ),
          title: Text(label, style: const TextStyle(fontSize: 11)),
          subtitle: index == 0
              ? const Text('최근 작업', style: TextStyle(fontSize: 9))
              : null,
        ),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        onPressed: _saveProject,
        icon: const Icon(Icons.save_outlined, size: 18),
        label: const Text('프로젝트 저장'),
      ),
    ],
  );
}

// WORKBENCH_COMPLETE
