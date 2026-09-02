import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';

/// ============================================================================
///  THE DEFAULT VENDOR LIST
/// ============================================================================
///  The companies this shop asks to quote, kept in a file of its own
///  (`vendor_list.json` in the Root Folder) rather than per job, for the reason
///  the rate card and the delivery locations are: the account number, the rep
///  and the spelling of the company name are facts about the DEPARTMENT, not
///  about one building.
///
///  SHARED, LIKE THE CATALOG. Point the path at a drive everybody reads and
///  every job starts with the same directory, which is what stops one job's
///  'Extron', another's 'EXTRON' and a third's 'Extron Electronics' from being
///  three suppliers on three quote comparisons.
///
///  IT SEEDS A JOB, IT DOES NOT OWN ONE. The vendors land on the Packages tab
///  as ordinary rows: rename them, drop the ones this job is not using, add the
///  local integrator nobody else works with. Editing a vendor on a job never
///  writes back here - the job is the document, and a rep's phone number typed
///  on a Tuesday should not silently change the department's list.
/// ============================================================================

/// One company on the shared list. The same three fields a project vendor
/// carries, because that is what this becomes the moment it lands on a job.
class DefaultVendor {
  /// Stable key, used by the editor and to keep the file readable. A job's
  /// vendor gets an id of the job's own when it is seeded.
  final String id;

  /// The company, spelled the way the department spells it.
  final String name;

  /// Who a request goes to: the rep, the email a quote request is sent to,
  /// the sales desk.
  final String contact;

  /// Anything worth knowing about the company - 'account 4471', 'slow on small
  /// orders', 'quotes exclude freight'.
  final String notes;

  const DefaultVendor({
    required this.id,
    required this.name,
    this.contact = '',
    this.notes = '',
  });

  /// True when [query] should find this company.
  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return name.toLowerCase().contains(needle) ||
        contact.toLowerCase().contains(needle) ||
        notes.toLowerCase().contains(needle);
  }

  /// The line under the name in a picker: who to ask, else what is known about
  /// them. Never blank, because a menu of bare names with one gap in it reads
  /// as a broken row.
  String get detail {
    if (contact.trim().isNotEmpty) return contact.trim();
    if (notes.trim().isNotEmpty) return notes.trim();
    return 'On the shared list';
  }

  DefaultVendor copyWith({String? name, String? contact, String? notes}) =>
      DefaultVendor(
        id: id,
        name: name ?? this.name,
        contact: contact ?? this.contact,
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name.trim(),
    if (contact.trim().isNotEmpty) 'contact': contact.trim(),
    if (notes.trim().isNotEmpty) 'notes': notes.trim(),
  };

  factory DefaultVendor.fromJson(Map<String, dynamic> json) => DefaultVendor(
    id: json['id']?.toString().trim() ?? '',
    name: json['name']?.toString().trim() ?? '',
    contact: json['contact']?.toString().trim() ?? '',
    notes: json['notes']?.toString().trim() ?? '',
  );
}

/// The list of companies, and the file it came from.
///
/// Starts EMPTY rather than with built-in names. Every shop buys from a
/// different handful, and a list that arrives with three invented suppliers on
/// it is a list people delete before they use.
class VendorBook {
  final List<DefaultVendor> vendors;

  /// The file this was read from or last written to. '' when it has never
  /// been saved anywhere.
  String filePath;

  /// What to show on screen about where these came from.
  String source;

  VendorBook({
    List<DefaultVendor>? vendors,
    this.filePath = '',
    this.source = '',
  }) : vendors = vendors ?? [];

  bool get isEmpty => vendors.isEmpty;

  int get count => vendors.length;

  DefaultVendor? byId(String id) {
    for (final v in vendors) {
      if (v.id == id) return v;
    }
    return null;
  }

