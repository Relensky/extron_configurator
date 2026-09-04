import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_logger.dart';
import 'app_state.dart';
import 'config_dictionary.dart';
import 'device_info_source.dart';
import 'search_match.dart';

/// ============================================================================
///  THE DRIVER'S OWN ANSWER, EDITED IN THE APP
/// ============================================================================
///  Everything this app knows about a python driver beyond its command list is
///  in the DEVICE_INFO dict at the top of the file: which models it covers,
///  which tab they belong on, how the box is reached, and what a device block
///  is filled in with when somebody picks one of those models.
///
///  A DRIVER WITHOUT ONE IS SILENT, NOT BROKEN. It parses, it loads, and its
///  models simply never appear - so the room that needs it is specified with
///  the model typed in by hand, no module, and nothing to check the connection
///  settings against. There was no way to see that from inside the app and no
///  way to fix it except opening the .py in an editor and copying a block from
///  a neighbour.
///
///  So: pick any module the app has read, see what it says about itself, and
///  write the block back into the file.
///
///  ---------------------------------------------------------------------------
///  SCAN FIRST, THEN CORRECT
///  ---------------------------------------------------------------------------
///  **Read the file** fills the form from what the driver actually declares -
///  its self.Models, the wrapper classes at the bottom and the baud rate and
///  protocol they default to - plus the house conventions every other driver
///  of that family already uses. See [scanModuleSource], which is also where
///  the one thing a driver CANNOT say about itself is spelled out: the TCP
///  port is passed in to it, never declared by it, so the scan leaves it blank
///  and says so rather than inventing a number.
///
///  NOTHING IS WRITTEN UNTIL SAVE, and Save shows the exact python first. The
///  file is somebody's driver; a tool that rewrote it on a button press is a
///  tool nobody points at their driver folder twice.
///
///  AFTER A SAVE THE FOLDER IS RE-READ, so the Model dropdown, the keep-alive
///  list and the defaults review are looking at the file as it is now. A save
///  that left the app believing the old copy is the same silence this screen
///  exists to end.
/// ============================================================================

/// Opens the editor, on [module] when one is named (the dotted config
/// spelling or the bare stem - either resolves).
Future<void> showDeviceInfoEditor(BuildContext context, {String? module}) =>
    showDialog<void>(
      context: context,
      builder: (_) => DeviceInfoEditorDialog(module: module),
    );

class DeviceInfoEditorDialog extends StatefulWidget {
  final String? module;

  const DeviceInfoEditorDialog({super.key, this.module});

  @override
  State<DeviceInfoEditorDialog> createState() => _DeviceInfoEditorDialogState();
}

/// One editable key and its value. The value is held as TEXT whatever the key
/// is - see [pythonScalarOf], which decides on the way out whether `22023` is
/// a number, a string or nonsense.
class _Pair {
  final TextEditingController key;
  final TextEditingController value;

  _Pair(String k, dynamic v)
      : key = TextEditingController(text: k),
        value = TextEditingController(text: editableValueOf(v));

  void dispose() {
    key.dispose();
    value.dispose();
  }
}

class _DeviceInfoEditorDialogState extends State<DeviceInfoEditorDialog> {
  /// The module stem being edited, '' before one is picked.
  String _module = '';

  final _searchCtl = TextEditingController();
  final _modelsCtl = TextEditingController();
  final _omitCtl = TextEditingController();

  List<String> _deviceTypes = [];
  List<_Pair> _connection = [];
  List<_Pair> _defaults = [];
  final Map<String, List<_Pair>> _comTypes = {};

  /// Top-level keys the file carried that this form has no box for. Carried
  /// through untouched - see [DeviceInfoDraft.extras].
  Map<String, dynamic> _extras = {};

  /// What the last scan found, and what it could not.
  List<String> _notes = [];

  /// The commands this driver can be polled on, for the keep-alive field.
  List<String> _commands = [];

  bool _loading = false;
  bool _dirty = false;

