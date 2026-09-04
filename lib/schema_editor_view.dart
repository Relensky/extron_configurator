import 'app_snack.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'side_pane.dart';
import 'ui_schema.dart';

/// ============================================================================
///  SCHEMA EDITOR TAB
/// ============================================================================
///  ui_schema.json, edited in the app instead of in a text editor.
///
///  The schema is what turns a config key into something a person can fill in:
///  the label on the field, the description behind the info button, whether it
///  is a switch or a dropdown and what the dropdown offers, which device
///  families exist at all, what a new room starts with. Everything about the
///  Devices and System tabs that is not the config itself.
///
///  It has always been editable — the file is read at startup and can say
///  anything — but only by hand, in JSON, against a config file open in
///  another window to see which keys were still undescribed. This tab is that
///  job with the two halves side by side:
///
///  * COVERAGE reads the DEFAULT CONFIG FILE (the template a new room is built
///    from) and lists every key in it against the schema entry that describes
///    it. "Not described yet" is the interesting filter: those are the fields
///    that show up as a raw key with a plain text box, and each one is one
///    click from having a label, a type and a description.
///
///  * The other sections are the schema's own parts — global fields, fields
///    scoped to a device family, the families themselves, the defaults a new
///    or migrated room gets, and the consistency checks.
///
///  * RAW JSON is the escape hatch: the whole document, validated before it is
///    applied, for the things a form does not cover.
///
///  WHAT IS SAVED is the document that was READ, with the edits in it — not a
///  regenerated approximation. A key this build does not understand yet, and
///  the "__comment" entries the file explains itself with, both survive a
///  round trip. Save writes it; until then the edits are in memory, where the
///  rest of the app is already following them.
/// ============================================================================

enum _SchemaSection {
  coverage('Coverage', Icons.fact_check,
      'Every key in your default config file, and whether the schema '
          'describes it yet.'),
  fields('Fields', Icons.label,
      'How a config key is drawn, wherever it turns up.'),
  deviceFields('Device fields', Icons.devices,
      'The same thing, but only for one device family or section.'),
  deviceTypes('Device families', Icons.category,
      'The families the Setup Wizard manages - a dev_ count key, the section '
          'prefix its blocks use, and a label.'),
  defaults('Defaults', Icons.playlist_add,
      'What a room is given when it is missing something.'),
  consistency('Consistency', Icons.rule,
      'Keys that have to agree, and what to say when they do not.'),
  raw('Raw JSON', Icons.data_object,
      'The whole document, for anything the forms do not cover. Checked '
          'before it is applied.');

  final String label;
  final IconData icon;
  final String blurb;
  const _SchemaSection(this.label, this.icon, this.blurb);
}

/// The "type" values a field may take — the list at the top of ui_schema.dart.
const List<String> kSchemaFieldTypes = [
  'auto',
  'text',
  'int',
  'double',
  'bool',
  'dropdown',
  'combo',
  'hidden',
  'com_port',
  'room_sources',
  'module_states',
  'source_map',
];

/// What each type actually PUTS ON THE TAB, and when to reach for it.
///
/// The picker used to offer the eleven raw values and nothing else, which asks
/// whoever is describing a key to already know what 'combo' and 'source_map'
/// draw — and the only place that is written down is a comment block at the top
/// of ui_schema.dart, which is a source file. Somebody adding a key to a schema
/// is not reading source; they are looking at a dropdown deciding whether their
/// new key wants a switch or a list, and this is the moment to answer that.
///
/// [name] is what the control is CALLED — 'On/off switch' rather than 'bool' —
/// and the raw value is still shown beside it, because the raw value is what
/// lands in ui_schema.json and somebody hand-editing that file has to be able
/// to match the two up.
///
/// [blurb] is one line, in the present tense, describing what appears on the
/// tab. Where a type needs something else filled in to work at all, the line
/// says so: a dropdown with no options is the commonest broken schema entry
/// there is.
const Map<String, ({String name, String blurb})> kSchemaFieldTypeInfo = {
  'auto': (
    name: 'Decide from the value',
    blurb: 'Looks at what is in the config: true/false becomes a switch, a '
        'number becomes a number field, anything else becomes a text box. The '
        'right answer for most keys.',
  ),
  'text': (
    name: 'Text box',
    blurb: 'A plain text field. Use it to force text on a key that holds '
        'something like "10.0.0.5" or "01" - values the automatic choice '
        'would read as a number and quietly reformat.',
  ),
  'int': (
    name: 'Whole number',
    blurb: 'A text field that stores an integer. Anything that will not parse '
        'is refused rather than written as text.',
  ),
  'double': (
    name: 'Decimal number',
    blurb: 'A text field that stores a decimal - gains, delays, levels.',
  ),
  'bool': (
    name: 'On/off switch',
    blurb: 'A switch storing true or false. Use it on a key that holds those '
        'and nothing else.',
  ),
  'dropdown': (
    name: 'Pick one from a list',
    blurb: 'A fixed list of choices. Fill in Options below - a dropdown with '
        'none is a field nobody can set.',
  ),
  'combo': (
    name: 'One choice, several keys',
    blurb: 'ONE dropdown that writes to several config keys at once. Fill in '
        'both Options and the keys it writes, in the same order - this is how '
        'a single "Which room mode?" sets four keys that must agree.',
  ),
  'hidden': (
    name: 'Never shown',
    blurb: 'The key stays in the config and is kept off the tab. Use it for '
        'keys a combo or the Setup Wizard owns, so nobody edits one half of a '
        'pair by hand.',
  ),
  'com_port': (
    name: 'Serial port number',
    blurb: 'A box for the port NUMBER alone - it prints the "COM" itself and '
        'stores COM3 when 3 is typed. Use it on a key that holds a processor '
        'COM port; a value that is not a port number is kept as typed.',
  ),
  'room_sources': (
    name: 'Pick one of this room’s sources',
    blurb: 'A dropdown whose choices are the sources THIS room has, read off '
        'its input_* keys - so it says HDMI 1 and Laptop rather than a list '
        'typed into the schema and gone stale.',
  ),
  'module_states': (
    name: 'Pick a state from the device’s module',
    blurb: 'A dropdown filled live from the device’s Python module: the '
        'states of one of its commands. Name the command below - the list is '
        'empty until you do.',
  ),
  'source_map': (
    name: 'Pairs of sources',
    blurb: 'Rows of two source dropdowns with add and remove - a display’s '
        'source_overrides. The only structured editor here; every other '
        'object key belongs on the Raw JSON tab.',
  ),
};

