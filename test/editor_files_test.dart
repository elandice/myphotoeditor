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
  bool? requestedStream;
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
    requestedStream = withReadStream;
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
    expect(picker.requestedData, isFalse);
    expect(picker.requestedStream, isTrue);
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

  test(
    'project import reads a stream after checking the advertised size',
    () async {
      picker.picked = FilePickerResult([
        PlatformFile(
          name: '작업.luma',
          size: 4,
          readStream: Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
        ),
      ]);
      final file = await EditorFiles.pickProject();
      expect(file!.bytes, [1, 2, 3, 4]);
      expect(file.name, '작업.luma');
      expect(picker.requestedData, isFalse);
      expect(picker.requestedStream, isTrue);
    },
  );

  test(
    'oversized project is rejected before subscribing to its stream',
    () async {
      var read = false;
      Stream<List<int>> data() async* {
        read = true;
        yield [1];
      }

      picker.picked = FilePickerResult([
        PlatformFile(
          name: 'huge.luma',
          size: (128 << 20) + 1,
          readStream: data(),
        ),
      ]);
      await expectLater(EditorFiles.pickProject(), throwsFormatException);
      expect(read, isFalse);
    },
  );

  test(
    'stream limit is enforced when the advertised size is inaccurate',
    () async {
      var cancelled = false;
      var chunksRead = 0;
      final chunk = Uint8List(1 << 20);
      Stream<List<int>> data() async* {
        try {
          for (var index = 0; index < 130; index++) {
            chunksRead++;
            yield chunk;
          }
        } finally {
          cancelled = true;
        }
      }

      picker.picked = FilePickerResult([
        PlatformFile(name: 'hidden-size.luma', size: 1, readStream: data()),
      ]);
      await expectLater(EditorFiles.pickProject(), throwsFormatException);
      expect(cancelled, isTrue);
      expect(chunksRead, 129);
    },
  );

  test(
    'project cancellation and save failures keep their original contract',
    () async {
      expect(await EditorFiles.pickProject(), isNull);
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(await EditorFiles.saveProject(bytes), ExportResult.cancelled);
      picker.savedPath = 'C:/Pictures/project.luma';
      expect(await EditorFiles.saveProject(bytes), ExportResult.saved);
      expect(picker.writtenBytes, bytes);
      picker.failure = Exception('Storage is unavailable');
      await expectLater(EditorFiles.saveProject(bytes), throwsException);
    },
  );

  test('project save sanitizes its name and refuses empty data', () async {
    await EditorFiles.saveProject(Uint8List(4), fileName: '../작업:편집');
    expect(picker.writtenName, '.._작업_편집.luma');
    await expectLater(
      EditorFiles.saveProject(Uint8List(0)),
      throwsArgumentError,
    );
  });
}