  /// Which modules already carry a block, so the list can say which do not.
  /// That is the question this screen is usually opened to answer.
  final Map<String, bool> _hasBlock = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<AppStateProvider>();
      _surveyFolder(provider);
      final wanted = widget.module?.trim() ?? '';
      if (wanted.isNotEmpty) _open(provider, AppStateProvider.moduleStem(wanted));
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _modelsCtl.dispose();
    _omitCtl.dispose();
    _disposeRows();
    super.dispose();
  }

  void _disposeRows() {
    for (final row in _connection) {
      row.dispose();
    }
    for (final row in _defaults) {
      row.dispose();
    }
    for (final rows in _comTypes.values) {
      for (final row in rows) {
        row.dispose();
      }
    }
  }

  // --- the folder -----------------------------------------------------------

  /// Which of the modules the app has read already carry a block.
  ///
  /// ASKED OF THE FILES, not of the registry. The registry cannot answer it:
  /// a driver's models reach it from its self.Models dict whether or not it
  /// has a DEVICE_INFO at all, which is exactly the driver this screen exists
  /// for - it would have marked the silent ones as done. Seventy small files
  /// read once when the dialog opens is a fair price for an honest list.
  Future<void> _surveyFolder(AppStateProvider provider) async {
    for (final module in provider.availableModules) {
      final stem = AppStateProvider.moduleStem(module);
      try {
        final file = File(provider.modulePyPath(stem));
        final content = await file.exists() ? await file.readAsString() : '';
        _hasBlock[stem] =
            RegExp(r'^DEVICE_INFO\s*=', multiLine: true).hasMatch(content);
      } catch (_) {
        // Unreadable is not "missing": saying a file has no block when
        // nobody could open it sends somebody to rewrite a block that is
        // already there.
        _hasBlock[stem] = true;
      }
    }
    if (mounted) setState(() {});
  }

  // --- opening one ----------------------------------------------------------

  Future<void> _open(AppStateProvider provider, String stem) async {
    if (_dirty && !await _confirmDiscard()) return;
    setState(() {
      _module = stem;
      _loading = true;
      _notes = [];
    });

    final path = provider.modulePyPath(stem);
    String content = '';
    try {
      final file = File(path);
      if (await file.exists()) content = await file.readAsString();
    } catch (e, stack) {
      AppLogger.logError('Could not read the module $path', e, stack);
    }

    final info = content.isEmpty
        ? null
        : AppStateProvider.parseDeviceInfo(path, content);
    final draft = info == null
        ? DeviceInfoDraft()
        : DeviceInfoDraft.fromInfo(info);

    _commands = updateCommandsIn(content);
    _fill(draft);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _dirty = false;
      _notes = info == null
          ? [
              'This driver has no DEVICE_INFO block, so nothing it drives '
                  'reaches the Model dropdown. Press "Read the file" to '
                  'propose one from what it does say about itself.'
            ]
          : [];
    });
  }

  /// Puts [draft] into the form, replacing whatever was in it.
  void _fill(DeviceInfoDraft draft) {
    _disposeRows();
    _deviceTypes = [...draft.deviceTypes];
    _modelsCtl.text = draft.models.join('\n');
    _omitCtl.text = draft.omit.join(', ');
    _connection = [
      for (final e in draft.connection.entries) _Pair(e.key, e.value),
    ];
    _defaults = [
      for (final e in draft.defaults.entries) _Pair(e.key, e.value),
    ];
    _comTypes.clear();
    for (final entry in draft.comTypes.entries) {
      _comTypes[entry.key] = [
        for (final e in entry.value.entries) _Pair(e.key, e.value),
      ];
    }
    _extras = {...draft.extras};
  }

  /// The form, as a block.
  DeviceInfoDraft _draft() {
    Map<String, dynamic> mapOf(List<_Pair> rows) => {
          for (final row in rows)
            if (row.key.text.trim().isNotEmpty)
              row.key.text.trim(): pythonScalarOf(row.value.text),
        };

    return DeviceInfoDraft(
      deviceTypes: [..._deviceTypes],
      models: [
        for (final line in _modelsCtl.text.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ],
      connection: mapOf(_connection),
      defaults: mapOf(_defaults),
      comTypes: {
        for (final e in _comTypes.entries)
          if (mapOf(e.value).isNotEmpty) e.key: mapOf(e.value),
      },
      omit: [
        for (final part in _omitCtl.text.split(','))
          if (part.trim().isNotEmpty) part.trim(),
      ],
      extras: _extras,
    );
  }

  // --- the two actions ------------------------------------------------------

  /// Fills the blanks from what the driver declares. What is already typed is
  /// LEFT ALONE: this is pressed on a half-finished block as often as on an
  /// empty one, and a scan that overwrote a port somebody had just looked up
  /// would be a scan nobody dares press.
  Future<void> _scan(AppStateProvider provider) async {
    final path = provider.modulePyPath(_module);
    String content;
    try {
      content = await File(path).readAsString();
    } catch (e, stack) {
      AppLogger.logError('Could not read the module $path', e, stack);
      _snack('Could not read $path.', error: true);
      return;
    }

    final scan = scanModuleSource(content,
        fileName: _module.split('.').last);
    final current = _draft();
    final merged = scan.draft;

    // What is already there wins, key by key.
    if (current.deviceTypes.isNotEmpty) merged.deviceTypes = current.deviceTypes;
    if (current.models.isNotEmpty) merged.models = current.models;
    if (current.omit.isNotEmpty) merged.omit = current.omit;
    merged.connection.addAll(current.connection);
    merged.defaults.addAll(current.defaults);
    for (final entry in current.comTypes.entries) {
      merged.comTypes.putIfAbsent(entry.key, () => {}).addAll(entry.value);
    }
    merged.extras.addAll(current.extras);

    _commands = updateCommandsIn(content);
    setState(() {
      _fill(merged);
      _notes = scan.notes;
      _dirty = true;
    });
  }

  /// Shows the python, then writes it.
  Future<void> _save(AppStateProvider provider) async {
    final draft = _draft();
    if (draft.models.isEmpty && draft.deviceTypes.isEmpty) {
      _snack('A block with no models and no device family says nothing. '
          'Fill one of them in first.', error: true);
      return;
    }

    final block = formatDeviceInfo(draft);
    final path = provider.modulePyPath(_module);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('device_info_preview'),
        title: const Text('Write this into the driver?'),
        content: SizedBox(
          width: 720,
          height: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(path, style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      block,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Only the DEVICE_INFO block is touched. Everything else in '
                'the file is left exactly as it is.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Back'),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: block));
              Navigator.of(ctx).pop(false);
            },
            child: const Text('Copy instead'),
          ),
          ElevatedButton(
            key: const ValueKey('device_info_write'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Write it'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final file = File(path);
      final content = await file.readAsString();
      await file.writeAsString(applyDeviceInfoBlock(content, block));
    } catch (e, stack) {
      AppLogger.logError('Could not write DEVICE_INFO into $path', e, stack);
      _snack('Could not write $path - $e', error: true);
      return;
    }

    // The app parses every driver once and keeps the answer, so a file edited
    // under it is a file it still believes the old version of.
    final found = await provider.reloadModules();
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _hasBlock[_module] = true;
    });
    await _surveyFolder(provider);
    _snack('Written, and $found module${found == 1 ? '' : 's'} re-read. '
        '${draft.models.length} model${draft.models.length == 1 ? '' : 's'} '
        'now come from this driver.');
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave without writing?'),
        content: const Text(
            'This block has been edited and not written to the file.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  // --- the form -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);

    return AlertDialog(
      key: const ValueKey('device_info_editor'),
      title: Row(
        children: [
          const Expanded(child: Text('Edit module default settings')),
          if (_dirty)
            Chip(
              label: const Text('Not written'),
              backgroundColor: theme.colorScheme.secondaryContainer,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 1080,
        height: 640,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 300, child: _moduleList(provider, theme)),
            const VerticalDivider(width: 24),
            Expanded(
              child: _module.isEmpty
                  ? Center(
                      child: Text(
                        'Pick a driver on the left.\nThe ones marked "no '
                        'block" drive nothing the Model dropdown offers.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _editor(provider, theme),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final navigator = Navigator.of(context);
            if (_dirty && !await _confirmDiscard()) return;
            navigator.pop();
          },
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _moduleList(AppStateProvider provider, ThemeData theme) {
    final query = _searchCtl.text.trim();
    final modules = [
      for (final module in provider.availableModules)
        AppStateProvider.moduleStem(module),
    ];
    final shown =
        query.isEmpty ? modules : searchFilter(modules, query).toList();
    final missing = _hasBlock.values.where((has) => !has).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('device_info_search'),
          controller: _searchCtl,
          decoration: const InputDecoration(
            isDense: true,
            prefixIcon: Icon(Icons.search, size: 18),
            hintText: 'Find a driver',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 6),
        Text(
          '${modules.length} driver${modules.length == 1 ? '' : 's'}'
          '${missing == 0 ? '' : ', $missing with no block'}',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final stem = shown[i];
              final has = _hasBlock[stem] ?? true;
              return ListTile(
                key: ValueKey('device_info_module_$stem'),
                dense: true,
                selected: stem == _module,
                title: Text(stem.split('.').last,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis),
                subtitle: has
                    ? null
                    : Text('no block',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.error)),
                onTap: () => _open(provider, stem),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _editor(AppStateProvider provider, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(provider.modulePyPath(_module),
                  style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              key: const ValueKey('device_info_scan'),
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: const Text('Read the file'),
              onPressed: () => _scan(provider),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              key: const ValueKey('device_info_save'),
              icon: const Icon(Icons.save, size: 18),
              label: const Text('Save to the .py'),
              onPressed: () => _save(provider),
            ),
          ],
        ),
        if (_notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: theme.colorScheme.tertiary),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final note in _notes)
                  Text('• $note',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.tertiary)),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        Expanded(
          child: ListView(
            children: [
              _section(theme, 'Device family',
                  'Which tabs offer these models. A driver with none shows on '
                  'no tab at all.'),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final family in _familySuggestions(provider))
                    FilterChip(
                      key: ValueKey('device_info_family_$family'),
                      label: Text(family),
                      selected: _deviceTypes.contains(family),
                      onSelected: (on) => setState(() {
                        _dirty = true;
                        on
                            ? _deviceTypes.add(family)
                            : _deviceTypes.remove(family);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              _section(theme, 'Models',
                  'One per line. These are what the Model dropdown offers, '
                  'and picking one is what sets a device to this driver.'),
              TextField(
                key: const ValueKey('device_info_models'),
                controller: _modelsCtl,
                minLines: 3,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(border: OutlineInputBorder()),
                onChanged: (_) => _dirty = true,
              ),
              const SizedBox(height: 16),

              _section(theme, 'Connection',
                  'How the box is reached. Written onto a device block when '
                  'somebody picks one of the models above.'),
              _rows(theme, _connection, kConnectionKeys, name: 'connection'),
              const SizedBox(height: 16),

              _section(theme, 'Defaults',
                  'The rest of the device block: panel object names, the '
                  'keep-alive, the credentials.'),
              _rows(theme, _defaults, kDefaultsKeys, name: 'defaults'),
              if (_commands.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Commands this driver can be polled on: '
                    '${_commands.take(12).join(', ')}'
                    '${_commands.length > 12 ? ', ...' : ''}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 16),

              _section(theme, 'One block per connection style',
                  'What this driver wants when the device is reached THAT '
                  'way. Changing com_type on a device loads the matching '
                  'block; picking a model merges it over the two above.'),
              for (final style in kComTypeStyleLabels.keys)
                _comTypeBlock(theme, style),
              const SizedBox(height: 16),

              _section(theme, 'Keys this model does not use',
                  'Comma separated, "*" allowed. A family default this model '
                  'has no use for - an IN1608 gets no group_* audio keys.'),
              TextField(
                key: const ValueKey('device_info_omit'),
                controller: _omitCtl,
                decoration: const InputDecoration(border: OutlineInputBorder()),
                onChanged: (_) => _dirty = true,
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ],
    );
  }

  /// The families the schema knows about, plus the words the device folder
  /// already uses. Both, because they are not the same list: 'display' and
  /// 'doccam' are real device_type values that no schema family spells.
  List<String> _familySuggestions(AppStateProvider provider) {
    final out = <String>{};
    for (final spec in provider.uiSchema.deviceTypes) {
      final token = AppStateProvider.normalizeDeviceTypeToken(spec.prefix);
      if (token.isNotEmpty) out.add(token);
    }
    out.addAll(kDeviceInfoFamilyLabels.keys);
    out.addAll(_deviceTypes); // whatever this file already says, even if odd
    final list = out.toList()..sort();
    return list;
  }

  Widget _section(ThemeData theme, String title, String why) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            Text(why,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );

  /// A block of key/value rows, with the keys it usually carries offered.
  /// [name] is what the row keys are built from ('connection',
  /// 'defaults', a connection style), so a test can name the block it
  /// means and two blocks on one page never share a key.
  Widget _rows(
    ThemeData theme,
    List<_Pair> rows,
    List<String> suggested, {
    required String name,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, row) in rows.indexed)
            Padding(
              key: ValueKey('device_info_row_${name}_$i'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // BOTH FIELDS DECORATED IDENTICALLY, which is what keeps
                      // them on one line. The key's description used to be the
                      // decoration's helperText, and a helper line makes that
                      // field taller than the one beside it - so the Row
                      // centred the two boxes against each other and neither
                      // the boxes in a row nor the rows down a block lined up.
                      // The description sits under the row instead.
                      SizedBox(
                        width: 200,
                        child: TextField(
                          controller: row.key,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => setState(() => _dirty = true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: row.value,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) => _dirty = true,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Drop this key',
                        onPressed: () => setState(() {
                          rows.remove(row);
                          row.dispose();
                          _dirty = true;
                        }),
                      ),
                    ],
                  ),
                  // What the key means, from the same dictionary the (i)
                  // buttons use - under the pair rather than beside one of
                  // them, so it reads as being about the row.
                  ?_describeUnder(theme, row.key.text),
                ],
              ),
            ),
          Wrap(
            spacing: 6,
            children: [
              for (final key in suggested)
                if (!rows.any((r) => r.key.text.trim() == key))
                  ActionChip(
                    label: Text('+ $key', style: theme.textTheme.labelSmall),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() {
                      rows.add(_Pair(key, ''));
                      _dirty = true;
                    }),
                  ),
              ActionChip(
                label: Text('+ another key', style: theme.textTheme.labelSmall),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  rows.add(_Pair('', ''));
                  _dirty = true;
                }),
              ),
            ],
          ),
        ],
      );

  Widget _comTypeBlock(ThemeData theme, String style) {
    final rows = _comTypes[style];
    final label = kComTypeStyleLabels[style]!;
    if (rows == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ActionChip(
          key: ValueKey('device_info_add_$style'),
          label: Text('+ $label block', style: theme.textTheme.labelSmall),
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() {
            _comTypes[style] = [];
            _dirty = true;
          }),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label, style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'Drop the $label block',
                  onPressed: () => setState(() {
                    for (final row in rows) {
                      row.dispose();
                    }
                    _comTypes.remove(style);
                    _dirty = true;
                  }),
                ),
              ],
            ),
            _rows(theme, rows, kConnectionKeys, name: style),
          ],
        ),
      ),
    );
  }

  /// What a config key means, from the same dictionary the (i) buttons use.
  String? _describe(String key) {
    final text = ConfigDictionary.descriptions[key.trim()];
    if (text == null) return null;
    // The first sentence: this is a line under a row, not a manual page.
    final stop = text.indexOf('. ');
    return stop < 0 ? text : text.substring(0, stop + 1);
  }

  /// That description as the line under a row, or nothing when the dictionary
  /// has never heard of the key - which is most of a driver's own keys.
  Widget? _describeUnder(ThemeData theme, String key) {
    final text = _describe(key);
    if (text == null) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 3, 40, 0),
      child: Text(
        text,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