/// What the type is called, with the raw value in brackets when the two are
/// not obviously the same thing. Falls back to the raw value, so a type added
/// to [kSchemaFieldTypes] and not described here still reads.
String _fieldTypeName(String type) {
  final info = kSchemaFieldTypeInfo[type];
  return info == null ? type : info.name;
}

/// The line under the picker: what the CURRENT choice will draw. Answers the
/// question at the moment it is being asked, rather than making somebody open
/// the menu again to re-read an option they have already picked.
String _fieldTypeBlurb(String type) =>
    kSchemaFieldTypeInfo[type]?.blurb ??
    'No description for this type - see the comment block at the top of '
        'ui_schema.dart.';

class SchemaEditorView extends StatefulWidget {
  const SchemaEditorView({super.key});

  @override
  State<SchemaEditorView> createState() => _SchemaEditorViewState();
}

class _SchemaEditorViewState extends State<SchemaEditorView> {
  _SchemaSection _section = _SchemaSection.coverage;
  bool _dirty = false;
  String _search = '';

  /// Coverage: the config file being measured against, and which block of it.
  Map<String, dynamic> _template = {};
  String _templatePath = '';
  String _templateError = '';
  String _block = 'SYSTEM_SETUP';
  bool _undescribedOnly = false;

  /// Raw JSON: the text being edited, and what is wrong with it.
  final TextEditingController _raw = TextEditingController();
  String _rawError = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadTemplate(context.read<AppStateProvider>().effectiveTemplateFilePath);
    });
  }

  @override
  void dispose() {
    _raw.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? snackErrorFill(context) : null),
    );
  }

  /// Reads the config file Coverage measures against.
  ///
  /// Synchronously, deliberately: it is one small local JSON file, it is read
  /// once when the tab opens, and reading it on the frame that needs it means
  /// the table is never briefly empty for reasons nobody can see.
  void _loadTemplate(String filePath) {
    if (filePath.trim().isEmpty) {
      setState(() {
        _templateError = 'No default config file is set yet - pick one under '
            'App Config > Template config.json.';
        _template = {};
        _templatePath = '';
      });
      return;
    }
    try {
      final doc = jsonDecode(File(filePath).readAsStringSync());
      if (doc is! Map<String, dynamic>) {
        throw const FormatException('The config file is not an object.');
      }
      setState(() {
        _template = doc;
        _templatePath = filePath;
        _templateError = '';
        if (!doc.containsKey(_block)) {
          _block = doc.keys.isEmpty ? '' : doc.keys.first;
        }
      });
    } catch (e) {
      setState(() {
        _template = {};
        _templatePath = filePath;
        _templateError = 'Could not read $filePath - $e';
      });
    }
  }

  // --- the document ---------------------------------------------------------

  /// Applies [change] to a COPY of the schema document and hands it back to
  /// the app, which rebuilds the schema from it.
  ///
  /// A copy rather than the live map because [UiSchema.fromDoc] rebuilds from
  /// the built-ins upward: handing it the map it is about to replace, and
  /// mutating that map on the way, is the shape of bug that only shows up in
  /// the third edit.
  void _edit(void Function(Map<String, dynamic> doc) change) {
    final provider = context.read<AppStateProvider>();
    final doc = jsonDecode(jsonEncode(provider.uiSchema.rawDoc))
        as Map<String, dynamic>;
    // The parser insists on a top-level "fields" object, which a schema that
    // has never been written to a file does not have yet.
    doc.putIfAbsent('fields', () => <String, dynamic>{});
    change(doc);
    try {
      provider.applyUiSchemaDoc(doc);
      setState(() => _dirty = true);
    } on FormatException catch (e) {
      _snack('The app could not read the schema after that edit, so it was '
          'left alone: $e', error: true);
    }
  }

  Future<void> _save() async {
    final provider = context.read<AppStateProvider>();
    if (provider.uiSchema.rawDoc.isEmpty) {
      // Nothing has been read and nothing edited: writing an empty document
      // would REPLACE a schema somebody has, with nothing.
      _snack(
          'There is nothing to save yet: this is the app’s built-in schema. '
          'Point App Config at a ui_schema.json, or start one on the Raw JSON '
          'page.',
          error: true);
      return;
    }
    final saved = await provider.saveUiSchema();
    if (saved.isEmpty) {
      _snack('Could not save the schema.', error: true);
      return;
    }
    setState(() => _dirty = false);
    _snack('Schema saved to $saved');
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final schema = provider.uiSchema;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Schema Editor', style: theme.textTheme.titleLarge),
              Text(
                _dirty ? 'Edited - not saved yet' : schema.source,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _dirty ? theme.colorScheme.error : theme.disabledColor,
                ),
              ),
              ElevatedButton.icon(
                key: const ValueKey('schema_editor_save'),
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save'),
                onPressed: _save,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Reload from file'),
                onPressed: () async {
                  await provider.loadUiSchema();
                  if (!mounted) return;
                  setState(() => _dirty = false);
                  _snack('Schema re-read from ${provider.uiSchema.source}');
                },
              ),
              Text('${schema.fieldCount} field definitions',
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SidePane(
                side: PaneSide.left,
                title: 'Schema',
                storageKey: 'schema_editor_sections',
                initialWidth: 250,
                child: ListView(
                  children: [
                    for (final s in _SchemaSection.values)
                      ListTile(
                        key: ValueKey('schema_section_${s.name}'),
                        dense: true,
                        selected: s == _section,
                        leading: Icon(s.icon, size: 20),
                        title:
                            Text(s.label, style: const TextStyle(fontSize: 13)),
                        onTap: () {
                          if (s == _SchemaSection.raw) {
                            _raw.text = const JsonEncoder.withIndent('  ')
                                .convert(schema.rawDoc);
                            _rawError = '';
                          }
                          setState(() => _section = s);
                        },
                      ),
                  ],
                ),
              ),
              Expanded(child: _body(provider, schema, theme)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _body(AppStateProvider provider, UiSchema schema, ThemeData theme) =>
      switch (_section) {
        _SchemaSection.coverage => _coverage(provider, schema, theme),
        _SchemaSection.fields => _fields(schema, theme),
        _SchemaSection.deviceFields => _deviceFields(schema, theme),
        _SchemaSection.deviceTypes => _deviceTypes(schema, theme),
        _SchemaSection.defaults => _defaults(schema, theme),
        _SchemaSection.consistency => _consistency(schema, theme),
        _SchemaSection.raw => _rawEditor(provider, theme),
      };

  Widget _header(ThemeData theme, {List<Widget> actions = const []}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_section.label, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(_section.blurb, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ...actions,
          ],
        ),
      );

  Widget _searchBox() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: 'Search keys',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
        ),
      );

  bool _matchesSearch(String text) =>
      _search.isEmpty || text.toLowerCase().contains(_search);

  // --------------------------------------------------------------------------
  //  COVERAGE — the schema measured against a real config file
  // --------------------------------------------------------------------------

  Widget _coverage(
      AppStateProvider provider, UiSchema schema, ThemeData theme) {
    final blocks = _template.keys.map((k) => k.toString()).toList()..sort();
    final block = _template[_block];
    final keys = block is Map
        ? (block.keys.map((k) => k.toString()).toList()..sort())
        : <String>[];

    int described = 0;
    for (final k in keys) {
      if (schema.specFor(k, sectionKey: _block) != null) described++;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(theme, actions: [
          OutlinedButton.icon(
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Another config file'),
            onPressed: () async {
              final picked = await FilePicker.pickFiles(
                  type: FileType.custom, allowedExtensions: ['json']);
              final chosen = picked?.files.single.path;
              if (chosen != null && mounted) _loadTemplate(chosen);
            },
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            _templateError.isNotEmpty
                ? _templateError
                : 'Checked against $_templatePath',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _templateError.isEmpty
                  ? theme.disabledColor
                  : theme.colorScheme.error,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('schema_coverage_block'),
                  initialValue: blocks.contains(_block) ? _block : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Config block',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final b in blocks)
                      DropdownMenuItem(value: b, child: Text(b)),
                  ],
                  onChanged: (v) => setState(() => _block = v ?? _block),
                ),
              ),
              FilterChip(
                key: const ValueKey('schema_coverage_undescribed'),
                label: const Text('Not described yet'),
                selected: _undescribedOnly,
                onSelected: (v) => setState(() => _undescribedOnly = v),
              ),
              Text('$described of ${keys.length} keys described',
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        _searchBox(),
        const SizedBox(height: 8),
        // FILTERED FIRST, THEN BUILT LAZILY. A SYSTEM_SETUP block runs to
        // several hundred keys, and this list used to lay out a row for every
        // one of them on every rebuild — which is every character typed into
        // the search box above it, the one place the list is guaranteed to be
        // long and the typing guaranteed to be fast.
        Expanded(
          child: Builder(builder: (context) {
            final visible = [
              for (final key in keys)
                if (_matchesSearch(key))
                  if (!(_undescribedOnly &&
                      schema.specFor(key, sectionKey: _block) != null))
                    key,
            ];
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final key = visible[index];
                return _coverageRow(
                  schema,
                  key,
                  schema.specFor(key, sectionKey: _block),
                  block as Map,
                );
              },
            );
          }),
        ),
      ],
    );
  }

  Widget _coverageRow(
      UiSchema schema, String key, FieldSpec? spec, Map block) {
    final value = block[key];
    final scope = _block == 'SYSTEM_SETUP'
        ? ''
        : '${schema.deviceTypeForSection(_block)?.prefix ?? _block}*';
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        key: ValueKey('schema_coverage_$key'),
        dense: true,
        leading: Icon(
          spec == null ? Icons.help_outline : Icons.check_circle_outline,
          size: 20,
          color: spec == null ? Theme.of(context).colorScheme.error : null,
        ),
        title: Text(key),
        subtitle: Text(
          spec == null
              ? 'Nothing describes this yet, so it shows up as a plain text '
                  'box called "$key". This file has: ${_short(value)}'
              : '${spec.label ?? key} • ${spec.type}'
                  '${spec.key == key ? '' : ' (via ${spec.key})'} • '
                  'this file has: ${_short(value)}',
        ),
        trailing: TextButton(
          child: Text(spec == null ? 'Describe' : 'Edit'),
          onPressed: () => _editField(
            existingKey: spec != null && spec.key == key ? key : null,
            scope: spec != null && spec.key == key ? _scopeOf(schema, key) : scope,
            seedKey: key,
            seedValue: value,
          ),
        ),
      ),
    );
  }

  String _short(dynamic value) {
    final text = value == null ? 'null' : value.toString();
    return text.length <= 40 ? text : '${text.substring(0, 40)}…';
  }

  /// Which part of the document an existing entry for [key] lives in: '' for
  /// the global fields, else the device/section pattern it is scoped to.
  String _scopeOf(UiSchema schema, String key) {
    final provider = context.read<AppStateProvider>();
    final doc = provider.uiSchema.rawDoc;
    for (final section in const ['device_fields', 'section_fields']) {
      final scoped = doc[section];
      if (scoped is! Map) continue;
      for (final entry in scoped.entries) {
        final fields = entry.value;
        if (fields is Map && fields.containsKey(key)) {
          return entry.key.toString();
        }
      }
    }
    return '';
  }

  // --------------------------------------------------------------------------
  //  FIELDS
  // --------------------------------------------------------------------------

  Widget _fields(UiSchema schema, ThemeData theme) {
    final fields = schema.rawDoc['fields'];
    final keys = fields is Map
        ? (fields.keys.map((k) => k.toString()).toList()..sort())
        : <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(theme, actions: [
          FilledButton.icon(
            key: const ValueKey('schema_add_field'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add field'),
            onPressed: () => _editField(scope: ''),
          ),
        ]),
        _searchBox(),
        const SizedBox(height: 8),
        Expanded(
          child: keys.isEmpty
              ? Center(
                  child: Text(
                    'This document does not describe any fields of its own '
                    'yet. Coverage is the quickest way in - it lists the keys '
                    'a real room has, and which of them nobody has described.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  children: [
                    for (final key in keys)
                      if (_matchesSearch(key) && !key.startsWith('__'))
                        _fieldTile(key, (fields as Map)[key], scope: ''),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _fieldTile(String key, dynamic entry, {required String scope}) {
    final map = entry is Map
        ? entry.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final type = map['type']?.toString() ?? 'auto';
    final label = map['label']?.toString() ?? '';
    final options = map['options'];
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        key: ValueKey('schema_field_${scope}_$key'),
        dense: true,
        title: Text(key),
        subtitle: Text([
          if (label.isNotEmpty) label,
          type,
          if (options is List && options.isNotEmpty)
            '${options.length} option(s)',
          if (map['addIfMissing'] == true) 'added when missing',
          if (map['hideWhen'] != null) 'conditional',
        ].join(' • ')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit, size: 18),
              tooltip: 'Edit',
              onPressed: () => _editField(existingKey: key, scope: scope),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: 'Remove',
              onPressed: () => _edit((doc) {
                if (scope.isEmpty) {
                  (doc['fields'] as Map).remove(key);
                } else {
                  for (final section in const [
                    'device_fields',
                    'section_fields'
                  ]) {
                    final scoped = doc[section];
                    if (scoped is Map && scoped[scope] is Map) {
                      (scoped[scope] as Map).remove(key);
                    }
                  }
                }
              }),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  //  DEVICE-SCOPED FIELDS
  // --------------------------------------------------------------------------

  Widget _deviceFields(UiSchema schema, ThemeData theme) {
    final doc = schema.rawDoc;
    final groups = <String, Map>{};
    for (final section in const ['device_fields', 'section_fields']) {
      final scoped = doc[section];
      if (scoped is! Map) continue;
      scoped.forEach((pattern, fields) {
        if (pattern.toString().startsWith('__')) return;
        if (fields is Map) groups[pattern.toString()] = fields;
      });
    }
    final patterns = groups.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(theme, actions: [
          FilledButton.icon(
            key: const ValueKey('schema_add_scoped_field'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add field'),
            onPressed: () => _editField(scope: '*'),
          ),
        ]),
        _searchBox(),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: [
              for (final pattern in patterns) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                  child: Text(pattern, style: theme.textTheme.titleSmall),
                ),
                for (final key in (groups[pattern]!.keys.toList()
                  ..sort((a, b) => a.toString().compareTo(b.toString()))))
                  if (_matchesSearch(key.toString()) &&
                      !key.toString().startsWith('__'))
                    _fieldTile(key.toString(), groups[pattern]![key],
                        scope: pattern),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  //  DEVICE FAMILIES
  // --------------------------------------------------------------------------

  Widget _deviceTypes(UiSchema schema, ThemeData theme) {
    final fromFile = schema.rawDoc['device_types'] is Map;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(theme, actions: [
          FilledButton.icon(
            key: const ValueKey('schema_add_family'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add family'),
            onPressed: () => _editFamily(schema, null),
          ),
        ]),
        if (!fromFile)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'These are the families the app ships with. Change any one of '
              'them and the whole list is written into your file - a file '
              'that lists families at all replaces the built-in list, so a '
              'half-list would quietly drop the rest.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: [
              for (final t in schema.deviceTypes)
                Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    key: ValueKey('schema_family_${t.countKey}'),
                    dense: true,
                    title: Text('${t.label}  (${t.countKey})'),
                    subtitle: Text([
                      'blocks ${t.prefix}1…${t.maxCount}',
                      if (t.systemKeys.isNotEmpty)
                        'owns ${t.systemKeys.join(', ')}',
                      if (t.keepAlivePreference.isNotEmpty)
                        'keep-alive ${t.keepAlivePreference.join(' > ')}',
                    ].join(' • ')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 18),
                          tooltip: 'Edit',
                          onPressed: () => _editFamily(schema, t),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: 'Remove',
                          onPressed: () => _removeFamily(schema, t),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// The effective family list as a document map — what has to be written
  /// whenever one family changes, because defining any replaces them all.
  Map<String, dynamic> _familiesAsDoc(UiSchema schema) => {
        for (final t in schema.deviceTypes)
          t.countKey: {
            'prefix': t.prefix,
            'label': t.label,
            if (t.maxCount != 8) 'max': t.maxCount,
            if (t.keepAlivePreference.isNotEmpty)
              'keepAlivePreference': t.keepAlivePreference,
            if (t.systemKeys.isNotEmpty) 'systemKeys': t.systemKeys,
            if (t.template != null) 'template': t.template,
          },
      };

  Future<void> _editFamily(UiSchema schema, DeviceTypeSpec? existing) async {
    final countKey = TextEditingController(text: existing?.countKey ?? '');
    final prefix = TextEditingController(text: existing?.prefix ?? '');
    final label = TextEditingController(text: existing?.label ?? '');
    final max = TextEditingController(text: '${existing?.maxCount ?? 8}');
    final systemKeys = TextEditingController(
        text: (existing?.systemKeys ?? const <String>[]).join('\n'));
    final keepAlive = TextEditingController(
        text: (existing?.keepAlivePreference ?? const <String>[]).join(', '));

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New device family' : 'Edit family'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _text(countKey, 'Count key',
                    'The SYSTEM_SETUP key that says how many, like '
                        'dev_projectors.'),
                _text(prefix, 'Section prefix',
                    'The config blocks this family uses, numbered from 1 - '
                        'PROJECTORDEVICE_, for instance.'),
                _text(label, 'Label', 'What the Setup Wizard calls it.'),
                _text(max, 'Most the wizard offers', ''),
                _text(systemKeys, 'SYSTEM_SETUP keys this family owns',
                    'One pattern per line. Setting the count to 0 takes them '
                    'out - outlet names with no power controller behind them '
                    'are just something else to read past.',
                    lines: 3),
                _text(keepAlive, 'Keep-alive commands, best first',
                    'Comma separated. Tried in this order when a new device '
                        'picks one off its module.'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    if (countKey.text.trim().isEmpty || prefix.text.trim().isEmpty) {
      _snack('A family needs a count key and a section prefix.', error: true);
      return;
    }

    final families = _familiesAsDoc(schema);
    if (existing != null && existing.countKey != countKey.text.trim()) {
      families.remove(existing.countKey);
    }
    families[countKey.text.trim()] = {
      'prefix': prefix.text.trim(),
      'label': label.text.trim().isEmpty ? countKey.text.trim() : label.text.trim(),
      'max': int.tryParse(max.text.trim()) ?? 8,
      if (keepAlive.text.trim().isNotEmpty)
        'keepAlivePreference': [
          for (final k in keepAlive.text.split(','))
            if (k.trim().isNotEmpty) k.trim(),
        ],
      if (systemKeys.text.trim().isNotEmpty)
        'systemKeys': [
          for (final k in systemKeys.text.split('\n'))
            if (k.trim().isNotEmpty) k.trim(),
        ],
      if (existing?.template != null) 'template': existing!.template,
    };
    _edit((doc) => doc['device_types'] = families);
  }

  Future<void> _removeFamily(UiSchema schema, DeviceTypeSpec family) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${family.label}?'),
        content: Text(
          'The Wizard stops offering ${family.countKey}, and ${family.prefix}n '
          'blocks stop being treated as devices. Nothing is deleted from any '
          'room - the blocks are still in the config, just no longer shown as '
          'devices.\n\n'
          'Every other family is written into your file at the same time, '
          'because a file that lists families at all replaces the built-in '
          'list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final families = _familiesAsDoc(schema)..remove(family.countKey);
    if (families.isEmpty) {
      _snack('A schema with no device families would have no device tabs at '
          'all - keep at least one.', error: true);
      return;
    }
    _edit((doc) => doc['device_types'] = families);
  }

  // --------------------------------------------------------------------------
  //  DEFAULTS
  // --------------------------------------------------------------------------

  Widget _defaults(UiSchema schema, ThemeData theme) {
    final doc = schema.rawDoc;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(theme),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              _defaultsGroup(
                theme,
                title: 'SYSTEM_SETUP defaults',
                blurb: 'Injected into a loaded room that is missing them. '
                    'Defining any replaces the built-in set.',
                values: schema.systemDefaults,
                onEdit: () => _editMap(
                  title: 'SYSTEM_SETUP defaults',
                  values: schema.systemDefaults,
                  onSave: (v) => _edit((d) => d['system_defaults'] = v),
                ),
              ),
              for (final entry in schema.sectionDefaults.entries)
                _defaultsGroup(
                  theme,
                  title: 'Section: ${entry.key}',
                  blurb: 'A whole block a room is given when it has none.',
                  values: entry.value,
                  onEdit: () => _editMap(
                    title: entry.key,
                    values: entry.value,
                    onSave: (v) => _edit((d) {
                      final map = (d['section_defaults'] is Map)
                          ? Map<String, dynamic>.from(d['section_defaults'])
                          : <String, dynamic>{};
                      map[entry.key] = v;
                      d['section_defaults'] = map;
                    }),
                  ),
                ),
              _newGroupButton(
                key: 'schema_add_section_default',
                label: 'Add a section block',
                onName: (name) => _edit((d) {
                  final map = (d['section_defaults'] is Map)
                      ? Map<String, dynamic>.from(d['section_defaults'])
                      : <String, dynamic>{};
                  map[name] = <String, dynamic>{};
                  d['section_defaults'] = map;
                }),
              ),
              const Divider(height: 32),
              for (final entry in _deviceDefaultsOf(doc).entries)
                _defaultsGroup(
                  theme,
                  title: 'New ${entry.key} blocks start with',
                  blurb: 'Merged into a device block the wizard creates. '
                      'Existing values are never overwritten.',
                  values: entry.value,
                  onEdit: () => _editMap(
                    title: entry.key,
                    values: entry.value,
                    onSave: (v) => _edit((d) {
                      final map = (d['device_defaults'] is Map)
                          ? Map<String, dynamic>.from(d['device_defaults'])
                          : <String, dynamic>{};
                      map[entry.key] = v;
                      d['device_defaults'] = map;
                    }),
                  ),
                ),
              _newGroupButton(
                key: 'schema_add_device_default',
                label: 'Add a device-family default',
                onName: (name) => _edit((d) {
                  final map = (d['device_defaults'] is Map)
                      ? Map<String, dynamic>.from(d['device_defaults'])
                      : <String, dynamic>{};
                  map[name] = <String, dynamic>{};
                  d['device_defaults'] = map;
                }),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Map<String, Map<String, dynamic>> _deviceDefaultsOf(Map<String, dynamic> doc) {
    final raw = doc['device_defaults'];
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (!e.key.toString().startsWith('__') && e.value is Map)
          e.key.toString(): (e.value as Map)
              .map((k, v) => MapEntry(k.toString(), v)),
    };
  }

  Widget _defaultsGroup(
    ThemeData theme, {
    required String title,
    required String blurb,
    required Map<String, dynamic> values,
    required VoidCallback onEdit,
  }) =>
      Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleSmall),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit'),
                    onPressed: onEdit,
                  ),
                ],
              ),
              Text(blurb, style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              if (values.isEmpty)
                Text('Nothing yet.', style: theme.textTheme.bodySmall)
              else
                Text(
                  [for (final e in values.entries) '${e.key} = ${e.value}']
                      .join('\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
            ],
          ),
        ),
      );

  Widget _newGroupButton({
    required String key,
    required String label,
    required void Function(String name) onName,
  }) =>
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: ValueKey(key),
          icon: const Icon(Icons.add, size: 18),
          label: Text(label),
          onPressed: () async {
            final name = await _askForText(label, 'Section or pattern');
            if (name != null && name.trim().isNotEmpty) onName(name.trim());
          },
        ),
      );

  /// A key/value editor for one defaults block, as text — `key = value`, one
  /// per line. Values are read back as JSON when they parse as JSON (so true,
  /// 3 and "text" all keep their type) and as plain strings otherwise, which
  /// is what a config file is mostly made of.
  Future<void> _editMap({
    required String title,
    required Map<String, dynamic> values,
    required void Function(Map<String, dynamic> values) onSave,
  }) async {
    final text = TextEditingController(
      text: [for (final e in values.entries) '${e.key} = ${jsonEncode(e.value)}']
          .join('\n'),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: text,
            maxLines: 16,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              helperText: 'One "key = value" per line. Values are written as '
                  'JSON, so "text" keeps its quotes and 3 and true do not.',
              helperMaxLines: 2,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;

    final out = <String, dynamic>{};
    for (final line in text.text.split('\n')) {
      final at = line.indexOf('=');
      if (at <= 0) continue;
      final key = line.substring(0, at).trim();
      final raw = line.substring(at + 1).trim();
      if (key.isEmpty) continue;
      try {
        out[key] = jsonDecode(raw);
      } catch (_) {
        out[key] = raw;
      }
    }
    onSave(out);
  }

  // --------------------------------------------------------------------------
  //  CONSISTENCY
  // --------------------------------------------------------------------------

  Widget _consistency(UiSchema schema, ThemeData theme) {
    final rules = schema.consistencyRules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(theme, actions: [
          FilledButton.icon(
            key: const ValueKey('schema_add_consistency'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add rule'),
            onPressed: () => _editConsistency(schema, -1),
          ),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: [
              for (int i = 0; i < rules.length; i++)
                Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    title: Text('${rules[i].whenCondition} → '
                        '${rules[i].expectCondition}'),
                    subtitle: Text('${rules[i].sectionPattern} • flags '
                        '${rules[i].flag.join(', ')}\n${rules[i].message}'),
                    isThreeLine: true,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 18),
                          onPressed: () => _editConsistency(schema, i),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => _edit((doc) {
                            final list = _consistencyAsDoc(schema)..removeAt(i);
                            doc['consistency'] = list;
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Map<String, dynamic>> _consistencyAsDoc(UiSchema schema) => [
        for (final r in schema.consistencyRules)
          {
            'section': r.sectionPattern,
            'when': r.whenCondition,
            'expect': r.expectCondition,
            'message': r.message,
            'flag': r.flag,
          },
      ];

  Future<void> _editConsistency(UiSchema schema, int index) async {
    final rules = schema.consistencyRules;
    final existing = index >= 0 && index < rules.length ? rules[index] : null;
    final section =
        TextEditingController(text: existing?.sectionPattern ?? 'SYSTEM_SETUP');
    final when = TextEditingController(text: existing?.whenCondition ?? '');
    final expect = TextEditingController(text: existing?.expectCondition ?? '');
    final message = TextEditingController(text: existing?.message ?? '');
    final flag =
        TextEditingController(text: (existing?.flag ?? const []).join(', '));

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New rule' : 'Edit rule'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'When the first condition is true, the second one has to be '
                  'true as well. Breaking a rule never blocks an edit - it '
                  'paints the red mismatch outline on the fields you name '
                  'below, with your message underneath them.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                _text(section, 'Section',
                    'Which block to check. A * stands for anything.'),
                _text(when, 'When',
                    'key=value, key!=value, or key~text for "contains".'),
                _text(expect, 'Expect', 'Written the same way.'),
                _text(message, 'Message',
                    'What to say when they disagree. Put {some_key} in it and '
                        'that key’s current value is filled in.'),
                _text(flag, 'Fields to flag',
                    'Comma separated - the fields that get the red outline.'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    if (when.text.trim().isEmpty || expect.text.trim().isEmpty) {
      _snack('A rule needs both a condition and what it expects.',
          error: true);
      return;
    }
    final entry = {
      'section': section.text.trim().isEmpty
          ? 'SYSTEM_SETUP'
          : section.text.trim(),
      'when': when.text.trim(),
      'expect': expect.text.trim(),
      'message': message.text.trim(),
      'flag': [
        for (final f in flag.text.split(','))
          if (f.trim().isNotEmpty) f.trim(),
      ],
    };
    _edit((doc) {
      final list = _consistencyAsDoc(schema);
      if (existing == null) {
        list.add(entry);
      } else {
        list[index] = entry;
      }
      doc['consistency'] = list;
    });
  }

  // --------------------------------------------------------------------------
  //  RAW JSON
  // --------------------------------------------------------------------------

  Widget _rawEditor(AppStateProvider provider, ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(theme, actions: [
            FilledButton.icon(
              key: const ValueKey('schema_apply_raw'),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Validate & apply'),
              onPressed: () {
                try {
                  final doc = jsonDecode(_raw.text);
                  if (doc is! Map<String, dynamic>) {
                    throw const FormatException(
                        'The document must be an object.');
                  }
                  provider.applyUiSchemaDoc(doc);
                  setState(() {
                    _rawError = '';
                    _dirty = true;
                  });
                  _snack('Applied - the rest of the app is using it now.');
                } on FormatException catch (e) {
                  setState(() => _rawError = '$e');
                }
              },
            ),
          ]),
          if (_rawError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_rawError,
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                key: const ValueKey('schema_raw_json'),
                controller: _raw,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ),
        ],
      );

  // --------------------------------------------------------------------------
  //  THE FIELD DIALOG
  // --------------------------------------------------------------------------

  /// Adds or edits one field definition.
  ///
  /// [scope] is '' for the global fields, '*' to be asked for a pattern, or
  /// the pattern itself. [seedKey] and [seedValue] come from Coverage: the key
  /// somebody pressed "Describe" on, and what the config file holds for it —
  /// which is enough to guess the type, and guessing it right is most of the
  /// work of describing a key.
  Future<void> _editField({
    String? existingKey,
    required String scope,
    String? seedKey,
    dynamic seedValue,
  }) async {
    final provider = context.read<AppStateProvider>();
    final doc = provider.uiSchema.rawDoc;

    String pattern = scope;
    if (scope == '*') {
      final asked = await _askForText(
          'Which section?', 'PROJECTORDEVICE_* or METRICS_CONFIG');
      if (asked == null || asked.trim().isEmpty || !mounted) return;
      pattern = asked.trim();
    }

    Map<String, dynamic> entry = {};
    if (existingKey != null) {
      final source = pattern.isEmpty
          ? doc['fields']
          : (doc['device_fields'] is Map &&
                  (doc['device_fields'] as Map)[pattern] is Map)
              ? (doc['device_fields'] as Map)[pattern]
              : (doc['section_fields'] is Map)
                  ? (doc['section_fields'] as Map)[pattern]
                  : null;
      if (source is Map && source[existingKey] is Map) {
        entry = (source[existingKey] as Map)
            .map((k, v) => MapEntry(k.toString(), v));
      }
    }

    final key = TextEditingController(text: existingKey ?? seedKey ?? '');
    final label = TextEditingController(text: entry['label']?.toString() ?? '');
    final description =
        TextEditingController(text: entry['description']?.toString() ?? '');
    final helper =
        TextEditingController(text: entry['helperText']?.toString() ?? '');
    final moduleCommand =
        TextEditingController(text: entry['moduleCommand']?.toString() ?? '');
    final options =
        TextEditingController(text: _optionsToText(entry['options']));
    final writes = TextEditingController(
        text: (entry['writes'] is List)
            ? (entry['writes'] as List).join(', ')
            : '');
    final hideWhen = TextEditingController(
        text: (entry['hideWhen'] is List)
            ? (entry['hideWhen'] as List).join('\n')
            : (entry['hideWhen']?.toString() ?? ''));
    final labelWhen = TextEditingController(
        text: (entry['labelWhen'] is Map)
            ? [
                for (final e in (entry['labelWhen'] as Map).entries)
                  '${e.key} = ${e.value}'
              ].join('\n')
            : '');
    String type = entry['type']?.toString() ?? _guessType(seedValue);
    bool addIfMissing = entry['addIfMissing'] == true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(existingKey == null
              ? (pattern.isEmpty ? 'New field' : 'New field in $pattern')
              : 'Edit $existingKey'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _text(key, 'Config key',
                      'One key, or a whole family with a star in it - '
                          'power1_outlet_*.'),
                  const SizedBox(height: 8),
                  // WHAT THIS FIELD BECOMES ON THE TAB. Every option names
                  // the control it draws and explains itself underneath,
                  // because the choice is being made by somebody describing a
                  // config key — who has no reason to know what 'combo' or
                  // 'source_map' render as, and whose only other source for
                  // that is a comment block inside ui_schema.dart.
                  //
                  // The raw value rides along beside the name: it is what
                  // lands in the file, and a schema hand-edited afterwards has
                  // to be matchable back to what was picked here.
                  DropdownButtonFormField<String>(
                    key: const ValueKey('schema_field_type'),
                    initialValue:
                        kSchemaFieldTypes.contains(type) ? type : 'auto',
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Rendered as',
                      helperText: _fieldTypeBlurb(type),
                      helperMaxLines: 4,
                      border: const OutlineInputBorder(),
                    ),
                    // Closed, it is one line: the menu's two-line rows would
                    // otherwise set the height of the field itself.
                    selectedItemBuilder: (ctx) => [
                      for (final t in kSchemaFieldTypes)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_fieldTypeName(t)),
                        ),
                    ],
                    items: [
                      for (final t in kSchemaFieldTypes)
                        DropdownMenuItem(
                          value: t,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_fieldTypeName(t)),
                              Text(
                                t,
                                style: Theme.of(ctx)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(ctx)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      fontFamily: 'monospace',
                                    ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    onChanged: (v) => setLocal(() => type = v ?? 'auto'),
                  ),
                  _text(label, 'Label', 'What the field is called on the tab.'),
                  _text(description, 'Description',
                      'What people read behind the info button. Leave it '
                          'blank to fall back to the app’s own description of '
                          'the key.',
                      lines: 3),
                  _text(helper, 'Helper line',
                      'A short hint under the field.'),
                  if (type == 'dropdown' || type == 'combo')
                    _text(options, 'Options',
                        type == 'combo'
                            ? 'One per line: the label, then the values it '
                                'writes to each key below, in order - '
                                'separated by | characters.'
                            : 'One per line. Just the value, or value | label '
                                'when the stored value is not what people '
                                'should read.',
                        lines: 6),
                  if (type == 'combo')
                    _text(writes, 'Keys this one field writes',
                        'Comma separated, in the same order as the values '
                            'above.'),
                  if (type == 'module_states')
                    _text(moduleCommand, 'Command in the module',
                        'The command in the device’s Python module whose '
                            'states fill this dropdown.'),
                  _text(hideWhen, 'Hide when',
                      'One condition per line, like com_type=Network. If any '
                          'of them is true the field is hidden - and not '
                          'added to new devices either.',
                      lines: 3),
                  _text(labelWhen, 'Label when',
                      'One "condition = label" per line, for a field that '
                          'means something different in some rooms. The first '
                          'match wins.',
                      lines: 3),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show it even when the block does not '
                        'have this key yet'),
                    subtitle: const Text(
                        'The first edit adds it. This is how a new setting '
                        'reaches rooms that were built before it existed.'),
                    value: addIfMissing,
                    onChanged: (v) => setLocal(() => addIfMissing = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    if (key.text.trim().isEmpty) {
      _snack('Which key is this describing? It needs one to attach to.',
          error: true);
      return;
    }

    final built = <String, dynamic>{
      // Everything the parser understands, and nothing it does not: a blank
      // stays out of the file rather than going in as an empty string that
      // then overrides the config dictionary with nothing.
      if (type != 'auto') 'type': type,
      if (label.text.trim().isNotEmpty) 'label': label.text.trim(),
      if (description.text.trim().isNotEmpty)
        'description': description.text.trim(),
      if (helper.text.trim().isNotEmpty) 'helperText': helper.text.trim(),
      if (moduleCommand.text.trim().isNotEmpty && type == 'module_states')
        'moduleCommand': moduleCommand.text.trim(),
      if (addIfMissing) 'addIfMissing': true,
      if ((type == 'dropdown' || type == 'combo') &&
          options.text.trim().isNotEmpty)
        'options': _textToOptions(options.text, combo: type == 'combo'),
      if (type == 'combo' && writes.text.trim().isNotEmpty)
        'writes': [
          for (final w in writes.text.split(','))
            if (w.trim().isNotEmpty) w.trim(),
        ],
      if (hideWhen.text.trim().isNotEmpty)
        'hideWhen': [
          for (final h in hideWhen.text.split('\n'))
            if (h.trim().isNotEmpty) h.trim(),
        ],
      if (labelWhen.text.trim().isNotEmpty)
        'labelWhen': {
          for (final line in labelWhen.text.split('\n'))
            if (line.contains('=') && line.trim().isNotEmpty)
              line.substring(0, line.indexOf('=')).trim():
                  line.substring(line.indexOf('=') + 1).trim(),
        },
      // Anything this build does not know about, kept.
      for (final e in entry.entries)
        if (!_knownFieldKeys.contains(e.key)) e.key: e.value,
    };

    _edit((d) {
      Map<String, dynamic> target;
      if (pattern.isEmpty) {
        target = Map<String, dynamic>.from(d['fields'] as Map);
        if (existingKey != null && existingKey != key.text.trim()) {
          target.remove(existingKey);
        }
        target[key.text.trim()] = built;
        d['fields'] = target;
        return;
      }
      final section =
          (d['section_fields'] is Map && (d['section_fields'] as Map)[pattern] != null)
              ? 'section_fields'
              : 'device_fields';
      final scoped = (d[section] is Map)
          ? Map<String, dynamic>.from(d[section] as Map)
          : <String, dynamic>{};
      final fields = (scoped[pattern] is Map)
          ? Map<String, dynamic>.from(scoped[pattern] as Map)
          : <String, dynamic>{};
      if (existingKey != null && existingKey != key.text.trim()) {
        fields.remove(existingKey);
      }
      fields[key.text.trim()] = built;
      scoped[pattern] = fields;
      d[section] = scoped;
    });
  }

  /// The keys the dialog above builds. Anything else in an entry is something
  /// a later build understands and this one does not, and it is copied through
  /// rather than dropped.
  static const Set<String> _knownFieldKeys = {
    'type',
    'label',
    'description',
    'helperText',
    'moduleCommand',
    'module_command',
    'addIfMissing',
    'add_if_missing',
    'options',
    'writes',
    'hideWhen',
    'labelWhen',
  };

  /// What a value in a real config file suggests the field is.
  String _guessType(dynamic value) {
    if (value is bool) return 'bool';
    if (value is int) return 'int';
    if (value is double) return 'double';
    return 'auto';
  }

  String _optionsToText(dynamic options) {
    if (options is! List) return '';
    return [
      for (final o in options)
        if (o is Map)
          [
            o['value']?.toString() ?? '',
            o['label']?.toString() ?? '',
            if (o['values'] is List) (o['values'] as List).join(', '),
          ].join(' | ')
        else
          o.toString(),
    ].join('\n');
  }

  List<dynamic> _textToOptions(String text, {required bool combo}) {
    final out = <dynamic>[];
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('|').map((p) => p.trim()).toList();
      final value = parts.isNotEmpty ? parts[0] : '';
      final label = parts.length > 1 ? parts[1] : '';
      final values = parts.length > 2
          ? [
              for (final v in parts[2].split(','))
                if (v.trim().isNotEmpty) v.trim(),
            ]
          : const <String>[];
      if (label.isEmpty && values.isEmpty && !combo) {
        out.add(value);
        continue;
      }
      out.add({
        'value': value,
        if (label.isNotEmpty) 'label': label,
        if (values.isNotEmpty) 'values': values,
      });
    }
    return out;
  }

  // --- small shared bits ----------------------------------------------------

  Widget _text(
    TextEditingController controller,
    String label,
    String helper, {
    int lines = 1,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: controller,
          maxLines: lines,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper.isEmpty ? null : helper,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  Future<String?> _askForText(String title, String hint) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
