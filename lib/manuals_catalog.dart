// ============================================================================
// [MANUALS]: device manuals for a room, from the Manuals repo's catalog.
//
// The catalog (catalog/manuals.json in the Manuals repo) lists every hardware
// model GVE reports, the spellings GVE uses for it, and the documents for it -
// PDFs kept beside the catalog under files/, or web links. This reads it and
// answers "which manuals go with this device / this room?".
//
// It knows nothing about the dashboard: give it a GVE model label (what
// GveDevice.modelLabel returns) and it gives back the entry. The match rules
// are the same as tools/manuals.py in the Manuals repo - keep the two in step:
//   norm(s) = lower-case, every run of non [a-z0-9] -> one space, trimmed
//   key(s)  = norm(s) with one leading manufacturer prefix removed
// so 'TR311', 'AVer TR311' and 'AVER - TR311' all land on the same entry.
//
// [root] is the folder holding catalog/ and files/: a clone of the Manuals
// repo, or a copy of it in the shared dashboard folder.
// ============================================================================

import 'dart:convert';
import 'dart:io';

class ManualDocument {
  final String title;

  /// user-guide, setup-guide, install-guide, quick-start, programming,
  /// spec-sheet, firmware-notes or web.
  final String kind;

  /// Path relative to the catalog root, for a document kept in the repo.
  final String? file;

  /// A web address, for one that is not.
  final String? url;

  const ManualDocument(
      {required this.title, required this.kind, this.file, this.url});

  factory ManualDocument.fromJson(Map<String, dynamic> json) => ManualDocument(
        title: (json['title'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'user-guide',
        file: json['file'] as String?,
        url: json['url'] as String?,
      );

  /// What to hand url_launcher's launchUrl: the file under [root], else the
  /// web address. Null when the document has neither.
  Uri? uri(String root) {
    if (file != null && file!.isNotEmpty) {
      return Uri.file('$root${Platform.pathSeparator}'
          '${file!.replaceAll('/', Platform.pathSeparator)}');
    }
    if (url != null && url!.isNotEmpty) return Uri.tryParse(url!);
    return null;
  }
}

class ManualEntry {
  final String id;
  final String manufacturer;
  final String model;
  final String deviceType;
  final List<String> aliases;

  /// Where this model's files go, relative to the catalog root.
  final String folder;
  final List<ManualDocument> documents;
  final String notes;

  const ManualEntry({
    required this.id,
    required this.manufacturer,
    required this.model,
    required this.deviceType,
    required this.aliases,
    required this.folder,
    required this.documents,
    required this.notes,
  });

  factory ManualEntry.fromJson(String id, Map<String, dynamic> json) =>
      ManualEntry(
        id: id,
        manufacturer: (json['manufacturer'] as String?) ?? 'Unknown',
        model: (json['model'] as String?) ?? id,
        deviceType: (json['deviceType'] as String?) ?? '',
        aliases: [
          for (final a in (json['aliases'] as List?) ?? const []) a.toString()
        ],
        folder: (json['folder'] as String?) ?? '',
        documents: [
          for (final d in (json['documents'] as List?) ?? const [])
            ManualDocument.fromJson(Map<String, dynamic>.from(d as Map))
        ],
        notes: (json['notes'] as String?) ?? '',
      );

  /// 'Extron TLP Pro 725T'; just the model when the maker is not known.
  String get displayName =>
      manufacturer == 'Unknown' ? model : '$manufacturer $model';

  bool get hasDocuments => documents.isNotEmpty;
}

/// One device of a room and what the catalog has for it. [entry] is null when
/// the catalog has never seen the model - a sync of the Manuals repo adds it.
class DeviceManuals {
  final String deviceName;
  final String deviceType;
  final String modelLabel;
  final ManualEntry? entry;

  const DeviceManuals({
    required this.deviceName,
    required this.deviceType,
    required this.modelLabel,
    required this.entry,
  });

  List<ManualDocument> get documents => entry?.documents ?? const [];
}

class ManualsCatalog {
  /// The folder holding catalog/manuals.json and files/.
  final String root;
  final Map<String, ManualEntry> models;
  final List<String> _prefixes;
  final Map<String, String> _index;

  ManualsCatalog._(this.root, this.models, this._prefixes, this._index);

  static String catalogPath(String root) =>
      '$root${Platform.pathSeparator}catalog${Platform.pathSeparator}manuals.json';

  /// Reads [root]/catalog/manuals.json. Null when it is missing or unreadable,
  /// so a PC without the Manuals folder just shows no manuals.
  static Future<ManualsCatalog?> load(String root) async {
    try {
      final file = File(catalogPath(root));
      if (!await file.exists()) return null;
      return fromJson(root, jsonDecode(await file.readAsString()) as Map);
    } catch (_) {
      return null;
    }
  }

  static ManualsCatalog fromJson(String root, Map json) {
    final prefixes = <String>{
      for (final m in ((json['manufacturers'] as Map?) ?? const {}).values)
        for (final p in ((m as Map)['prefixes'] as List?) ?? const [])
          norm(p.toString())
    }.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    final models = <String, ManualEntry>{
      for (final e in ((json['models'] as Map?) ?? const {}).entries)
        e.key.toString(): ManualEntry.fromJson(
            e.key.toString(), Map<String, dynamic>.from(e.value as Map))
    };

    final index = <String, String>{};
    for (final entry in models.values) {
      for (final label in [entry.model, ...entry.aliases]) {
        index.putIfAbsent(keyOf(label, prefixes), () => entry.id);
      }
    }
    return ManualsCatalog._(root, models, prefixes, index);
  }

  static String norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static String keyOf(String label, List<String> prefixes) {
    final n = norm(label);
    for (final p in prefixes) {
      if (n.length > p.length + 1 && n.startsWith('$p ')) {
        return n.substring(p.length + 1);
      }
    }
    return n;
  }

  /// The entry for a GVE model label, or null. 'Unknown' never matches.
  ManualEntry? forModel(String? modelLabel) {
    final label = modelLabel?.trim() ?? '';
    if (label.isEmpty || label.toLowerCase() == 'unknown') return null;
    final id = _index[keyOf(label, _prefixes)];
    return id == null ? null : models[id];
  }

  /// Every device of a room with its manuals, in the order given. Pass the
  /// room's GVE devices as (name, type, modelLabel) records:
  ///
  ///   catalog.forRoom([
  ///     for (final d in room.devices) (d.deviceName, d.deviceType, d.modelLabel)
  ///   ]);
  List<DeviceManuals> forRoom(
          Iterable<(String name, String type, String modelLabel)> devices) =>
      [
        for (final (name, type, label) in devices)
          DeviceManuals(
            deviceName: name,
            deviceType: type,
            modelLabel: label,
            entry: forModel(label),
          )
      ];

  /// The folder a model's files belong in, for an "open folder" button.
  String folderFor(ManualEntry entry) =>
      '$root${Platform.pathSeparator}'
      '${entry.folder.replaceAll('/', Platform.pathSeparator)}';
}
