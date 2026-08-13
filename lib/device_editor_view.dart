import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_port_editor.dart';
import 'cost_estimate.dart' show trimNumber, formatMoney;
import 'device_merge.dart';
import 'live_text_field.dart';
import 'side_pane.dart';

/// ============================================================================
///  DEVICE EDITOR TAB
/// ============================================================================
///  The catalog every room is built from: for each model, what connectors it
///  has, how many rack units it takes, what it draws, and what it costs.
///
///  The room config describes control and nothing else — it knows a device's
///  IP address, never that it has four HDMI inputs, is 2U, draws 90 W and
///  lists at $8,500. Those four facts are what the AV diagram, the rack
///  elevation, the power estimate and the cost estimate are all built out of,
///  so they live here once instead of being re-typed per room.
///
///  Saved to `av_devices.json` in the Root Folder (or wherever the loaded one
///  came from). Entries here override the app's built-in models; a built-in
///  you never touch stays built-in, so a later app build can still improve it.
///
///  MERGE exists because two engineers keep two copies of this file, and
///  neither is authoritative: one has priced the switchers, the other has
///  drawn their connectors. Pick their file and every difference comes up
///  with its own checkbox — take one field, one device, or all of it.
/// ============================================================================

class DeviceEditorView extends StatefulWidget {
  const DeviceEditorView({super.key});

  @override
  State<DeviceEditorView> createState() => _DeviceEditorViewState();
}

class _DeviceEditorViewState extends State<DeviceEditorView> {
  /// Normalized model key of the entry being edited.
  String _selectedKey = '';

  String _search = '';
  String _categoryFilter = '';
  bool _customOnly = false;

  /// Retired models are hidden by default. They are still IN the catalog —
  /// rooms that already use one keep resolving its ports and price — but a
  /// list of a thousand parts is hard enough to search without the
  /// discontinued half of it in the way.
  bool _showRetired = false;

