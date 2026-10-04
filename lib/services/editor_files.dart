import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../editor/editor_project_schema.dart';

class PickedEditorImage {
  const PickedEditorImage({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;
}

enum ExportResult { saved, cancelled, downloadStarted }

/// System file dialogs on desktop/mobile and the browser's picker/download UI.
abstract final class EditorFiles {
  static const maxImageInputBytes = 128 << 20;

  static Future<Uint8List> _readPickedFile(
    PlatformFile file, {
    required int maxBytes,
  }) async {
    if (file.size > maxBytes) {
      throw const FormatException('선택한 파일은 128MiB 이하여야 합니다.');
    }
    // Some platforms provide bytes even when a stream was requested. Validate
    // those too; the normal stream path avoids loading oversized files first.
    final bytes = file.bytes;
    if (bytes != null) {
      if (bytes.length > maxBytes) {
        throw const FormatException('선택한 파일은 128MiB 이하여야 합니다.');
      }
      if (bytes.isEmpty) throw const FormatException('파일을 읽을 수 없습니다.');
      return bytes;
    }
    final stream = file.readStream;
    if (stream == null) throw const FormatException('파일을 읽을 수 없습니다.');
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > maxBytes) {
        // Exiting await-for cancels the subscription before any further reads.
        throw const FormatException('선택한 파일은 128MiB 이하여야 합니다.');
      }
      builder.add(chunk);
    }
    if (builder.isEmpty) throw const FormatException('파일을 읽을 수 없습니다.');
    return builder.takeBytes();
  }

  static Future<PickedEditorImage?> pickProject() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Luma 프로젝트 열기',
      type: FileType.custom,
      allowedExtensions: const ['luma'],
      withData: false,
      withReadStream: true,
      allowMultiple: false,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final bytes = await _readPickedFile(
      file,
      maxBytes: EditorProjectSchema.maxProjectBytes,
    );
    return PickedEditorImage(bytes: bytes, name: file.name);
  }

  static Future<ExportResult> saveProject(
    Uint8List bytes, {
    String fileName = 'luma-project.luma',
  }) async {
    if (bytes.isEmpty) throw ArgumentError('저장할 프로젝트가 비어 있습니다.');
    if (bytes.length > EditorProjectSchema.maxProjectBytes) {
      throw ArgumentError('프로젝트 파일은 128MiB 이하여야 합니다.');
    }
    var safeName = fileName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    if (safeName.trim().isEmpty) safeName = 'luma-project';
    if (!safeName.toLowerCase().endsWith('.luma')) safeName += '.luma';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Luma 프로젝트 저장',
      fileName: safeName,
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
      withData: false,
      withReadStream: true,
      allowMultiple: false,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final bytes = await _readPickedFile(file, maxBytes: maxImageInputBytes);
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
