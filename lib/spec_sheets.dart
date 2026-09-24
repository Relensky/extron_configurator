import 'dart:io';

import 'package:path/path.dart' as path;

import 'av_device_library.dart';

/// ============================================================================
///  SPEC SHEETS IN ONE SHARED FOLDER
/// ============================================================================
///  The catalog says what a product is; its spec sheet is where somebody goes
///  to check. Both are shared: the catalog on the department's share, and the
///  spec sheets in one folder beside it (App Config > Spec Sheet Folder), so a
///  sheet attached on one machine opens on every other.
///
///  An entry names its sheet RELATIVE to that folder - `Extron/DTP_CrossPoint_84.pdf`
///  - never with a drive letter, because the same share is S:\ on one desk and
///  \\server\av on the next. A web address and an absolute path are allowed
///  too, for a sheet that lives somewhere else.
///
///  An entry with nothing attached still finds a sheet that follows the naming
///  convention - `<maker>/<model>.pdf` or `<model>.pdf` - so a folder somebody
///  filled by hand works without anybody editing four hundred entries.
/// ============================================================================

/// File types a spec sheet may be.
const kSpecSheetExtensions = ['pdf', 'docx', 'doc', 'xlsx', 'png', 'jpg'];

/// A model or maker as a file name: `DTP CrossPoint 84 4K` -> `DTP_CrossPoint_84_4K`.
String specSheetSafeName(String s) => s
    .trim()
    .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
    .replaceAll(RegExp(r'\s+'), '_');

/// Whether [ref] is a web address rather than a file.
bool specSheetIsUrl(String ref) {
  final uri = Uri.tryParse(ref.trim());
  return uri != null &&
      uri.hasScheme &&
      (uri.scheme == 'http' || uri.scheme == 'https');
}

/// Where [entry]'s spec sheet is: the attached one resolved against [folder],
/// else the first file following the naming convention. '' when there is none.
String resolveSpecSheet(AvDeviceTemplate entry, String folder) {
  final ref = entry.specSheet.trim();
  if (ref.isNotEmpty) {
    if (specSheetIsUrl(ref)) return ref;
    final full = path.isAbsolute(ref) ? ref : path.join(folder, ref);
    return full;
  }
  return findSpecSheetByName(entry, folder);
}

/// The file in [folder] named for [entry]'s model, if any: under the maker's
/// sub-folder first, then at the top level.
String findSpecSheetByName(AvDeviceTemplate entry, String folder) {
  if (folder.isEmpty || entry.model.trim().isEmpty) return '';
  final stem = specSheetSafeName(entry.model);
  final dirs = [
    if (entry.manufacturer.trim().isNotEmpty)
      path.join(folder, specSheetSafeName(entry.manufacturer)),
    folder,
  ];
  for (final dir in dirs) {
    for (final ext in kSpecSheetExtensions) {
      final candidate = path.join(dir, '$stem.$ext');
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return '';
}

/// How [file] is stored on the entry: relative to [folder] when it is inside
/// it, as given otherwise.
String specSheetReference(String file, String folder) {
  if (folder.isNotEmpty && path.isWithin(folder, file)) {
    return path.relative(file, from: folder).replaceAll('\\', '/');
  }
  return file;
}

/// Copies [source] into the shared folder under the naming convention -
/// `<folder>/<maker>/<model>.<ext>` - and returns the reference to store on
/// the entry. A file already inside the folder is referenced where it is,
/// not copied again.
Future<String> attachSpecSheet({
  required AvDeviceTemplate entry,
  required String source,
  required String folder,
}) async {
  if (folder.isEmpty) {
    throw const FileSystemException('No spec sheet folder is set.');
  }
  if (path.isWithin(folder, source)) {
    return specSheetReference(source, folder);
  }
  final ext = path.extension(source).toLowerCase();
  final dir = entry.manufacturer.trim().isEmpty
      ? folder
      : path.join(folder, specSheetSafeName(entry.manufacturer));
  await Directory(dir).create(recursive: true);
  var target = path.join(dir, '${specSheetSafeName(entry.model)}$ext');
  // Never over the top of a different sheet somebody else already filed.
  if (await File(target).exists()) {
    final same = await File(target).length() == await File(source).length();
    if (!same) {
      var n = 2;
      while (await File(target).exists()) {
        target = path.join(dir, '${specSheetSafeName(entry.model)}_$n$ext');
        n++;
      }
    }
  }
  if (!await File(target).exists()) await File(source).copy(target);
  return specSheetReference(target, folder);
}

/// How many entries of [entries] have a sheet, attached or found by name.
int countSpecSheets(Iterable<AvDeviceTemplate> entries, String folder) {
  var n = 0;
  for (final e in entries) {
    final r = resolveSpecSheet(e, folder);
    if (r.isEmpty) continue;
    if (specSheetIsUrl(r) || File(r).existsSync()) n++;
  }
  return n;
}
