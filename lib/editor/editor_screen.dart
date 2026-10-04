import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/editor_files.dart';
import '../services/editor_recovery.dart';
import 'editor_controller.dart';
import 'editor_color_picker.dart';
import 'editor_project_schema.dart';
import 'editor_viewport.dart';

part 'editor_workbench.dart';

const _accent = Color(0xFF7865E9);
const _ink = Color(0xFF31333F);
const _muted = Color(0xFF9295A3);
const _line = Color(0xFFE9EAF0);

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, this.recoveryStore});
  final EditorRecoveryStore? recoveryStore;
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final _editor = EditorController();
  final _viewport = ViewportController();
  bool _loading = true;
  bool _fileBusy = false;
  bool _grid = false;
  String _documentName = '이름 없는 작업';
  int _inspectorTab = 0;
  bool _transformSliderActive = false;
  late final EditorRecoveryStore _recovery;
  late final EditorCloseGuard _closeGuard;
  late final AppLifecycleListener _lifecycle;
  Timer? _recoveryTimer;
  int? _recoveryToken;
  bool _recoveryWriting = false;
  bool _recoveryAvailable = true;
  bool _discardPromptOpen = false;
  bool _dialogActive = false;
  List<Color> _customColors = const [];

  bool get _hasTransformSelection =>
      _editor.isTransformingSelection ||
      (_editor.selection != null && !_editor.selection!.isEmpty);

  String _displayToolName(EditorTool tool) =>
      tool == EditorTool.transform && _hasTransformSelection
      ? '선택 영역 변형'
      : _toolName(tool);

  String _displayToolHint(EditorTool tool) =>
      tool == EditorTool.transform && _hasTransformSelection
      ? '선택 영역을 드래그하여 이동 · 모서리로 크기 조절 · 위쪽 손잡이로 회전'
      : _toolHint(tool);
  void _updateUI(VoidCallback update) {
    if (mounted) {
      setState(update);
      if (!_fileBusy) _onEditorChanged();
    }
  }

  @override
  void initState() {
    super.initState();
    _recovery = widget.recoveryStore ?? createEditorRecoveryStore();
    _closeGuard = createEditorCloseGuard();
    _editor.addListener(_onEditorChanged);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async => await _confirmDiscard(exiting: true)
          ? ui.AppExitResponse.exit
          : ui.AppExitResponse.cancel,
      onPause: () => unawaited(_writeRecovery()),
    );
    _initialize();
  }

  Future<void> _initialize() async {
    Uint8List? recovery;
    try {
      await _editor.newDocument(1200, 900);
      try {
        recovery = await _recovery.read();
      } catch (_) {
        _recoveryAvailable = false;
      }
    } catch (error) {
      _showMessage('캔버스를 준비하지 못했습니다: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (mounted && recovery != null) await _offerRecovery(recovery);
    if (mounted && !_recoveryAvailable) {
      _showMessage('자동 복구 저장소를 사용할 수 없습니다. 프로젝트를 직접 저장해 주세요.');
    }
  }

  void _onEditorChanged() {
    _closeGuard.update(_editor.isDirty);
    _recoveryTimer?.cancel();
    if (_loading ||
        !_recoveryAvailable ||
        _recoveryWriting ||
        _discardPromptOpen ||
        _dialogActive) {
      return;
    }
    if (!_editor.isDirty) {
      if (_recoveryToken != null) {
        _recoveryToken = null;
        unawaited(_clearRecovery());
      }
      return;
    }
    if (!_fileBusy &&
        !_editor.isBusy &&
        !_editor.isStroking &&
        !_editor.hasActiveTransform &&
        _recoveryToken != _editor.documentToken) {
      _recoveryTimer = Timer(const Duration(seconds: 4), _writeRecovery);
    }
  }

  Future<void> _clearRecovery() async {
    try {
      await _recovery.clear();
    } catch (_) {
      _recoveryAvailable = false;
    }
  }

  Future<void> _writeRecovery() async {
    if (mounted &&
        _editor.isDirty &&
        _recoveryAvailable &&
        !_fileBusy &&
        (_dialogActive || ModalRoute.of(context)?.isCurrent == false)) {
      _recoveryTimer = Timer(const Duration(seconds: 1), _writeRecovery);
      return;
    }
    if (!mounted ||
        _loading ||
        !_recoveryAvailable ||
        _recoveryWriting ||
        _fileBusy ||
        _editor.isBusy ||
        _editor.isStroking ||
        _editor.hasActiveTransform ||
        !_editor.isDirty ||
        _recoveryToken == _editor.documentToken) {
      return;
    }
    _recoveryWriting = true;
    _updateUI(() => _fileBusy = true);
    try {
      final bytes = await _editor.exportProject();
      final token = _editor.documentToken;
      await _recovery.write(bytes);
      _recoveryToken = token;
    } catch (_) {
      _recoveryAvailable = false;
      _showMessage('자동 복구를 저장하지 못했습니다. 프로젝트를 직접 저장해 주세요.');
    } finally {
      _recoveryWriting = false;
      _updateUI(() => _fileBusy = false);
      if (mounted) _onEditorChanged();
    }
  }

  Future<T?> _showOwnedDialog<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool barrierDismissible = true,
  }) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
    );
    _dialogActive = true;
    _recoveryTimer?.cancel();
    try {
      final result = await navigator.push(route);
      // Pop results precede the reverse animation and widget disposal.
      await route.completed;
      return result;
    } finally {
      _dialogActive = false;
      if (mounted) _onEditorChanged();
    }
  }

  Future<void> _offerRecovery(Uint8List bytes) async {
    final restore = await _showOwnedDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('이전 작업 복구'),
        content: const Text('기기에 남아 있는 편집 작업을 복구할 수 있습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('복구본 삭제'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('복구'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (restore != true) {
      await _clearRecovery();
      return;
    }
    try {
      await _editor.importProject(bytes);
      _editor.markUnsaved();
      _recoveryToken = _editor.documentToken;
      _updateUI(() => _documentName = '복구한 작업');
      _viewport.fit();
    } catch (error) {
      _showMessage('복구본을 열지 못했습니다: $error');
    }
  }

  Future<bool> _confirmDiscard({bool exiting = false}) async {
    if (_loading ||
        _fileBusy ||
        _editor.isBusy ||
        _editor.isStroking ||
        _dialogActive ||
        _discardPromptOpen ||
        !mounted) {
      return false;
    }
    if (!_editor.isDirty) return true;
    _discardPromptOpen = true;
    var allowed = false;
    _recoveryTimer?.cancel();
    try {
      final decision = await _showOwnedDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('저장하지 않은 변경'),
          content: const Text('현재 작업을 프로젝트로 저장한 뒤 계속할 수 있습니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('저장하지 않고 계속'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('프로젝트 저장'),
            ),
          ],
        ),
      );
      if (!mounted) return false;
      if (decision == 'save') {
        allowed = await _saveProject();
        return allowed;
      }
      if (decision == 'discard') {
        if (exiting) {
          await _clearRecovery();
          _recoveryToken = null;
        }
        allowed = true;
        return allowed;
      }
      return false;
    } finally {
      _discardPromptOpen = false;
      if (mounted && (!exiting || !allowed)) _onEditorChanged();
    }
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel();
    _editor.removeListener(_onEditorChanged);
    _closeGuard.dispose();
    _lifecycle.dispose();
    _viewport.dispose();
    _editor.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> _importImage() async {
    if (_fileBusy || _editor.isBusy || _loading) return;
    setState(() => _fileBusy = true);
    try {
      final picked = await EditorFiles.pickImage();
      if (picked != null && mounted) {
        await _editor.importImage(picked.bytes, picked.name);
        _showMessage('사진을 새 레이어로 추가했습니다.');
      }
    } catch (error) {
      _showMessage('사진을 불러오지 못했습니다: $error');
    } finally {
      _updateUI(() => _fileBusy = false);
    }
  }

  Future<void> _exportImage() async {
    if (_fileBusy || _editor.isBusy || _loading) return;
    setState(() => _fileBusy = true);
    try {
      final bytes = await _editor.exportPng();
      if (!mounted) return;
      final result = await EditorFiles.exportPng(
        bytes,
        fileName: 'luma-studio.png',
      );
      if (result == ExportResult.saved) _showMessage('PNG 이미지를 내보냈습니다.');
      if (result == ExportResult.downloadStarted) {
        _showMessage('PNG 다운로드를 시작했습니다.');
      }
    } catch (error) {
      _showMessage('이미지를 내보내지 못했습니다: $error');
    } finally {
      _updateUI(() => _fileBusy = false);
    }
  }

  Future<void> _newDocument() async {
    if (!await _confirmDiscard() || !mounted) return;
    _updateUI(() => _fileBusy = true);
    try {
      final width = TextEditingController(text: '1200');
      final height = TextEditingController(text: '900');
      String? error;
      final result = await _showOwnedDialog<Size>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('새 캔버스'),
            content: SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '새로운 투명 캔버스를 만듭니다.',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: width,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: '너비 (px)',
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('×'),
                      ),
                      Expanded(
                        child: TextField(
                          controller: height,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: '높이 (px)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    error ?? '128–4096 px · 투명 배경',
                    style: TextStyle(
                      fontSize: 12,
                      color: error == null ? _muted : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () {
                  final w = int.tryParse(width.text) ?? 0;
                  final h = int.tryParse(height.text) ?? 0;
                  if (w < 128 || h < 128 || w > 4096 || h > 4096) {
                    update(() => error = '너비와 높이를 128–4096 사이로 입력하세요.');
                    return;
                  }
                  Navigator.pop(context, Size(w.toDouble(), h.toDouble()));
                },
                child: const Text('만들기'),
              ),
            ],
          ),
        ),
      );
      width.dispose();
      height.dispose();
      if (result == null || !mounted) return;
      await _editor.newDocument(result.width.toInt(), result.height.toInt());
      if (mounted) {
        setState(() => _documentName = '이름 없는 작업');
        _viewport.fit();
      }
    } catch (error) {
      _showMessage('새 캔버스를 만들지 못했습니다: $error');
    } finally {
      _updateUI(() => _fileBusy = false);
    }
  }

  Future<void> _editText({bool create = false}) async {
    if (_loading || _fileBusy || _editor.isBusy || _editor.isStroking) return;
    _updateUI(() => _fileBusy = true);
    try {
      final layer = _editor.activeLayer;
      final input = TextEditingController(
        text: create ? '' : layer?.text ?? '',
      );
      double fontSize = create ? 84 : layer?.fontSize ?? 84;
      String? inputError;
      final result = await _showOwnedDialog<(String, double)>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(create ? '텍스트 추가' : '텍스트 편집'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: input,
                    autofocus: true,
                    maxLength: EditorProjectSchema.maxTextLength,
                    maxLines: 4,
                    minLines: 2,
                    decoration: InputDecoration(
                      hintText: '이야기를 더해 보세요…',
                      errorText: inputError,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Text('글자 크기'),
                      const Spacer(),
                      Text('${fontSize.round()} px'),
                    ],
                  ),
                  Slider(
                    value: fontSize.clamp(12, 240),
                    min: 12,
                    max: 240,
                    onChanged: (value) => update(() => fontSize = value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () {
                  if (input.text.trim().isNotEmpty) {
                    try {
                      EditorProjectSchema.validateText(input.text.trim());
                    } on ArgumentError catch (error) {
                      update(() => inputError = error.message.toString());
                      return;
                    }
                    Navigator.pop(context, (input.text.trim(), fontSize));
                  }
                },
                child: const Text('적용'),
              ),
            ],
          ),
        ),
      );
      input.dispose();
      if (result == null || !mounted) return;
      if (create) {
        await _editor.addText(
          result.$1,
          fontSize: result.$2,
          color: _editor.brushColor,
        );
      } else {
        await _editor.updateText(result.$1, fontSize: result.$2);
      }
    } catch (error) {
      _showMessage('텍스트를 적용하지 못했습니다: $error');
    } finally {
      _updateUI(() => _fileBusy = false);
    }
  }

  Future<void> _renameLayer() async {
    if (_loading || _fileBusy || _editor.isBusy || _editor.isStroking) return;
    final layer = _editor.activeLayer;
    if (layer == null) return;
    _updateUI(() => _fileBusy = true);
    try {
      final input = TextEditingController(text: layer.name);
      String? inputError;
      final result = await _showOwnedDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) {
            void submit() {
              try {
                EditorProjectSchema.validateLayerName(input.text.trim());
              } on ArgumentError catch (error) {
                update(() => inputError = error.message.toString());
                return;
              }
              Navigator.pop(context, input.text);
            }

            return AlertDialog(
              title: const Text('레이어 이름'),
              content: TextField(
                controller: input,
                maxLength: EditorProjectSchema.maxLayerNameLength,
                autofocus: true,
                decoration: InputDecoration(errorText: inputError),
                onSubmitted: (_) => submit(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소'),
                ),
                FilledButton(onPressed: submit, child: const Text('저장')),
              ],
            );
          },
        ),
      );
      input.dispose();
      if (result != null && result.trim().isNotEmpty && mounted) {
        _editor.renameLayer(layer.id, result.trim());
      }
    } catch (error) {
      _showMessage('레이어 이름을 변경하지 못했습니다: $error');
    } finally {
      _updateUI(() => _fileBusy = false);
    }
  }

  Future<void> _customColor() => _pickColor(
    initialColor: _editor.brushColor,
    onSelected: _editor.setBrushColor,
  );

  Future<void> _pickColor({
    required Color initialColor,
    required ValueChanged<Color> onSelected,
    String title = '색 편집',
  }) async {
    if (_loading ||
        _fileBusy ||
        _dialogActive ||
        _editor.isBusy ||
        _editor.isStroking) {
      return;
    }
    final selection = await _showOwnedDialog<EditorColorSelection>(
      context: context,
      builder: (context) => EditorColorPickerDialog(
        initialColor: initialColor,
        customColors: _customColors,
        title: title,
      ),
    );
    if (selection != null && mounted) {
      setState(() => _customColors = selection.customColors);
      onSelected(selection.color);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (event is! KeyDownEvent ||
        focused?.widget is EditableText ||
        focused?.findAncestorWidgetOfExactType<EditableText>() != null ||
        _loading ||
        _fileBusy ||
        _dialogActive ||
        _editor.isStroking ||
        _editor.isBusy) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed) {
      if (key == LogicalKeyboardKey.keyZ) {
        keys.isShiftPressed ? _editor.redo() : _editor.undo();
      } else if (key == LogicalKeyboardKey.keyY) {
        _editor.redo();
      } else if (key == LogicalKeyboardKey.keyO) {
        _importImage();
      } else if (key == LogicalKeyboardKey.keyS) {
        _saveProject();
      } else if (key == LogicalKeyboardKey.keyA) {
        _editor.selectAll();
      } else if (key == LogicalKeyboardKey.keyC) {
        _perform(_editor.copySelection);
      } else if (key == LogicalKeyboardKey.keyX) {
        _perform(_editor.cutSelection);
      } else if (key == LogicalKeyboardKey.keyV) {
        _perform(_editor.pasteSelection);
      } else if (key == LogicalKeyboardKey.keyD) {
        _editor.clearSelection();
      } else if (key == LogicalKeyboardKey.digit0) {
        _viewport.fit();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    final shortcuts = {
      LogicalKeyboardKey.keyB: EditorTool.brush,
      LogicalKeyboardKey.keyE: EditorTool.eraser,
      LogicalKeyboardKey.keyH: EditorTool.hand,
      LogicalKeyboardKey.keyM: EditorTool.marquee,
      LogicalKeyboardKey.keyV: EditorTool.transform,
      LogicalKeyboardKey.keyT: EditorTool.text,
      LogicalKeyboardKey.keyL: EditorTool.lasso,
      LogicalKeyboardKey.keyW: EditorTool.magicWand,
      LogicalKeyboardKey.keyI: EditorTool.eyedropper,
      LogicalKeyboardKey.keyG: EditorTool.gradient,
      LogicalKeyboardKey.keyS: EditorTool.cloneStamp,
      LogicalKeyboardKey.keyU: EditorTool.rectangle,
    };
    if (shortcuts.containsKey(key)) {
      _editor.setTool(shortcuts[key]!);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_editor.hasActiveTransform) {
        _transformSliderActive = false;
        _editor.cancelTransform();
      } else {
        _editor.clearSelection();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      _perform(_editor.deleteSelection);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.bracketLeft ||
        key == LogicalKeyboardKey.bracketRight) {
      _editor.setBrushSize(
        (_editor.brushSize + (key == LogicalKeyboardKey.bracketLeft ? -4 : 4))
            .clamp(1, 200),
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: _onKey,
    child: AnimatedBuilder(
      animation: Listenable.merge([_editor, _viewport]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 1000;
          final compact = constraints.maxWidth < 600;
          return PopScope<Object?>(
            canPop: !_editor.isDirty && !_editor.isBusy && !_fileBusy,
            onPopInvokedWithResult: (didPop, result) async {
              if (!didPop &&
                  await _confirmDiscard(exiting: true) &&
                  context.mounted) {
                if (Navigator.of(context).canPop()) {
                  _editor.markSaved();
                  Navigator.of(context).pop(result);
                } else {
                  await SystemNavigator.pop();
                }
              }
            },
            child: AbsorbPointer(
              absorbing: _fileBusy,
              child: Scaffold(
                body: SafeArea(
                  child: Column(
                    children: [
                      _header(desktop, constraints.maxWidth < 760),
                      _contextBar(compact),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!compact) _toolRail(),
                            Expanded(
                              child: Column(
                                children: [
                                  if (!compact) _documentTab(),
                                  Expanded(
                                    child: Stack(
                                      children: [
                                        Positioned.fill(
                                          child: _loading
                                              ? const Center(
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : EditorViewport(
                                                  controller: _editor,
                                                  viewportController: _viewport,
                                                  showGrid: _grid,
                                                  onDialogStateChanged:
                                                      (active) {
                                                        _dialogActive = active;
                                                        if (!active) {
                                                          _onEditorChanged();
                                                        }
                                                      },
                                                ),
                                        ),
                                        Positioned(
                                          top: 18,
                                          left: 18,
                                          child: IgnorePointer(
                                            child: _badge(
                                              '${_editor.documentSize.width.toInt()} × ${_editor.documentSize.height.toInt()} px',
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          right: 16,
                                          bottom: 16,
                                          child: _zoomControl(),
                                        ),
                                        if ((_fileBusy || _editor.isBusy) &&
                                            !_loading)
                                          const Positioned(
                                            top: 0,
                                            left: 0,
                                            right: 0,
                                            child: LinearProgressIndicator(
                                              minHeight: 2,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (!compact) _statusBar(),
                                ],
                              ),
                            ),
                            if (desktop)
                              Container(
                                width: 292,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  border: Border(
                                    left: BorderSide(color: _line),
                                  ),
                                ),
                                child: _inspector(),
                              ),
                          ],
                        ),
                      ),
                      if (compact) _mobileTools(),
                      if (!desktop) _mobilePanelBar(compact),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _header(bool desktop, bool compact) => Container(
    height: compact ? 64 : 76,
    padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: _line)),
    ),
    child: Row(
      children: [
        if (!compact || MediaQuery.sizeOf(context).width >= 360) ...[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _accent,
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.white,
              size: 21,
            ),
          ),
          const SizedBox(width: 10),
        ],
        Text(
          'luma',
          style: TextStyle(
            fontSize: compact ? 24 : 28,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.2,
            color: _ink,
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: 8),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'STUDIO',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.6,
                color: _muted,
              ),
            ),
          ),
        ],
        if (desktop) ...[
          const SizedBox(width: 40),
          const SizedBox(height: 24, child: VerticalDivider(width: 1)),
          const SizedBox(width: 24),
          Text(
            '$_documentName${_editor.isDirty ? ' •' : ''}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          _badge('로컬 작업', purple: true),
        ],
        const Spacer(),
        _icon(
          Icons.undo_rounded,
          '실행 취소 (Ctrl/⌘ Z)',
          _editor.canUndo ? _editor.undo : null,
        ),
        _icon(
          Icons.redo_rounded,
          '다시 실행 (Ctrl/⌘ Shift Z)',
          _editor.canRedo ? _editor.redo : null,
        ),
        if (!compact) ...[
          const SizedBox(width: 12),
          const SizedBox(height: 24, child: VerticalDivider(width: 1)),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: _fileBusy || _loading ? null : _importImage,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 19),
            label: const Text('사진 불러오기'),
            style: TextButton.styleFrom(foregroundColor: _ink),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: _fileBusy || _loading ? null : _exportImage,
            icon: const Icon(Icons.file_download_outlined, size: 19),
            label: const Text('내보내기'),
          ),
        ] else
          _icon(
            Icons.file_download_outlined,
            'PNG 내보내기',
            _loading || _fileBusy ? null : _exportImage,
          ),
        const SizedBox(width: 4),
        PopupMenuButton<String>(
          tooltip: '문서 메뉴',
          icon: const Icon(Icons.more_horiz, color: _muted),
          onSelected: _handleDocumentMenu,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'new', child: Text('새 캔버스')),
            const PopupMenuItem(value: 'import', child: Text('사진 불러오기')),
            const PopupMenuItem(
              value: 'openProject',
              child: Text('프로젝트 열기 (.luma)'),
            ),
            const PopupMenuItem(
              value: 'saveProject',
              child: Text('프로젝트 저장 (Ctrl/⌘ S)'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'tools', child: Text('모든 편집 도구')),
            const PopupMenuItem(
              value: 'actions',
              child: Text('선택 · 이미지 · 레이어 작업'),
            ),
            const PopupMenuItem(value: 'filters', child: Text('필터 · 효과')),
            const PopupMenuItem(value: 'history', child: Text('편집 기록')),
            const PopupMenuItem(value: 'help', child: Text('사용법 · 단축키')),
          ],
        ),
      ],
    ),
  );

  Widget _contextBar(bool compact) => Container(
    height: 58,
    padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 24),
    color: const Color(0xFFFCFCFE),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Icon(_toolIcon(_editor.tool), size: 18, color: _accent),
          const SizedBox(width: 10),
          Text(
            _displayToolName(_editor.tool),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          if (compact) ...[
            const SizedBox(width: 16),
            _colorDot(_editor.brushColor, true, _customColor, tooltip: '색 편집'),
          ],
          const SizedBox(width: 24),
          if (_editor.tool == EditorTool.brush ||
              _editor.tool == EditorTool.eraser ||
              _editor.tool == EditorTool.cloneStamp) ...[
            const Text('크기', style: TextStyle(color: _muted, fontSize: 12)),
            SizedBox(
              width: compact ? 100 : 140,
              child: Slider(
                value: _editor.brushSize.clamp(1, 200),
                min: 1,
                max: 200,
                onChanged: _editor.setBrushSize,
              ),
            ),
            _valuePill('${_editor.brushSize.round()} px'),
            const SizedBox(width: 24),
            const Text('불투명도', style: TextStyle(color: _muted, fontSize: 12)),
            SizedBox(
              width: 100,
              child: Slider(
                value: _editor.brushOpacity,
                onChanged: _editor.setBrushOpacity,
              ),
            ),
            _valuePill('${(_editor.brushOpacity * 100).round()}%'),
            const SizedBox(width: 24),
            if (!compact)
              _colorDot(
                _editor.brushColor,
                true,
                _customColor,
                tooltip: '색 편집',
              ),
            if (_editor.tool == EditorTool.cloneStamp) ...[
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: () => _editor.setCloneSourcePickMode(
                  !_editor.cloneSourcePickMode,
                ),
                icon: const Icon(Icons.my_location, size: 16),
                label: Text(
                  _editor.cloneSourcePickMode ? '캔버스를 눌러 원본 지정' : '복제 원본 지정',
                ),
              ),
            ],
          ] else ...[
            Text(
              _displayToolHint(_editor.tool),
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
            ..._extraToolOptions(),
            if (_editor.tool == EditorTool.text) ...[
              const SizedBox(width: 20),
              TextButton(
                onPressed: () => _editText(create: true),
                child: const Text('텍스트 추가'),
              ),
            ],
            if (_editor.selection != null) ...[
              const SizedBox(width: 20),
              TextButton.icon(
                onPressed: _editor.clearSelection,
                icon: const Icon(Icons.deselect, size: 16),
                label: const Text('선택 해제'),
              ),
            ],
          ],
        ],
      ),
    ),
  );

  Widget _toolRail() => Container(
    width: 76,
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: _line)),
    ),
    child: Column(
      children: [
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final tool in _primaryTools)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _toolButton(tool),
                  ),
                _icon(Icons.apps_rounded, '모든 편집 도구', _openTools),
                _icon(
                  Icons.dashboard_customize_outlined,
                  '선택 · 이미지 · 레이어 작업',
                  _openActions,
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Divider(),
                ),
                _colorDot(
                  _editor.brushColor,
                  true,
                  _customColor,
                  size: 32,
                  tooltip: '색 편집',
                ),
              ],
            ),
          ),
        ),
        _icon(
          Icons.grid_4x4_outlined,
          '격자 표시',
          () => setState(() => _grid = !_grid),
          selected: _grid,
        ),
        _icon(Icons.help_outline_rounded, '사용법 · 단축키', _showHelp),
        const SizedBox(height: 12),
      ],
    ),
  );

  Widget _toolButton(EditorTool tool, {bool label = false}) {
    final selected = _editor.tool == tool;
    return Tooltip(
      message: '${_displayToolName(tool)} (${_toolKey(tool)})',
      child: Material(
        color: selected ? const Color(0xFFEDE9FC) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _editor.setTool(tool),
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: label ? 55 : 46,
            height: label ? 60 : 46,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _toolIcon(tool),
                  size: 22,
                  color: selected ? _accent : const Color(0xFF8B8D9C),
                ),
                if (label) ...[
                  const SizedBox(height: 4),
                  Text(
                    _displayToolName(tool),
                    style: TextStyle(
                      fontSize: 9,
                      color: selected ? _accent : _muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mobileTools() => Container(
    height: 72,
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: _line)),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final tool in _primaryTools.take(5))
          Flexible(child: _toolButton(tool, label: true)),
        Flexible(
          child: IconButton(
            tooltip: '모든 편집 도구',
            onPressed: _openTools,
            icon: const Icon(Icons.apps_rounded),
          ),
        ),
      ],
    ),
  );

  Widget _mobilePanelBar(bool compact) => Container(
    height: 49,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    color: Colors.white,
    child: Row(
      children: [
        TextButton.icon(
          onPressed: () => _openInspector(0),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: const Icon(Icons.layers_outlined, size: 18),
          label: Text('레이어 ${_editor.layers.length}'),
        ),
        TextButton.icon(
          onPressed: () => _openInspector(1),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: const Icon(Icons.tune_rounded, size: 18),
          label: const Text('조정'),
        ),
        const Spacer(),
        _icon(Icons.auto_awesome_outlined, '필터 · 효과', () => _openInspector(2)),
        if (compact)
          _icon(Icons.add_photo_alternate_outlined, '사진 불러오기', _importImage),
        if (MediaQuery.sizeOf(context).width >= 360)
          _icon(
            Icons.grid_4x4_outlined,
            '격자 표시',
            () => setState(() => _grid = !_grid),
            selected: _grid,
          ),
      ],
    ),
  );

  Widget _documentTab() => Container(
    height: 44,
    decoration: const BoxDecoration(
      color: Color(0xFFF4F5F8),
      border: Border(bottom: BorderSide(color: _line)),
    ),
    child: Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          height: 44,
          decoration: const BoxDecoration(
            color: Color(0xFFEEF0F4),
            border: Border(right: BorderSide(color: _line)),
          ),
          child: Row(
            children: [
              const Icon(Icons.photo_outlined, size: 15, color: _muted),
              const SizedBox(width: 9),
              Text(
                '$_documentName${_editor.isDirty ? ' •' : ''}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 20),
              Tooltip(
                message: _editor.isDirty ? '저장하지 않은 변경' : '저장된 상태',
                child: Icon(
                  Icons.circle,
                  size: 5,
                  color: _editor.isDirty ? _accent : _muted,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        const Flexible(
          child: Padding(
            padding: EdgeInsets.only(right: 20),
            child: Text(
              '당신의 시선, 당신의 작품.',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: _muted),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _statusBar() => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    decoration: const BoxDecoration(
      color: Color(0xFFFCFCFE),
      border: Border(top: BorderSide(color: _line)),
    ),
    child: Row(
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: const BoxDecoration(
            color: Color(0xFF86AD9D),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 7),
        const Expanded(
          child: Text(
            '모든 편집은 기기에서 처리됩니다',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: _muted),
          ),
        ),
        Text(
          '${_editor.layers.length}개 레이어',
          style: const TextStyle(fontSize: 10, color: _muted),
        ),
        const SizedBox(width: 18),
        Text(
          _editor.renderer,
          style: const TextStyle(fontSize: 10, color: _muted),
        ),
      ],
    ),
  );

  Widget _zoomControl() => Container(
    height: 40,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _line),
      boxShadow: const [
        BoxShadow(
          color: Color(0x06000000),
          blurRadius: 12,
          offset: Offset(0, 3),
        ),
      ],
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _icon(Icons.remove, '축소', _viewport.zoomOut, size: 18),
        SizedBox(
          width: 46,
          child: Text(
            '${(_viewport.zoom * 100).round()}%',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
        _icon(Icons.add, '확대', _viewport.zoomIn, size: 18),
        const SizedBox(height: 18, child: VerticalDivider(width: 1)),
        _icon(
          Icons.fit_screen_rounded,
          '화면에 맞춤 (Ctrl/⌘ 0)',
          _viewport.fit,
          size: 19,
        ),
      ],
    ),
  );

  void _openInspector(int tab) {
    setState(() => _inspectorTab = tab);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: AnimatedBuilder(
          animation: _editor,
          builder: (context, _) => StatefulBuilder(
            builder: (context, update) => _inspector(
              onTab: (value) {
                setState(() => _inspectorTab = value);
                update(() {});
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _inspector({ValueChanged<int>? onTab}) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Row(
          children: [
            for (var i = 0; i < 4; i++)
              Expanded(
                child: InkWell(
                  onTap: () => onTab != null
                      ? onTab(i)
                      : setState(() => _inspectorTab = i),
                  child: Container(
                    padding: const EdgeInsets.only(bottom: 17),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: _inspectorTab == i ? _accent : _line,
                          width: _inspectorTab == i ? 2 : 1,
                        ),
                      ),
                    ),
                    child: Text(
                      const ['레이어', '조정', '필터', '기록'][i],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _inspectorTab == i ? _accent : _muted,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: switch (_inspectorTab) {
            0 => _layersPanel(),
            1 => _adjustmentsPanel(),
            2 => _filtersPanel(),
            _ => _historyPanel(),
          },
        ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: _line)),
        ),
        child: EditorColorPalette(
          color: _editor.brushColor,
          customColors: _customColors,
          onSelected: _editor.setBrushColor,
          onEdit: _customColor,
        ),
      ),
    ],
  );

  Widget _layersPanel() {
    final layer = _editor.activeLayer;
    final transformRotation = _editor.activeTransformRotation;
    final transformScale = _editor.activeTransformScale;
    final transformOffset = _editor.activeTransformOffset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('레이어', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            _badge('${_editor.layers.length}'),
            const Spacer(),
            _icon(Icons.add, '새 레이어', () => _editor.addLayer(), size: 19),
          ],
        ),
        const SizedBox(height: 12),
        if (layer != null) ...[
          DropdownButtonFormField<BlendMode>(
            initialValue: layer.blendMode,
            key: ValueKey('${layer.id}-${layer.blendMode.name}'),
            isExpanded: true,
            style: const TextStyle(fontSize: 12, color: _ink),
            decoration: const InputDecoration(labelText: '블렌드 모드'),
            items: _blendModes.entries
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) _editor.setLayerBlendMode(value);
            },
          ),
          const SizedBox(height: 18),
          _propertySlider(
            '불투명도',
            layer.opacity,
            0,
            1,
            '${(layer.opacity * 100).round()}%',
            _editor.setLayerOpacity,
          ),
          const SizedBox(height: 12),
        ],
        for (final item in _editor.layers.reversed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _layerTile(item),
          ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _icon(
              Icons.drive_file_rename_outline,
              '레이어 이름 변경',
              layer == null ? null : _renameLayer,
              size: 18,
            ),
            _icon(
              Icons.content_copy_outlined,
              '레이어 복제',
              layer == null ? null : _editor.duplicateActiveLayer,
              size: 18,
            ),
            _icon(
              Icons.arrow_upward,
              '레이어 위로',
              layer == null || _editor.layers.last.id == layer.id
                  ? null
                  : () => _editor.moveLayer(layer.id, 1),
              size: 18,
            ),
            _icon(
              Icons.arrow_downward,
              '레이어 아래로',
              layer == null || _editor.layers.first.id == layer.id
                  ? null
                  : () => _editor.moveLayer(layer.id, -1),
              size: 18,
            ),
            _icon(
              Icons.delete_outline,
              '레이어 삭제',
              layer == null || layer.locked ? null : _editor.removeActiveLayer,
              size: 18,
            ),
          ],
        ),
        if (layer?.isText ?? false) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _editText(),
            icon: const Icon(Icons.text_fields, size: 18),
            label: const Text('텍스트 편집'),
          ),
        ],
        if (layer != null) ...[
          const SizedBox(height: 12),
          _maskControls(layer),
        ],
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 16),
        _sectionHeading(
          _hasTransformSelection ? '선택 영역 변형' : '레이어 변형',
          Icons.open_with_rounded,
        ),
        if (_hasTransformSelection) ...[
          const SizedBox(height: 10),
          const Text(
            '선택한 픽셀만 이동·회전·확대합니다.\n슬라이더를 놓으면 현재 변형을 적용합니다.',
            style: TextStyle(fontSize: 11, color: _muted, height: 1.6),
          ),
        ],
        const SizedBox(height: 20),
        if (layer != null) ...[
          _propertySlider(
            '회전',
            transformRotation * 180 / math.pi,
            -180,
            180,
            '${(transformRotation * 180 / math.pi).round()}°',
            (value) =>
                _editor.setActiveTransform(rotation: value * math.pi / 180),
            transform: true,
          ),
          const SizedBox(height: 16),
          _propertySlider(
            '크기',
            transformScale,
            .1,
            4,
            '${(transformScale * 100).round()}%',
            (value) => _editor.setActiveTransform(scale: value),
            transform: true,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                'X ${transformOffset.dx.round()}   Y ${transformOffset.dy.round()}',
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
              const Spacer(),
              TextButton(
                onPressed: _hasTransformSelection
                    ? (_editor.hasActiveTransform
                          ? () {
                              _transformSliderActive = false;
                              _editor.cancelTransform();
                            }
                          : null)
                    : _resetLayerTransform,
                child: Text(
                  _hasTransformSelection ? '변형 취소' : '초기화',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F3FC),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lightbulb_outline_rounded, size: 17, color: _accent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '레이어를 나누면 더 자유로워져요.\n각 요소를 따로 편집해 보세요.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF9589B7),
                    height: 1.7,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _layerTile(EditorLayer layer) {
    final selected = layer.id == _editor.activeLayerId;
    return Material(
      color: selected ? const Color(0xFFF0ECFC) : const Color(0xFFF8F9FB),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: () => _editor.selectLayer(layer.id),
        onDoubleTap: () {
          _editor.selectLayer(layer.id);
          _renameLayer();
        },
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.fromLTRB(9, 10, 3, 10),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? const Color(0xFFDCD3FA)
                  : const Color(0xFFF0F1F5),
            ),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 36,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: const Color(0xFFE3E4ED)),
                ),
                child: RawImage(image: layer.image, fit: BoxFit.contain),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      layer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: layer.visible ? _ink : _muted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      layer.isText ? '텍스트 레이어' : '이미지 레이어',
                      style: const TextStyle(fontSize: 9, color: _muted),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: MediaQuery.sizeOf(context).width < 1000 ? 44 : 30,
                child: _icon(
                  layer.locked ? Icons.lock_outline : Icons.lock_open_rounded,
                  layer.locked ? '잠금 해제' : '레이어 잠금',
                  () => _editor.toggleLayerLock(layer.id),
                  size: 14,
                ),
              ),
              SizedBox(
                width: MediaQuery.sizeOf(context).width < 1000 ? 44 : 30,
                child: _icon(
                  layer.visible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  layer.visible ? '레이어 숨기기' : '레이어 표시',
                  () => _editor.toggleLayerVisibility(layer.id),
                  size: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _adjustmentsPanel() {
    final layer = _editor.activeLayer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeading('빛과 색상', Icons.tune_rounded),
        const SizedBox(height: 10),
        const Text(
          '선택한 레이어의 분위기를 조절하세요.',
          style: TextStyle(fontSize: 11, color: _muted, height: 1.6),
        ),
        const SizedBox(height: 28),
        if (layer != null) ...[
          _propertySlider(
            '밝기',
            layer.brightness,
            -1,
            1,
            '${(layer.brightness * 100).round()}',
            (value) => _editor.setAdjustments(brightness: value),
          ),
          const SizedBox(height: 24),
          _propertySlider(
            '대비',
            layer.contrast,
            0,
            2,
            '${(layer.contrast * 100).round()}%',
            (value) => _editor.setAdjustments(contrast: value),
          ),
          const SizedBox(height: 24),
          _propertySlider(
            '채도',
            layer.saturation,
            0,
            2,
            '${(layer.saturation * 100).round()}%',
            (value) => _editor.setAdjustments(saturation: value),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => _editor.setAdjustments(
              brightness: 0,
              contrast: 1,
              saturation: 1,
            ),
            icon: const Icon(Icons.restart_alt, size: 17),
            label: const Text('색상 조정 초기화'),
          ),
        ],
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 24),
        _sectionHeading('선택 영역', Icons.crop_free_rounded),
        const SizedBox(height: 12),
        Text(
          _editor.selection == null
              ? '선택 도구로 편집 범위를 지정하세요. 브러시·지우개·변형은 선택 영역에 적용됩니다.'
              : '${_editor.selection!.width.round()} × ${_editor.selection!.height.round()} px 선택됨',
          style: const TextStyle(fontSize: 12, color: _muted, height: 1.7),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _editor.selection == null
              ? () => _editor.setTool(EditorTool.marquee)
              : _editor.clearSelection,
          icon: Icon(
            _editor.selection == null ? Icons.crop_free : Icons.deselect,
            size: 17,
          ),
          label: Text(_editor.selection == null ? '영역 선택하기' : '선택 해제'),
        ),
      ],
    );
  }

  Widget _propertySlider(
    String label,
    double value,
    double min,
    double max,
    String display,
    ValueChanged<double> onChanged, {
    bool transform = false,
  }) => Column(
    children: [
      Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF747887)),
          ),
          const Spacer(),
          _valuePill(display),
        ],
      ),
      SizedBox(
        height: 30,
        child: Listener(
          onPointerCancel: transform ? (_) => _cancelTransformSlider() : null,
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChangeStart: (_) {
              if (transform) {
                _transformSliderActive = _editor.beginTransform();
              } else {
                _editor.beginTransaction(label);
              }
            },
            onChanged:
                transform &&
                    (_editor.isBusy ||
                        _editor.activeLayer == null ||
                        _editor.activeLayer!.locked ||
                        !_editor.activeLayer!.visible)
                ? null
                : (value) {
                    if (!transform ||
                        (_transformSliderActive &&
                            _editor.hasActiveTransform)) {
                      onChanged(value);
                    }
                  },
            onChangeEnd: (_) {
              if (transform) {
                if (!_transformSliderActive) return;
                _transformSliderActive = false;
                _perform(_editor.commitTransform);
              } else {
                _editor.commitTransaction();
              }
            },
          ),
        ),
      ),
    ],
  );

  void _cancelTransformSlider() {
    if (!_transformSliderActive) return;
    _transformSliderActive = false;
    _editor.cancelTransform();
  }

  void _resetLayerTransform() {
    if (!_editor.beginTransform()) return;
    _editor.setActiveTransform(offset: Offset.zero, rotation: 0, scale: 1);
    _perform(_editor.commitTransform);
  }

  Widget _sectionHeading(String text, IconData icon) => Row(
    children: [
      Icon(icon, size: 16, color: _muted),
      const SizedBox(width: 9),
      Text(
        text,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ],
  );
  Widget _valuePill(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xFFF4F5F9),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 10, color: Color(0xFF757987)),
    ),
  );
  Widget _badge(String text, {bool purple = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: purple ? const Color(0xFFF1EDFC) : const Color(0xBFFFFFFF),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 9,
        color: purple ? _accent : _muted,
        letterSpacing: .2,
      ),
    ),
  );
  Widget _icon(
    IconData icon,
    String tooltip,
    VoidCallback? onTap, {
    double size = 20,
    bool selected = false,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    icon: Icon(icon, size: size),
    color: selected ? _accent : null,
    padding: const EdgeInsets.all(8),
    constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
  );
  Widget _colorDot(
    Color color,
    bool selected,
    VoidCallback onTap, {
    double size = 26,
    String? tooltip,
  }) => Tooltip(
    message:
        tooltip ??
        '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(selected ? 3 : 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected
                ? color == Colors.white
                      ? _muted
                      : color
                : const Color(0xFFE5E6ED),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    ),
  );

  void _showHelp() => _showOwnedDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('작은 도구로, 더 큰 가능성'),
      content: const SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Text(
            'PC\nB 브러시 · E 지우개 · H 이동 · M 선택\nV 선택 영역/레이어 변형 · T 텍스트\nL 올가미 · W 자동 선택 · I 스포이드\nG 그라디언트 · S 복제 도장 · U 도형\n마우스 휠: 포인터 중심 확대/축소\nSpace + 드래그 / 가운데 버튼: 캔버스 이동\n[ / ]: 브러시 크기\nCtrl/⌘ Z: 실행 취소\nCtrl/⌘ Shift Z: 다시 실행\nCtrl/⌘ O: 사진 불러오기\nCtrl/⌘ S: 프로젝트 저장\nCtrl/⌘ 0: 화면에 맞춤\nEscape / Ctrl/⌘ D: 선택 해제\n\n모바일\n한 손가락으로 현재 도구 사용\n두 손가락으로 화면 이동·확대/축소\n하단 레이어·조정 버튼으로 상세 편집\n도구 모음에서 선택·리터칭·도형 도구 사용\n복제 도장: 원본 지정 버튼을 누른 뒤 캔버스 터치\n\n영역을 선택한 뒤 변형 도구를 사용하면 현재 레이어의 선택한 픽셀만 이동·회전·확대합니다. 선택 상자를 드래그해 이동하고, 모서리와 위쪽 회전 손잡이로 크기·각도를 바꾸세요. 선택하지 않으면 레이어 전체를 변형합니다. 마우스나 손가락을 놓으면 한 번에 적용되고, Escape 또는 두 번째 손가락 터치로 진행 중 변형을 취소합니다.\n\n사진은 새 레이어로 추가됩니다. PNG는 보이는 레이어를 합친 이미지로 저장되며, 레이어·텍스트·마스크는 .luma 프로젝트로 저장하고 다시 열 수 있습니다. 편집 기록은 현재 세션에서 유지됩니다.',
            style: TextStyle(fontSize: 13, height: 1.8),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('시작하기'),
        ),
      ],
    ),
  );
}

