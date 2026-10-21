import 'dart:io';

import 'package:path/path.dart' as path;

import 'manuals_catalog.dart';

/// ============================================================================
///  DEVICE MANUALS AND MODULE MANUALS
/// ============================================================================
///  Two kinds of paperwork, kept apart on purpose:
///    * DEVICE manuals - the hardware's own user and setup guides, from the
///      Manuals catalog the CTS Dashboard also reads (App Config > Manuals
///      Folder: the file share, else the Root Folder's manuals folder).
///    * MODULE manuals - the PDF for each python driver, `<module>.pdf` in the
///      Documentation Path (see AppStateProvider.locateModuleManual).
///  The report lists what is missing from each.
/// ============================================================================

/// Where the dashboard keeps the shared copy of the Manuals catalog.
const String kDashboardManualsFolder =
    r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology\Dashboard\manuals';

/// The catalog under [folder], read once and kept until manuals.json changes.
class ManualsCatalogCache {
  ManualsCatalogCache._();

  static String _folder = '';
  static DateTime? _stamp;
  static ManualsCatalog? _catalog;

  /// Null when [folder] has no readable catalog.
  static Future<ManualsCatalog?> load(String folder) async {
    final file = File(ManualsCatalog.catalogPath(folder));
    DateTime? stamp;
    try {
      stamp = await file.exists() ? await file.lastModified() : null;
    } catch (_) {
      stamp = null;
    }
    if (folder == _folder && stamp == _stamp && (_catalog != null || stamp == null)) {
      return _catalog;
    }
    _folder = folder;
    _stamp = stamp;
    _catalog = stamp == null ? null : await ManualsCatalog.load(folder);
    return _catalog;
  }

  /// Forget the cached copy, so the next [load] reads the file again.
  static void clear() {
    _folder = '';
    _stamp = null;
    _catalog = null;
  }
}

/// How far a model's device manuals have got.
enum DeviceManualStatus {
  /// The catalog lists at least one document for it.
  found,

  /// The catalog knows the model but has nothing filed for it.
  noDocuments,

  /// The catalog has never heard of the model.
  notInCatalog,
}

/// One model a driver supports, and what the catalog has for it.
class DeviceManualRow {
  final String model;

  /// The python module that drives it.
  final String module;
  final ManualEntry? entry;

  const DeviceManualRow(
      {required this.model, required this.module, required this.entry});

  DeviceManualStatus get status => entry == null
      ? DeviceManualStatus.notInCatalog
      : entry!.hasDocuments
          ? DeviceManualStatus.found
          : DeviceManualStatus.noDocuments;

  bool get missing => status != DeviceManualStatus.found;
}

/// Every [models] entry (model -> module) checked against [catalog], sorted
/// by model.
List<DeviceManualRow> deviceManualRows(
    ManualsCatalog catalog, Map<String, String> models) {
  final rows = [
    for (final e in models.entries)
      DeviceManualRow(
          model: e.key, module: e.value, entry: catalog.forModel(e.key)),
  ];
  rows.sort((a, b) => a.model.toLowerCase().compareTo(b.model.toLowerCase()));
  return rows;
}

/// One python driver and its manual.
class ModuleManualRow {
  /// The module as listed, dot notation ('vendor.extr_dsp_DMP_64').
  final String module;

  /// Where its manual would be.
  final String pdfPath;
  final bool exists;

  const ModuleManualRow(
      {required this.module, required this.pdfPath, required this.exists});

  /// The file name the manual must have.
  String get expectedName => path.basename(pdfPath);
}

/// The manual file for [module] - same rule as locateModuleManual: the last
/// dotted part, plus .pdf, in [docsFolder].
String moduleManualPath(String module, String docsFolder) =>
    path.join(docsFolder, '${module.split('.').last}.pdf');

/// Every module in [modules] checked for its manual in [docsFolder], sorted.
/// [exists] is injectable for tests.
List<ModuleManualRow> moduleManualRows(List<String> modules, String docsFolder,
    {bool Function(String path)? exists}) {
  final check = exists ?? (p) => File(p).existsSync();
  final rows = <ModuleManualRow>[];
  final seen = <String>{};
  for (final m in modules) {
    final p = moduleManualPath(m, docsFolder);
    if (!seen.add(p.toLowerCase())) continue;
    rows.add(ModuleManualRow(module: m, pdfPath: p, exists: check(p)));
  }
  rows.sort((a, b) => a.module.toLowerCase().compareTo(b.module.toLowerCase()));
  return rows;
}

/// The missing rows as plain text, one per line, for the clipboard.
String missingDeviceManualsText(List<DeviceManualRow> rows) => [
      'Model\tDriver\tStatus',
      for (final r in rows.where((r) => r.missing))
        '${r.model}\t${r.module}\t'
            '${r.status == DeviceManualStatus.notInCatalog ? 'not in catalog' : 'no documents'}',
    ].join('\n');

String missingModuleManualsText(List<ModuleManualRow> rows) => [
      'Module\tExpected manual',
      for (final r in rows.where((r) => !r.exists)) '${r.module}\t${r.expectedName}',
    ].join('\n');
