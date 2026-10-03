import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphotoeditor/services/editor_files.dart';

class _TestFilePicker extends FilePicker {
  FilePickerResult? picked;
  String? savedPath;
  Uint8List? writtenBytes;
  String? writtenName;
  bool? requestedData;
  Exception? failure;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    requestedData = withData;
    if (failure != null) throw failure!;
    return picked;
  }

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
    if (failure != null) throw failure!;
    writtenBytes = bytes;
    writtenName = fileName;
    return savedPath;
  }
}

void main() {
  late _TestFilePicker picker;
  setUp(() {
    picker = _TestFilePicker();
    FilePicker.platform = picker;
  });

  test('import cancellation does not fabricate an image', () async {
    expect(await EditorFiles.pickImage(), isNull);
  });

  test('import reads bytes and preserves the selected filename', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    picker.picked = FilePickerResult([
      PlatformFile(name: '여행.png', size: bytes.length, bytes: bytes),
    ]);
    final image = await EditorFiles.pickImage();
    expect(image!.name, '여행.png');
    expect(image.bytes, bytes);
    expect(picker.requestedData, isTrue);
  });

  test('unreadable import reports a failure', () async {
    picker.picked = FilePickerResult([PlatformFile(name: 'bad.png', size: 0)]);
    expect(EditorFiles.pickImage(), throwsFormatException);
  });

  test(
    'native export cancellation is distinct from a successful save',
    () async {
      final bytes = Uint8List.fromList([137, 80, 78, 71]);
      expect(await EditorFiles.exportPng(bytes), ExportResult.cancelled);
      picker.savedPath = 'C:/Pictures/photo.png';
      expect(await EditorFiles.exportPng(bytes), ExportResult.saved);
      expect(picker.writtenBytes, bytes);
    },
  );

  test(
    'export sanitizes portable filenames and keeps a PNG extension',
    () async {
      await EditorFiles.exportPng(Uint8List(4), fileName: '../휴가:편집');
      expect(picker.writtenName, '.._휴가_편집.png');
    },
  );

  test('save failures propagate so the UI cannot claim success', () async {
    picker.failure = Exception('Storage is unavailable');
    expect(EditorFiles.exportPng(Uint8List(4)), throwsException);
  });
}
