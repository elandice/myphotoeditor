import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

class PickedEditorImage {
  const PickedEditorImage({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;
}

enum ExportResult { saved, cancelled, downloadStarted }

/// System file dialogs on desktop/mobile and the browser's picker/download UI.
abstract final class EditorFiles {
  static Future<PickedEditorImage?> pickProject() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Luma 프로젝트 열기',
      type: FileType.custom,
      allowedExtensions: const ['luma'],
      withData: true,
      allowMultiple: false,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    if (file.bytes == null || file.bytes!.isEmpty) {
      throw const FormatException('프로젝트를 읽을 수 없습니다.');
    }
    return PickedEditorImage(bytes: file.bytes!, name: file.name);
  }

  static Future<ExportResult> saveProject(
    Uint8List bytes, {
    String fileName = 'luma-project.luma',
  }) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Luma 프로젝트 저장',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['luma'],
      bytes: bytes,
      lockParentWindow: true,
    );
    if (kIsWeb) return ExportResult.downloadStarted;
    return path == null ? ExportResult.cancelled : ExportResult.saved;
  }

  static Future<PickedEditorImage?> pickImage() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '사진 가져오기',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
      withData: true,
      allowMultiple: false,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('선택한 이미지의 데이터를 읽을 수 없습니다.');
    }
    return PickedEditorImage(bytes: bytes, name: file.name);
  }

  static Future<ExportResult> exportPng(
    Uint8List bytes, {
    String fileName = 'luma-studio.png',
  }) async {
    if (bytes.isEmpty) throw ArgumentError('내보낼 이미지가 비어 있습니다.');
    var safeName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    if (safeName.trim().isEmpty) safeName = 'luma-studio';
    if (!safeName.toLowerCase().endsWith('.png')) safeName += '.png';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'PNG 이미지 내보내기',
      fileName: safeName,
      type: FileType.custom,
      allowedExtensions: const ['png'],
      bytes: bytes,
      lockParentWindow: true,
    );
    // Browsers do not disclose download paths or whether a download is kept.
    if (kIsWeb) return ExportResult.downloadStarted;
    return path == null ? ExportResult.cancelled : ExportResult.saved;
  }
}