  /// True when the catalog has been edited since the last write to disk.
  bool _dirty = false;

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null),
    );
  }

  /// Opens a catalog entry's product page in the system browser.
  ///
  /// Only http(s) is launched. The field is free text in a file the user can
  /// hand-edit or import, and handing an arbitrary scheme to the shell is how
  /// a catalog entry turns into "open anything on this machine".
  Future<void> _openUrl(String raw) async {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      _snack('Not a web address: $text', error: true);
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) _snack('Could not open $text', error: true);
    }
  }

  // --- editing helpers ------------------------------------------------------

  AvDeviceTemplate? _selected(AvDeviceLibrary library) {
    for (final t in library.all) {
      if (AvDeviceLibrary.normalizeModel(t.model) == _selectedKey) return t;
    }
    return null;
  }

  /// Writes an edited entry back into the catalog (in memory). Disk is only
  /// touched by Save, so a mistyped price is one Ctrl-Z of the mind away
  /// rather than already on everyone's shared drive.
  void _apply(AvDeviceTemplate updated, {String previousModel = ''}) {
    final provider = context.read<AppStateProvider>();
    provider.avDeviceLibrary.upsert(updated, previousModel: previousModel);
    _selectedKey = AvDeviceLibrary.normalizeModel(updated.model);
    _dirty = true;
    provider.avDeviceLibraryChanged();
  }

  Future<void> _save() async {
    final provider = context.read<AppStateProvider>();
    final saved = await provider.saveAvDeviceLibrary();
    if (saved.isEmpty) {
      _snack('Could not save the device catalog.', error: true);
      return;
    }
    setState(() => _dirty = false);
    _snack('Device catalog saved to $saved');
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final library = provider.avDeviceLibrary;
    final entries = _filtered(library);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToolbar(provider, library),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              // Draggable and foldable: the entry form beside it is wide, and
              // on a laptop 340 pixels of model list is most of the screen
              // when you are filling one entry in.
              SidePane(
                side: PaneSide.left,
                title: 'Models',
                storageKey: 'catalog_list',
                initialWidth: 340,
                minWidth: 200,
                maxWidth: 560,
                child: _buildList(entries),
              ),
              Expanded(child: _buildDetail(provider, library)),
            ],
          ),
        ),
      ],
    );
  }

  List<AvDeviceTemplate> _filtered(AvDeviceLibrary library) {
    final narrowed = library.all.where((t) {
      if (!_showRetired && t.retired) return false;
      if (_customOnly && !t.custom) return false;
      if (_categoryFilter.isNotEmpty && t.category != _categoryFilter) {
        return false;
      }
      return true;
    }).toList();
    // Same matching as the AV tab's model picker: spaces, dashes and case are
    // ignored, so "dtpcross108" finds "DTP CrossPoint 108".
    return searchCatalog(narrowed, _search, limit: narrowed.length);
  }

  Widget _buildToolbar(AppStateProvider provider, AvDeviceLibrary library) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Device Editor', style: theme.textTheme.titleLarge),
              const SizedBox(width: 4),
              if (_dirty)
                Chip(
                  avatar: const Icon(Icons.edit, size: 16),
                  label: const Text('Unsaved changes'),
                  backgroundColor: theme.colorScheme.errorContainer,
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New device'),
                onPressed: () => _showNewDeviceDialog(library),
              ),
              // A billable line that is not a box: it needs a name, a price
              // and nothing else, so it skips the connector and rack-height
              // half of the editor rather than being filled in with zeroes.
              OutlinedButton.icon(
                icon: const Icon(Icons.receipt_long, size: 18),
                label: const Text('New cost item'),
                onPressed: () => _showNewDeviceDialog(library, costItem: true),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.percent, size: 18),
                label: const Text('Education prices...'),
                onPressed: () => _showEducationPricingDialog(provider, library),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.merge, size: 18),
                label: const Text('Merge from file...'),
                onPressed: () => _startMerge(provider),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Export a copy...'),
                onPressed: () => _exportCopy(provider),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Reload'),
                onPressed: () => _reload(provider),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save catalog'),
                onPressed: _save,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 260,
                child: LiveTextField(
                  fieldId: 'catalog_search',
                  initial: _search,
                  hint: 'Search model, maker, part number',
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  initialValue: _categoryFilter.isEmpty ? null : _categoryFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    labelText: 'Category',
                  ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('All')),
                    for (final c in library.categories)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _categoryFilter = v ?? ''),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                label: const Text('My entries only'),
                selected: _customOnly,
                onSelected: (v) => setState(() => _customOnly = v),
              ),
              const SizedBox(width: 8),
              FilterChip(
                avatar: const Icon(Icons.history_toggle_off, size: 18),
                label: Text(
                  library.retiredCount == 0
                      ? 'Show retired'
                      : 'Show retired (${library.retiredCount})',
                ),
                selected: _showRetired,
                onSelected: (v) => setState(() => _showRetired = v),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  '${library.modelCount} models '
                  '(${library.customCount} yours) · '
                  '${provider.effectiveAvDevicesPath}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- the list -------------------------------------------------------------

  Widget _buildList(List<AvDeviceTemplate> entries) {
    final theme = Theme.of(context);
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No models match. Clear the search, or add one with '
            '"New device".',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (ctx, i) {
        final t = entries[i];
        final key = AvDeviceLibrary.normalizeModel(t.model);
        final facts = [
          if (t.retired) 'RETIRED',
          if (t.rackUnits > 0) '${t.rackUnits}U',
          '${t.inputCount} in / ${t.outputCount} out',
          if (t.powerWatts > 0) '${trimNumber(t.powerWatts)} W',
        ].join(' · ');

        return ListTile(
          dense: true,
          selected: key == _selectedKey,
          leading: Icon(
            t.custom ? Icons.edit_note : Icons.inventory_2_outlined,
            size: 20,
            color: t.custom ? theme.colorScheme.primary : theme.disabledColor,
          ),
          title: Text(
            t.model,
            style: TextStyle(
              fontSize: 13,
              // Struck through rather than hidden: when the filter is off,
              // a retired part should be recognizable at a glance.
              decoration: t.retired ? TextDecoration.lineThrough : null,
              color: t.retired ? theme.disabledColor : null,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              if (t.manufacturer.isNotEmpty) t.manufacturer,
              facts,
            ].where((s) => s.isNotEmpty).join(' — '),
            style: const TextStyle(fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
          // Both tiers, so a part way through pricing the catalog is obvious
          // from the list rather than one entry at a time.
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                t.price > 0 ? formatMoney(t.price) : '—',
                style: TextStyle(
                  fontSize: 12,
                  color: t.price > 0 ? null : theme.disabledColor,
                ),
              ),
              Text(
                t.educationPrice > 0
                    ? '${formatMoney(t.educationPrice)} edu'
                    : 'no edu price',
                style: TextStyle(
                  fontSize: 10,
                  color: t.educationPrice > 0
                      ? theme.colorScheme.primary
                      : theme.disabledColor,
                ),
              ),
            ],
          ),
          onTap: () => setState(() => _selectedKey = key),
        );
      },
    );
  }

  // --- the editor -----------------------------------------------------------

  Widget _buildDetail(AppStateProvider provider, AvDeviceLibrary library) {
    final theme = Theme.of(context);
    final entry = _selected(library);
    if (entry == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.inventory_2_outlined,
                size: 64,
                color: theme.disabledColor,
              ),
              const SizedBox(height: 16),
              Text(
                'Pick a model on the left to edit its connectors, rack '
                'height, power draw and price — or add one with "New '
                'device".',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    final ports = List<AvPort>.from(entry.ports);
    final key = AvDeviceLibrary.normalizeModel(entry.model);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: LiveTextField(
                // The model name is the entry's identity, so it commits on
                // Enter or focus loss rather than per keystroke — renaming
                // letter by letter would walk over every entry whose name is
                // a prefix of the new one.
                fieldId: 'model_$key',
                initial: entry.model,
                label: 'Model (identifies the entry)',
                onChanged: (_) {},
                onSubmitted: (v) => _rename(library, entry, v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: LiveTextField(
                fieldId: 'maker_$key',
                initial: entry.manufacturer,
                label: 'Manufacturer',
                onChanged: (v) =>
                    setState(() => _apply(entry.copyWith(manufacturer: v))),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: LiveTextField(
                fieldId: 'part_$key',
                initial: entry.partNumber,
                label: 'Part number',
                onChanged: (v) =>
                    setState(() => _apply(entry.copyWith(partNumber: v))),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: LiveTextField(
                fieldId: 'cat_$key',
                initial: entry.category,
                label: 'Category',
                hint: 'Switcher, Camera, Display...',
                onChanged: (v) =>
                    setState(() => _apply(entry.copyWith(category: v))),
              ),
            ),
            // The categories the app itself keys off. Typed text still works —
            // this is a shortcut to the spellings that make an entry show up
            // on the rack editor's parts list or in the cabling section, which
            // are exactly the ones a typo silently costs you.
            PopupMenuButton<String>(
              tooltip: 'Use a known category',
              icon: const Icon(Icons.arrow_drop_down),
              onSelected: (v) => setState(
                () => _apply(
                  entry.copyWith(
                    category: v,
                    // A cable needs a signal type to be priced against the
                    // diagram; default it to the first rather than leaving an
                    // entry that looks priced and matches nothing.
                    cableSignal: v == kCategoryCable
                        ? (entry.cableSignal ?? SignalType.hdmi)
                        : null,
                    clearCableSignal: v != kCategoryCable,
                  ),
                ),
              ),
              itemBuilder: (ctx) => [
                for (final c in kWellKnownCategories)
                  PopupMenuItem(value: c, child: Text(c)),
              ],
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: LiveTextField(
                fieldId: 'ru_$key',
                initial: entry.rackUnits == 0 ? '' : '${entry.rackUnits}',
                label: 'Rack U',
                helper: '0 = not racked',
                numeric: true,
                onChanged: (v) => setState(
                  () => _apply(
                    entry.copyWith(rackUnits: int.tryParse(v.trim()) ?? 0),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 130,
              child: LiveTextField(
                fieldId: 'watts_$key',
                initial: entry.powerWatts == 0
                    ? ''
                    : trimNumber(entry.powerWatts),
                label: 'Power',
                suffix: 'W',
                helper: 'typical draw',
                numeric: true,
                onChanged: (v) => setState(
                  () => _apply(
                    entry.copyWith(powerWatts: double.tryParse(v.trim()) ?? 0),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 140,
              child: LiveTextField(
                fieldId: 'btu_$key',
                initial: entry.btuPerHour == 0
                    ? ''
                    : trimNumber(entry.btuPerHour),
                label: 'Heat',
                suffix: 'BTU/hr',
                helper: entry.powerWatts > 0
                    ? 'blank = ${trimNumber(entry.powerWatts * kWattsToBtu)}'
                    : 'blank = from W',
                numeric: true,
                onChanged: (v) => setState(
                  () => _apply(
                    entry.copyWith(btuPerHour: double.tryParse(v.trim()) ?? 0),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 150,
              child: LiveTextField(
                fieldId: 'price_$key',
                initial: entry.price == 0 ? '' : trimNumber(entry.price),
                label: 'MSRP',
                helper: 'list price',
                numeric: true,
                onChanged: (v) => setState(
                  () => _apply(
                    entry.copyWith(price: double.tryParse(v.trim()) ?? 0),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 150,
              child: LiveTextField(
                fieldId: 'edu_$key',
                initial: entry.educationPrice == 0
                    ? ''
                    : trimNumber(entry.educationPrice),
                label: 'Education price',
                helper: 'what we pay',
                numeric: true,
                onChanged: (v) => setState(
                  () => _apply(
                    entry.copyWith(
                      educationPrice: double.tryParse(v.trim()) ?? 0,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        // WHAT MUST BE LEFT EMPTY AROUND IT. A rack elevation says what fits
        // and nothing about what should not be touching: an amplifier that
        // vents upwards, a drawer whose lid opens, a box with its intake on
        // the top cover. All of them fit under the next unit and all of them
        // fail on site. Recorded on the MODEL because whoever reads the rack
        // height off the back of the box is looking at the vents while they do
        // it, and every room that racks the part then inherits it.
        if (entry.rackUnits > 0) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 130,
                child: LiveTextField(
                  fieldId: 'clrabove_$key',
                  initial: entry.clearanceAboveU == 0
                      ? ''
                      : '${entry.clearanceAboveU}',
                  label: 'Keep clear above',
                  helper: 'U',
                  numeric: true,
                  onChanged: (v) => setState(
                    () => _apply(
                      entry.copyWith(
                        clearanceAboveU: int.tryParse(v.trim()) ?? 0,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 130,
                child: LiveTextField(
                  fieldId: 'clrbelow_$key',
                  initial: entry.clearanceBelowU == 0
                      ? ''
                      : '${entry.clearanceBelowU}',
                  label: 'Keep clear below',
                  helper: 'U',
                  numeric: true,
                  onChanged: (v) => setState(
                    () => _apply(
                      entry.copyWith(
                        clearanceBelowU: int.tryParse(v.trim()) ?? 0,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    entry.clearanceAboveU == 0 && entry.clearanceBelowU == 0
                        ? 'Minimum space around this part in a frame — leave '
                              'blank when it does not need any. The rails are '
                              'shaded light red on the rack elevation as a '
                              'warning; nothing is ever refused.'
                        : 'The rack elevation shades '
                              '${entry.clearanceAboveU} U above and '
                              '${entry.clearanceBelowU} U below every one of '
                              'these light red. A warning to whoever is '
                              'planning the frame, not a lock — anything can '
                              'still be placed there.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        // Retiring a part keeps everything it knows — ports, prices, rack
        // height — for the rooms that already have one, and takes it out of
        // the pickers that specify new work.
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: entry.retired,
          onChanged: (v) =>
              setState(() => _apply(entry.copyWith(retired: v ?? false))),
          title: const Text('Retired / discontinued'),
          subtitle: const Text(
            'Hidden from the device, parts and estimator pickers. Rooms that '
            'already use it keep its connectors and price.',
          ),
        ),
        // A cable entry says what it carries. That is the whole hinge of the
        // cabling estimate: every run of this signal type on the AV flow is
        // quoted at this entry's price.
        if (entry.isCable) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<SignalType>(
                  initialValue: entry.cableSignal ?? SignalType.hdmi,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Carries',
                    helperText: 'runs of this type on the diagram are quoted '
                        'at this price',
                    isDense: true,
                  ),
                  items: [
                    for (final s in SignalType.values)
                      DropdownMenuItem(
                        value: s,
                        child: Text(kSignalLabels[s] ?? s.name),
                      ),
                  ],
                  onChanged: (v) => setState(
                    () => _apply(entry.copyWith(cableSignal: v)),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Text('Power in', style: theme.textTheme.titleSmall),
            const SizedBox(width: 12),
            // The toggle keeps the inlet connector in step with itself: pick
            // PoE and the port relabels, pick None and it goes away, so the
            // drawing and the rack load can never disagree about whether this
            // box is plugged into anything.
            SegmentedButton<PowerInput>(
              segments: const [
                ButtonSegment(
                  value: PowerInput.mains,
                  icon: Icon(Icons.power, size: 16),
                  label: Text('Mains'),
                ),
                ButtonSegment(
                  value: PowerInput.poe,
                  icon: Icon(Icons.lan, size: 16),
                  label: Text('PoE'),
                ),
                ButtonSegment(
                  value: PowerInput.none,
                  icon: Icon(Icons.power_off, size: 16),
                  label: Text('None'),
                ),
              ],
              selected: {entry.powerInput},
              onSelectionChanged: (s) => setState(
                () => _apply(
                  entry.copyWith(
                    powerInput: s.first,
                    ports: withPowerInlet(entry.ports, s.first),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                switch (entry.powerInput) {
                  PowerInput.mains =>
                    'Lands on the room circuit; counted in the rack load.',
                  PowerInput.poe =>
                    'Fed off the network switch; kept out of the mains total.',
                  PowerInput.none =>
                    'Passive — a speaker, a cable, a blanking plate.',
                },
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.disabledColor,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // The page the numbers above were read off. Kept beside them because
        // a price and a heat figure both go stale, and the question a year
        // from now is "where did this come from", not "what is it".
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: LiveTextField(
                fieldId: 'url_$key',
                initial: entry.url,
                label: 'Product page',
                hint: 'https://...',
                onChanged: (v) =>
                    setState(() => _apply(entry.copyWith(url: v.trim()))),
              ),
            ),
            avRowIcon(
              Icons.open_in_new,
              entry.url.trim().isEmpty
                  ? 'No product page recorded'
                  : 'Open ${entry.url}',
              entry.url.trim().isEmpty ? null : () => _openUrl(entry.url),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LiveTextField(
          fieldId: 'notes_$key',
          initial: entry.notes,
          label: 'Notes',
          onChanged: (v) => setState(() => _apply(entry.copyWith(notes: v))),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Text(
              'Connectors — ${entry.inputCount} in / ${entry.outputCount} out',
              style: theme.textTheme.titleSmall,
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.login, size: 16),
              label: const Text('Add input'),
              onPressed: () => setState(
                () => _apply(
                  entry.copyWith(
                    ports: [...ports, newAvPort(index: entry.inputCount)],
                  ),
                ),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.logout, size: 16),
              label: const Text('Add output'),
              onPressed: () => setState(
                () => _apply(
                  entry.copyWith(
                    ports: [
                      ...ports,
                      newAvPort(
                        index: entry.outputCount,
                        direction: PortDirection.output,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const Divider(),
        if (ports.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No connectors yet. A model with none can still be priced and '
              'counted — it just cannot be cabled on the AV diagram.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (ports.isNotEmpty)
          Builder(
            builder: (context) {
              final keys = avPortRowKeys(ports, prefix: '${key}_');
              return ReorderableListView.builder(
                // This list sits inside the entry page's own scroll view, so
                // it lays itself out at full height and does not scroll.
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                // The row draws its own grip; the stock desktop handle floats
                // over the bottom-right of the tile, on top of the delete
                // button.
                buildDefaultDragHandles: false,
                itemCount: ports.length,
                // onReorderItem hands over an index already corrected for the
                // dragged row having left the list.
                onReorderItem: (from, to) {
                  final next = List<AvPort>.from(ports);
                  next.insert(to, next.removeAt(from));
                  setState(() => _apply(entry.copyWith(ports: next)));
                },
                itemBuilder: (context, i) => AvPortEditorRow(
                  key: keys[i],
                  dragIndex: i,
                  port: ports[i],
                  onChanged: (p) {
                    final next = List<AvPort>.from(ports)..[i] = p;
                    setState(() => _apply(entry.copyWith(ports: next)));
                  },
                  onDelete: () {
                    final next = List<AvPort>.from(ports)..removeAt(i);
                    setState(() => _apply(entry.copyWith(ports: next)));
                  },
                  onMoveUp: i == 0
                      ? null
                      : () {
                          final next = List<AvPort>.from(ports);
                          next.insert(i - 1, next.removeAt(i));
                          setState(() => _apply(entry.copyWith(ports: next)));
                        },
                  onMoveDown: i == ports.length - 1
                      ? null
                      : () {
                          final next = List<AvPort>.from(ports);
                          next.insert(i + 1, next.removeAt(i));
                          setState(() => _apply(entry.copyWith(ports: next)));
                        },
                ),
              );
            },
          ),
        const SizedBox(height: 24),
        Row(
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Duplicate'),
              onPressed: () => _showNewDeviceDialog(library, copyFrom: entry),
            ),
            const SizedBox(width: 12),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Remove from catalog'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => _confirmDelete(entry),
            ),
          ],
        ),
      ],
    );
  }

  /// Renames an entry, refusing to land on a model that already exists —
  /// upsert would silently replace it, and the entry it swallowed would only
  /// be missed weeks later.
  void _rename(
    AvDeviceLibrary library,
    AvDeviceTemplate entry,
    String proposed,
  ) {
    final name = proposed.trim();
    if (name.isEmpty || name == entry.model) return;
    final clash = library.templateForModel(name);
    if (clash != null &&
        AvDeviceLibrary.normalizeModel(clash.model) !=
            AvDeviceLibrary.normalizeModel(entry.model)) {
      _snack(
        '"$name" is already in the catalog — rename or remove that one '
        'first.',
        error: true,
      );
      return;
    }
    setState(
      () => _apply(entry.copyWith(model: name), previousModel: entry.model),
    );
  }

  Future<void> _confirmDelete(AvDeviceTemplate entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${entry.model}?'),
        content: const Text(
          'It goes out of the catalog on the next save. If it started as one '
          "of the app's built-in models, the built-in version comes back the "
          'next time the app starts — this only drops your edits to it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final provider = context.read<AppStateProvider>();
    provider.avDeviceLibrary.remove(entry.model);
    setState(() {
      _selectedKey = '';
      _dirty = true;
    });
    provider.avDeviceLibraryChanged();
  }

  Future<void> _showNewDeviceDialog(
    AvDeviceLibrary library, {
    AvDeviceTemplate? copyFrom,
    bool costItem = false,
  }) async {
    final controller = TextEditingController(
      text: copyFrom == null ? '' : '${copyFrom.model} (copy)',
    );

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          costItem
              ? 'New cost item'
              : (copyFrom == null ? 'New device' : 'Duplicate device'),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: costItem ? 'Item name' : 'Model name',
                  hintText: costItem
                      ? 'How it should read on a quote'
                      : 'Exactly as the config and quotes spell it',
                ),
                onSubmitted: (_) => Navigator.of(ctx).pop(true),
              ),
              const SizedBox(height: 8),
              Text(
                costItem
                    ? 'A billable line rather than a box — a licence, a '
                          'mount, a rental, a trip charge. Filed under '
                          '"$kCategoryMisc" with a price and no connectors, '
                          'and offered on the estimate\'s Other items.'
                    : copyFrom == null
                    ? 'Everything else — connectors, rack height, power, '
                          'price — is filled in on the next screen.'
                    : 'Starts as a copy of ${copyFrom.model}, connectors '
                          'and all.',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (created != true) return;
    final name = controller.text.trim();
    if (name.isEmpty) return;
    if (library.templateForModel(name) != null) {
      _snack('"$name" is already in the catalog.', error: true);
      return;
    }
    if (costItem) {
      // No inlet and no connectors: a licence does not draw power, and giving
      // it a mains plug would put it in the rack load and the power report.
      setState(
        () => _apply(
          AvDeviceTemplate(
            model: name,
            category: kCategoryMisc,
            powerInput: PowerInput.none,
            ports: const [],
          ),
        ),
      );
      return;
    }
    final base = copyFrom ?? const AvDeviceTemplate(model: '', ports: []);
    setState(
      () => _apply(
        base.copyWith(
          model: name,
          // A new entry starts with a mains inlet, like everything else in
          // the catalog — a device with no recorded inlet is a device the
          // rack load quietly forgets.
          ports: withPowerInlet(base.ports, base.powerInput),
        ),
      ),
    );
  }

  // --- merge ---------------------------------------------------------------

  /// Sets education prices in bulk, as a discount off MSRP.
  ///
  /// This is how the number actually arrives: a contract says "40% off list
  /// for these families", not a price per part. Typing that per device across
  /// a thousand entries is the reason the second tier would otherwise stay
  /// empty. The discount applies to whatever the list is currently filtered
  /// to, so a contract with different rates per family is a few passes rather
  /// than one blunt one.
  Future<void> _showEducationPricingDialog(
    AppStateProvider provider,
    AvDeviceLibrary library,
  ) async {
    final entries = _filtered(library).where((t) => t.price > 0).toList();
    final discountController = TextEditingController(text: '40');
    bool overwrite = false;

    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final discount = double.tryParse(discountController.text.trim()) ?? 0;
          final targets = entries
              .where((t) => overwrite || t.educationPrice <= 0)
              .toList();
          final sample = targets.isEmpty ? null : targets.first;
          return AlertDialog(
            title: const Text('Set education prices'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Works out each entry\'s education price as a discount off '
                    'its MSRP. Applies to the ${entries.length} priced '
                    'entr${entries.length == 1 ? 'y' : 'ies'} matching the '
                    'current search and category filter — narrow those first '
                    'if your contract discounts families differently.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      SizedBox(
                        width: 140,
                        child: TextField(
                          controller: discountController,
                          autofocus: true,
                          decoration: const InputDecoration(
                            labelText: 'Discount',
                            suffixText: '% off MSRP',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'),
                            ),
                          ],
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ),
                      const SizedBox(width: 16),
                      if (sample != null)
                        Expanded(
                          child: Text(
                            'e.g. ${sample.model}: '
                            '${formatMoney(sample.price, provider.currencySymbol)}'
                            ' → '
                            '${formatMoney(sample.price * (1 - discount / 100),
                                provider.currencySymbol)}',
                            style: Theme.of(ctx).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: overwrite,
                    onChanged: (v) => setLocal(() => overwrite = v ?? false),
                    title: const Text('Overwrite education prices already set'),
                    subtitle: const Text(
                      'Off: only fills the blanks, so a price typed by hand '
                      'survives.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${targets.length} entr${targets.length == 1 ? 'y' : 'ies'}'
                    ' would change.',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: discount <= 0 || discount >= 100 || targets.isEmpty
                    ? null
                    : () => Navigator.of(ctx).pop(true),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );

    if (apply != true) return;
    final discount = double.tryParse(discountController.text.trim()) ?? 0;
    if (discount <= 0 || discount >= 100) return;

    int changed = 0;
    for (final t in entries) {
      if (!overwrite && t.educationPrice > 0) continue;
      // Rounded to cents, so the catalog never carries a price that cannot be
      // written on an invoice.
      final price = ((t.price * (1 - discount / 100)) * 100).round() / 100;
      provider.avDeviceLibrary.upsert(t.copyWith(educationPrice: price));
      changed++;
    }
    if (changed > 0) {
      setState(() => _dirty = true);
      provider.avDeviceLibraryChanged();
    }
    _snack(
      '$changed education price${changed == 1 ? '' : 's'} set at '
      '${trimNumber(discount)}% off MSRP. Save the catalog to keep them.',
    );
  }

  Future<void> _startMerge(AppStateProvider provider) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Pick the device catalog to merge in',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final chosen = picked?.files.single.path;
    if (chosen == null) return;

    late final List<DeviceDiff> diffs;
    try {
      final theirs = await AvDeviceLibrary.readFile(chosen);
      diffs = diffCatalogs(provider.avDeviceLibrary, theirs);
    } catch (e) {
      _snack('Could not read $chosen: $e', error: true);
      return;
    }
    if (!mounted) return;

    if (diffs.isEmpty) {
      _snack(
        'Nothing to merge — ${path.basename(chosen)} says the same as your '
        'catalog.',
      );
      return;
    }

    final applied = await showDialog<int>(
      context: context,
      builder: (ctx) => _MergeDialog(
        fileName: path.basename(chosen),
        diffs: diffs,
        library: provider.avDeviceLibrary,
      ),
    );
    if (applied == null || applied == 0 || !mounted) return;

    setState(() => _dirty = true);
    provider.avDeviceLibraryChanged();
    _snack(
      'Merged $applied model${applied == 1 ? '' : 's'} from '
      '${path.basename(chosen)} — Save catalog to write it to disk.',
    );
  }

  Future<void> _exportCopy(AppStateProvider provider) async {
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Export a copy of the device catalog',
      fileName: 'av_devices.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.json')) outputFile += '.json';
    // rebind: false — handing a colleague a copy must not repoint your own
    // Save at their folder.
    final saved = await provider.avDeviceLibrary.save(
      toPath: outputFile,
      rebind: false,
    );
    if (!mounted) return;
    if (saved.isEmpty) {
      _snack('Could not write the copy.', error: true);
      return;
    }
    // A write reconciles the power inlets, so the entry on screen may have
    // just gained or lost one even though this was "only" an export.
    provider.avDeviceLibraryChanged();
    showSavedFileSnack(context, provider, 'Catalog copy', saved);
  }

  Future<void> _reload(AppStateProvider provider) async {
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard unsaved catalog changes?'),
          content: const Text(
            'Reloading reads av_devices.json back off disk. Anything edited '
            'here since the last save is lost.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Discard and reload'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    await provider.loadAvDeviceLibrary();
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _selectedKey = '';
    });
    _snack('Device catalog reloaded.');
  }
}

// ---------------------------------------------------------------------------
//  MERGE DIALOG
// ---------------------------------------------------------------------------

/// Every difference between the two catalogs, each with its own checkbox.
/// New models come first (nothing of yours is at stake), then the models you
/// both describe differently, expandable field by field.
class _MergeDialog extends StatefulWidget {
  final String fileName;
  final List<DeviceDiff> diffs;
  final AvDeviceLibrary library;

  const _MergeDialog({
    required this.fileName,
    required this.diffs,
    required this.library,
  });

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final added = widget.diffs.where((d) => d.isNew).toList();
    final changed = widget.diffs.where((d) => !d.isNew).toList();
    final selected = widget.diffs.fold(0, (n, d) => n + d.selectedCount);
    final total = widget.diffs.fold(0, (n, d) => n + d.decisionCount);

    return AlertDialog(
      title: Text('Merge from ${widget.fileName}'),
      content: SizedBox(
        width: 820,
        height: MediaQuery.of(context).size.height - 220,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${added.length} model${added.length == 1 ? '' : 's'} you do not '
              'have, ${changed.length} you describe differently. Tick what to '
              'take; everything else is left exactly as it is. Nothing is '
              'deleted, and nothing is written to disk until you save the '
              'catalog.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.done_all, size: 16),
                  label: const Text('Select all'),
                  onPressed: () => setState(() {
                    for (final d in widget.diffs) {
                      d.setAll(true);
                    }
                  }),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.remove_done, size: 16),
                  label: const Text('Select none'),
                  onPressed: () => setState(() {
                    for (final d in widget.diffs) {
                      d.setAll(false);
                    }
                  }),
                ),
                const Spacer(),
                Text(
                  '$selected of $total selected',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  if (added.isNotEmpty) ...[
                    _sectionLabel(theme, 'New models'),
                    for (final d in added) _newRow(theme, d),
                  ],
                  if (changed.isNotEmpty) ...[
                    _sectionLabel(theme, 'Models you both have'),
                    for (final d in changed) _changedTile(theme, d),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(0),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: selected == 0
              ? null
              : () => Navigator.of(
                  context,
                ).pop(applyMerge(widget.library, widget.diffs)),
          child: Text('Merge $selected selected'),
        ),
      ],
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
    child: Text(text, style: theme.textTheme.titleSmall),
  );

  Widget _newRow(ThemeData theme, DeviceDiff d) {
    final t = d.theirs;
    final facts = [
      if (t.manufacturer.isNotEmpty) t.manufacturer,
      if (t.rackUnits > 0) '${t.rackUnits}U',
      '${t.inputCount} in / ${t.outputCount} out',
      if (t.powerWatts > 0) '${trimNumber(t.powerWatts)} W',
      if (t.price > 0) formatMoney(t.price),
    ].join(' · ');

    return CheckboxListTile(
      dense: true,
      value: d.selected,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(d.model, style: const TextStyle(fontSize: 13)),
      subtitle: Text(facts, style: const TextStyle(fontSize: 11)),
      onChanged: (v) => setState(() => d.selected = v ?? false),
    );
  }

  Widget _changedTile(ThemeData theme, DeviceDiff d) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: Checkbox(
          value: d.allSelected
              ? true
              : (d.anySelected ? null : false),
          tristate: true,
          onChanged: (_) => setState(() => d.setAll(!d.allSelected)),
        ),
        title: Text(d.model, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          '${d.fields.length} difference${d.fields.length == 1 ? '' : 's'}: '
          '${d.fields.map((f) => f.label).join(', ')}',
          style: const TextStyle(fontSize: 11),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          Row(
            children: [
              const SizedBox(width: 48),
              SizedBox(
                width: 130,
                child: Text('Field', style: theme.textTheme.labelSmall),
              ),
              Expanded(
                child: Text('Yours', style: theme.textTheme.labelSmall),
              ),
              Expanded(
                child: Text('Theirs', style: theme.textTheme.labelSmall),
              ),
            ],
          ),
          const Divider(height: 8),
          for (final f in d.fields)
            Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Checkbox(
                    value: f.selected,
                    onChanged: (v) => setState(() => f.selected = v ?? false),
                  ),
                ),
                SizedBox(
                  width: 130,
                  child: Text(f.label, style: const TextStyle(fontSize: 12)),
                ),
                Expanded(
                  child: Text(
                    f.mine,
                    style: TextStyle(fontSize: 12, color: theme.disabledColor),
                  ),
                ),
                Expanded(
                  child: Text(
                    f.theirs,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: f.selected ? FontWeight.bold : null,
                      color: f.selected ? theme.colorScheme.primary : null,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
