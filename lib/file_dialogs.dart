import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

// file_picker 12 changed two things this app relies on: pickFiles returns a
// bare list, and saveFile writes the file itself from bytes handed over up
// front. Every caller here builds its file AFTER the path is chosen, so these
// keep the old shape: a result that is null when canceled, and a save dialog
// that only picks a path.

/// What [pickFilesCompat] returns; null means the dialog was canceled.
class FilePickerResult {
  const FilePickerResult(this.files);
  final List<PlatformFile> files;
}

/// The open dialog. One file unless [allowMultiple].
Future<FilePickerResult?> pickFilesCompat({
  String? dialogTitle,
  String? initialDirectory,
  FileType type = FileType.any,
  List<String>? allowedExtensions,
  bool allowMultiple = false,
}) async {
  if (allowMultiple) {
    final files = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: type,
      allowedExtensions: allowedExtensions,
    );
    return files.isEmpty ? null : FilePickerResult(files);
  }
  final file = await FilePicker.pickFile(
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
    type: type,
    allowedExtensions: allowedExtensions,
  );
  return file == null ? null : FilePickerResult([file]);
}

/// The save dialog, returning the chosen path without writing anything.
///
/// The plugin writes its bytes to the chosen file as soon as the dialog
/// closes. Handed an empty list that would blank a file the user chose to
/// replace before the caller had its new contents, so the write is caught in
/// a zone and dropped; the caller writes the real file.
Future<String?> saveFileCompat({
  required String fileName,
  String? dialogTitle,
  String? initialDirectory,
  FileType type = FileType.any,
  List<String>? allowedExtensions,
}) async {
  final uri = await IOOverrides.runZoned(
    () => FilePicker.saveFile(
      fileName: fileName,
      bytes: Uint8List(0),
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: type,
      allowedExtensions: allowedExtensions,
    ),
    createFile: (path) => _PathOnly(path),
  );
  if (uri == null) return null;
  return uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
}

/// Stands in for the file the plugin would write; writing does nothing.
class _PathOnly implements File {
  _PathOnly(this.path);

  @override
  final String path;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async => this;

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Only a path is picked here.');
}
