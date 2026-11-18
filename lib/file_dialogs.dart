import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'ios_file_browser.dart';

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
  // iOS: the app's own browser, so the path is the real file and the folder
  // it sits in - see ios_file_browser.dart.
  if (Platform.isIOS) {
    final picked = await IosFileBrowser.show(
      mode: allowMultiple ? IosBrowseMode.openMany : IosBrowseMode.open,
      title: dialogTitle,
      initialDirectory: initialDirectory,
      extensions: type == FileType.custom ? allowedExtensions : null,
    );
    if (picked == null) return null;
    if (!identical(picked, IosFileBrowser.otherLocation)) {
      return FilePickerResult([for (final path in picked) _LocalFile(path)]);
    }
  }
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
  if (Platform.isIOS) {
    final picked = await IosFileBrowser.show(
      mode: IosBrowseMode.save,
      title: dialogTitle,
      initialDirectory: initialDirectory,
      extensions: type == FileType.custom ? allowedExtensions : null,
      fileName: fileName,
    );
    if (picked == null) return null;
    if (!identical(picked, IosFileBrowser.otherLocation)) return picked.single;
  }
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

/// The folder dialog. On iOS the app's own browser: iOS's folder picker
/// grants a folder only until the app restarts.
Future<String?> getDirectoryPathCompat({
  String? dialogTitle,
  String? initialDirectory,
}) async {
  if (Platform.isIOS) {
    final picked = await IosFileBrowser.show(
      mode: IosBrowseMode.folder,
      title: dialogTitle,
      initialDirectory: initialDirectory,
    );
    return picked?.single;
  }
  return FilePicker.getDirectoryPath(
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
  );
}

/// A file chosen in the iOS browser: the file itself, by its path.
base class _LocalFile extends PlatformFile {
  _LocalFile(String path) : name = p.basename(path), uri = Uri.file(path);

  @override
  final String name;

  @override
  final Uri uri;

  File get _file => File(uri.toFilePath());

  @override
  XFile get xFile => XFile(uri.toFilePath(), name: name);

  @override
  int? lengthSync() {
    try {
      return _file.lengthSync();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int?> length() async => lengthSync();

  @override
  Future<Uint8List> readAsBytes() => _file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      _file.openRead().map((b) => b is Uint8List ? b : Uint8List.fromList(b));
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