const _blendModes = <BlendMode, String>{
  BlendMode.srcOver: '일반 · Normal',
  BlendMode.multiply: '곱하기 · Multiply',
  BlendMode.screen: '스크린 · Screen',
  BlendMode.overlay: '오버레이 · Overlay',
  BlendMode.darken: '어둡게 · Darken',
  BlendMode.lighten: '밝게 · Lighten',
  BlendMode.difference: '차이 · Difference',
  BlendMode.plus: '더하기 · Add',
};
IconData _toolIcon(EditorTool tool) => switch (tool) {
  EditorTool.brush => Icons.brush_outlined,
  EditorTool.eraser => Icons.auto_fix_normal_outlined,
  EditorTool.hand => Icons.pan_tool_outlined,
  EditorTool.marquee => Icons.crop_free_rounded,
  EditorTool.transform => Icons.open_with_rounded,
  EditorTool.text => Icons.text_fields_rounded,
  EditorTool.ellipticalMarquee => Icons.circle_outlined,
  EditorTool.lasso => Icons.gesture_rounded,
  EditorTool.magicWand => Icons.auto_fix_high,
  EditorTool.eyedropper => Icons.colorize,
  EditorTool.fill => Icons.format_color_fill,
  EditorTool.gradient => Icons.gradient,
  EditorTool.rectangle => Icons.rectangle_outlined,
  EditorTool.ellipse => Icons.circle_outlined,
  EditorTool.cloneStamp => Icons.copy_all_outlined,
};
String _toolName(EditorTool tool) => switch (tool) {
  EditorTool.brush => '브러시',
  EditorTool.eraser => '지우개',
  EditorTool.hand => '화면 이동',
  EditorTool.marquee => '영역 선택',
  EditorTool.transform => '변형',
  EditorTool.text => '텍스트',
  EditorTool.ellipticalMarquee => '타원 선택',
  EditorTool.lasso => '올가미',
  EditorTool.magicWand => '자동 선택',
  EditorTool.eyedropper => '스포이드',
  EditorTool.fill => '페인트 통',
  EditorTool.gradient => '그라디언트',
  EditorTool.rectangle => '사각형 도형',
  EditorTool.ellipse => '타원 도형',
  EditorTool.cloneStamp => '복제 도장',
};
String _toolKey(EditorTool tool) => switch (tool) {
  EditorTool.brush => 'B',
  EditorTool.eraser => 'E',
  EditorTool.hand => 'H',
  EditorTool.marquee => 'M',
  EditorTool.transform => 'V',
  EditorTool.text => 'T',
  EditorTool.lasso => 'L',
  EditorTool.magicWand => 'W',
  EditorTool.eyedropper => 'I',
  EditorTool.gradient => 'G',
  EditorTool.rectangle => 'U',
  EditorTool.cloneStamp => 'S',
  _ => '도구 모음',
};
String _toolHint(EditorTool tool) => switch (tool) {
  EditorTool.brush => '드래그하여 그리기',
  EditorTool.eraser => '현재 레이어에서 지우기',
  EditorTool.hand => '드래그하여 화면 이동 · 두 손가락으로 확대/축소',
  EditorTool.marquee => '드래그하여 사각형 선택 · Esc로 해제',
  EditorTool.transform => '드래그하여 이동 · 모서리로 크기 조절 · 위쪽 손잡이로 회전',
  EditorTool.text => '캔버스를 눌러 텍스트 추가',
  EditorTool.ellipticalMarquee => '드래그하여 타원 선택',
  EditorTool.lasso => '자유롭게 그려 선택 영역 닫기',
  EditorTool.magicWand => '비슷한 색으로 연결된 영역 선택',
  EditorTool.eyedropper => '보이는 이미지에서 색상 추출',
  EditorTool.fill => '연결된 같은 색 영역을 채우기',
  EditorTool.gradient => '드래그한 방향으로 두 색상 채우기',
  EditorTool.rectangle => '드래그하여 사각형 그리기',
  EditorTool.ellipse => '드래그하여 타원 그리기',
  EditorTool.cloneStamp => 'Alt 클릭 또는 원본 지정 후 드래그',
};
// SCREEN_COMPLETE