  /// The company called [name], ignoring case and surrounding space - which is
  /// the only spelling difference worth forgiving on a name somebody types.
  DefaultVendor? byName(String name) {
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final v in vendors) {
      if (v.name.trim().toLowerCase() == needle) return v;
    }
    return null;
  }

  /// Everything matching [query], in list order.
  List<DefaultVendor> search(String query) => [
    for (final v in vendors)
      if (v.matches(query)) v,
  ];

  /// An id nothing else on the list is using, derived from the name so a
  /// hand-edited file reads as something rather than as `vendor7`.
  String nextId(String name) {
    final stem = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    var id = stem.isEmpty ? 'vendor' : stem;
    var n = 1;
    while (byId(id) != null) {
      id = '${stem.isEmpty ? 'vendor' : stem}_${++n}';
    }
    return id;
  }

  /// Adds a company and returns it. A blank name is refused - a nameless row
  /// seeds nothing onto a job and sits in the file looking like a mistake.
  DefaultVendor? add({
    required String name,
    String contact = '',
    String notes = '',
  }) {
    if (name.trim().isEmpty) return null;
    final vendor = DefaultVendor(
      id: nextId(name),
      name: name.trim(),
      contact: contact.trim(),
      notes: notes.trim(),
    );
    vendors.add(vendor);
    return vendor;
  }

  /// Replaces the company with [vendor]'s id, or appends it when there is none.
  void upsert(DefaultVendor vendor) {
    final at = vendors.indexWhere((v) => v.id == vendor.id);
    if (at >= 0) {
      vendors[at] = vendor;
    } else {
      vendors.add(vendor);
    }
  }

  void remove(String id) => vendors.removeWhere((v) => v.id == id);

  /// Moves a company one step up or down. The order is the order a job is
  /// seeded in and the order the picker offers, and the two companies most
  /// packages go to belong at the top of it.
  void move(String id, {required bool up}) {
    final at = vendors.indexWhere((v) => v.id == id);
    if (at < 0) return;
    final to = up ? at - 1 : at + 1;
    if (to < 0 || to >= vendors.length) return;
    vendors.insert(to, vendors.removeAt(at));
  }

  Map<String, dynamic> toJson() => {
    '__readme':
        'The default vendor list for the Room Config Builder. One entry per '
        'company the shop asks to quote; a new job starts with these on its '
        'Packages tab, and any of them can be added to an older job from the '
        'same tab. Put this file on a shared drive to give everybody one '
        'directory. Editing a vendor on a job does not write back here.',
    'vendors': [for (final v in vendors) v.toJson()],
  };

  /// Reads [path]. A missing file is an EMPTY list rather than an error: a
  /// shop that has never set the directory up is the normal state on day one,
  /// and every job can still add its vendors by hand.
  ///
  /// A broken file is logged and leaves the list empty - a directory of
  /// suppliers is not worth taking the app down for.
  static Future<VendorBook> load(String path) async {
    if (path.isEmpty) return VendorBook(source: 'No file set');
    try {
      final file = File(path);
      if (!await file.exists()) {
        return VendorBook(
          filePath: path,
          source: 'No vendors saved yet (no file at $path)',
        );
      }
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map) throw const FormatException('Root must be an object.');
      final book = VendorBook(filePath: path, source: path);
      for (final entry in (doc['vendors'] as List? ?? [])) {
        if (entry is! Map) continue;
        final vendor = DefaultVendor.fromJson(Map<String, dynamic>.from(entry));
        if (vendor.name.isEmpty) continue;
        // A hand-written file can leave the id out, or repeat one. Neither is
        // worth refusing the company over: the name is what does the work.
        book.vendors.add(
          vendor.id.isEmpty || book.byId(vendor.id) != null
              ? DefaultVendor(
                  id: book.nextId(vendor.name),
                  name: vendor.name,
                  contact: vendor.contact,
                  notes: vendor.notes,
                )
              : vendor,
        );
      }
      AppLogger.logInfo(
        'Default vendors loaded from $path (${book.vendors.length} vendors).',
      );
      return book;
    } catch (e, stack) {
      AppLogger.logError('Failed to load the vendor list from $path', e, stack);
      return VendorBook(filePath: path, source: 'Failed to load $path: $e');
    }
  }

  /// Writes the list. Returns the file written, or '' on failure.
  Future<String> save({String toPath = ''}) async {
    final target = toPath.isNotEmpty ? toPath : filePath;
    if (target.isEmpty) return '';
    try {
      const encoder = JsonEncoder.withIndent('  ');
      await File(target).parent.create(recursive: true);
      await File(target).writeAsString(encoder.convert(toJson()));
      filePath = target;
      source = target;
      AppLogger.logInfo('Default vendors saved to $target.');
      return target;
    } catch (e, stack) {
      AppLogger.logError('Failed to save the vendor list to $target', e, stack);
      return '';
    }
  }
}
