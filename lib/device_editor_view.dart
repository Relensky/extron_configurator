import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'contrast.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_swap_dialogs.dart' show pickCatalogModel;
import 'av_port_editor.dart';
import 'cost_estimate.dart' show trimNumber, formatMoney;
import 'device_merge.dart';
import 'equipment_lifecycle.dart' show kDefaultEquipmentLifeYears;
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

/// What order the model list comes back in.
///
/// [bestMatch] is the list's own order — by maker, then by model, which is how
/// [AvDeviceLibrary.all] hands it over — except while something is typed in
/// the search box, where relevance wins: "dtpcross108" has to put the DTP
/// CrossPoint 108 first no matter who makes it. The other three are the
/// question somebody is answering when they pick them, and they answer it
/// whether the search box is empty or not.
enum _CatalogSort { bestMatch, manufacturer, model, price }

const Map<_CatalogSort, String> _kCatalogSortLabels = {
  _CatalogSort.bestMatch: 'Best match',
  _CatalogSort.manufacturer: 'Manufacturer',
  _CatalogSort.model: 'Model',
  _CatalogSort.price: 'Price, high to low',
};

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

  /// What the list is ordered by — see [_CatalogSort].
  _CatalogSort _sort = _CatalogSort.bestMatch;

  /// Retired models are hidden by default. They are still IN the catalog —
  /// rooms that already use one keep resolving its ports and price — but a
  /// list of a thousand parts is hard enough to search without the
  /// discontinued half of it in the way.
  bool _showRetired = false;

  /// True when the catalog has been edited since the last write to disk.
  bool _dirty = false;

  /// Bumped to put the model box back to what the entry is actually called.
  ///
  /// The box commits on Enter or focus loss and owns its own text, so a name
  /// the rename REFUSED — it clashes, or the question about the open room was
  /// canceled — sat in the field looking applied while the entry kept its old
  /// name. Changing the field's id is what makes it re-read the entry.
  int _modelFieldRevision = 0;

  /// Puts the model box back, after a rename that did not happen.
  void _revertModelField() =>
      setState(() => _modelFieldRevision++);

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? snackErrorFill(context) : null),
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
  /// WHAT REPLACES A RETIRED ENTRY, and what that costs today.
  ///
  /// ============================================================================
  ///  RETIRING WITHOUT SAYING WHAT INSTEAD IS HALF AN ANSWER
  /// ============================================================================
  ///  Retiring an entry answers "do not specify this any more" and leaves
  ///  "what does it cost to replace the forty of them already on the estate"
  ///  answered with the discontinued product's own list price - a real figure,
  ///  for a real catalog entry, that nobody can buy anything at. On a
  ///  four-year refresh plan that is the entire budget, wrong by whatever the
  ///  successor went up by, with nothing on any screen saying so.
  ///
  ///  Naming the successor here fixes it in every reader at once: the room's
  ///  cost page, the project report and the campus report all price a
  ///  replacement through the same ladder, and its first rung follows this.
  ///  See [AvDeviceLibrary.successorFor] and [equipmentReplacementPrice].
  ///
  ///  PICKED, NOT TYPED, for the reason every model reference in this app is:
  ///  a name the catalog does not have is a chain that stops, silently, at the
  ///  price it was trying to get away from.
  Widget _replacedBy(BuildContext context, AvDeviceTemplate entry) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final library = provider.avDeviceLibrary;
    final named = entry.replacedBy.trim();
    final successor = named.isEmpty ? null : library.templateForModel(named);
    // The end of the chain, which is what a replacement is actually priced at
    // - a 2012 model replaced by a 2016 one replaced by a 2024 one prices at
    // the 2024 one.
    final buying = library.successorFor(entry.model);
    final chained = buying != null &&
        successor != null &&
        AvDeviceLibrary.normalizeModel(buying.model) !=
            AvDeviceLibrary.normalizeModel(successor.model);

    return Padding(
      padding: const EdgeInsets.only(left: 32, top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                key: const ValueKey('catalog_replaced_by'),
                icon: const Icon(Icons.sync_alt, size: 18),
                label: Text(
                  named.isEmpty ? 'Replaced by...' : named,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: () async {
                  final picked = await pickCatalogModel(
                    context,
                    provider,
                    title: 'What replaces ${entry.model}?',
                    actionLabel: 'This one',
                    currentModel: named.isEmpty ? null : named,
                    note: 'Every room already holding a ${entry.model} will '
                        'be budgeted at what this one costs.',
                  );
                  if (picked == null) return;
                  setState(
                    () => _apply(entry.copyWith(replacedBy: picked.model)),
                  );
                },
              ),
              if (named.isNotEmpty) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('catalog_replaced_by_clear'),
                  tooltip: 'No successor. Rooms holding one are budgeted at '
                      'this entry\'s own price again.',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () =>
                      setState(() => _apply(entry.copyWith(replacedBy: ''))),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(
            named.isEmpty
                ? 'Nothing named, so a room holding one is still budgeted at '
                      'this entry\'s own price - which is the price of a '
                      'product nobody sells.'
                : successor == null
                ? 'The catalog has no "$named". The chain stops here and rooms '
                      'holding one are budgeted at this entry\'s own price.'
                : chained
                ? 'Rooms holding a ${entry.model} are budgeted at '
                      '${buying.model} - $named is retired too, and the '
                      'chain runs on to it.'
                : 'Rooms holding a ${entry.model} are budgeted at what a '
                      '$named costs'
                      '${successor.price > 0 ? ' - ${formatMoney(successor.price, provider.currencySymbol)}' : ''}'
                      '.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

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

  /// What the rest of the catalog already stocks this cable in, so the entry
  /// being edited is filled in against the list rather than against memory.
  String _cableLengthNote(AvDeviceLibrary library, AvDeviceTemplate entry) {
    final signal = entry.cableSignal;
    if (signal == null) return '';
    final family = library
        .cablesForSignal(signal)
        .where((t) => t.cableLengthFt > 0)
        .toList();
    if (family.isEmpty) {
      return 'Nothing else is stocked for this signal yet. Add one entry per '
          'length - 3 ft, 6 ft, 25 ft - each with its own price, and the '
          'estimate buys every run the shortest one that reaches it.';
    }
    final lengths = family
        .map((t) => '${trimNumber(t.cableLengthFt)} ft')
        .join(', ');
    return 'Stocked for this signal: $lengths. A run longer than the longest '
        'is quoted at the longest.';
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
    final matched = searchCatalog(narrowed, _search, limit: narrowed.length);
    if (_sort == _CatalogSort.bestMatch) return matched;

    // A CHOSEN ORDER OUTRANKS RELEVANCE, because it was chosen while the
    // search box had something in it: "every Extron switcher, by maker" is a
    // list you scroll, not a list you take the top of.
    final sorted = List<AvDeviceTemplate>.of(matched);
    int byModel(AvDeviceTemplate a, AvDeviceTemplate b) =>
        a.model.toLowerCase().compareTo(b.model.toLowerCase());
    switch (_sort) {
      case _CatalogSort.manufacturer:
        sorted.sort((a, b) {
          final makerA = a.manufacturer.trim();
          final makerB = b.manufacturer.trim();
          // Unattributed entries last: an empty string sorts above every
          // letter, which would open a maker-sorted catalog on the parts
          // nobody has said who makes.
          if (makerA.isEmpty != makerB.isEmpty) return makerA.isEmpty ? 1 : -1;
          final byMaker = makerA.toLowerCase().compareTo(makerB.toLowerCase());
          return byMaker != 0 ? byMaker : byModel(a, b);
        });
      case _CatalogSort.model:
        sorted.sort(byModel);
      case _CatalogSort.price:
        // Highest first: the reason to sort a catalog by price is to find what
        // is carrying the money, or to spot the entry with a decimal point in
        // the wrong place.
        sorted.sort((a, b) {
          final byPrice = b.price.compareTo(a.price);
          return byPrice != 0 ? byPrice : byModel(a, b);
        });
      case _CatalogSort.bestMatch:
        break;
    }
    return sorted;
  }

  Widget _buildToolbar(AppStateProvider provider, AvDeviceLibrary library) {
    final theme = Theme.of(context);
    final duplicates = library.duplicateParts;
    // How many categories in the catalog are words the app cannot map onto a
    // config section. Counted here rather than in the button so the label and
    // the dialog are reading the same list.
    final untracked = library.categoryCounts
        .where((c) => !isTrackedCategory(c.category))
        .length;
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
                  // The avatar as well as the label: an icon on a fill nobody
                  // measured is the same fault drawn smaller.
                  avatar: Icon(
                    Icons.edit,
                    size: 16,
                    color: errorTextOn(
                      theme.colorScheme,
                      theme.colorScheme.errorContainer,
                    ),
                  ),
                  label: Text(
                    'Unsaved changes',
                    style: TextStyle(
                      color: errorTextOn(
                        theme.colorScheme,
                        theme.colorScheme.errorContainer,
                      ),
                    ),
                  ),
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
              // ONE VOCABULARY, OR THE APP UNDERSTANDS NONE OF IT. A price
              // list imported under the manufacturer's own aisle names -
              // 'Fox Systems', 'XTP Systems', 'Scalers Switchers' - reads
              // perfectly well in the column and prices at nothing, because
              // nothing in the app maps those words onto a room's config
              // section. See [kTrackedCategories]. Labeled with the count so
              // it says how much of the catalog is in that state, and shown
              // in the ordinary style rather than in red: an untracked
              // category is untidy, not broken.
              OutlinedButton.icon(
                key: const ValueKey('catalog_tidy_categories'),
                icon: const Icon(Icons.label_outline, size: 18),
                label: Text(
                  untracked == 0
                      ? 'Tidy categories...'
                      : 'Tidy categories ($untracked)...',
                ),
                onPressed: () => _tidyCategories(provider),
              ),
              // ONE PART NUMBER, ONE ENTRY. Two imports of the same box under
              // two model names are two half-filled entries that drift apart,
              // and the part number is the only thing that says they are the
              // same product. Shown only when there is something to fix, in
              // the error color, because a catalog that is clean should not
              // carry a permanent warning about it.
              if (duplicates.isNotEmpty)
                OutlinedButton.icon(
                  key: const ValueKey('catalog_duplicates'),
                  icon: const Icon(Icons.copy_all, size: 18),
                  label: Text(
                    duplicates.length == 1
                        ? '1 duplicate part number'
                        : '${duplicates.length} duplicate part numbers',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                  onPressed: () => _showDuplicates(provider),
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
          // A WRAP, for the same reason the toolbar above it is one: search,
          // two pickers and two chips are wider than a laptop window with the
          // side pane open, and a Row of that shape paints its last control
          // off the edge of the page under a yellow-and-black bar.
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
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
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<_CatalogSort>(
                  key: const ValueKey('catalog_sort'),
                  initialValue: _sort,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    labelText: 'Sort by',
                  ),
                  items: [
                    for (final sort in _CatalogSort.values)
                      DropdownMenuItem(
                        value: sort,
                        child: Text(_kCatalogSortLabels[sort] ?? sort.name),
                      ),
                  ],
                  onChanged: (v) =>
                      setState(() => _sort = v ?? _CatalogSort.bestMatch),
                ),
              ),
              FilterChip(
                label: const Text('My entries only'),
                selected: _customOnly,
                onSelected: (v) => setState(() => _customOnly = v),
              ),
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
              // Bounded rather than Expanded: a Wrap gives a child whatever
              // width it asks for, and a long share path would ask for the
              // page. This asks for at most a column of it and ellipsizes.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
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
            ].where((s) => s.isNotEmpty).join(' - '),
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
                t.price > 0 ? formatMoney(t.price) : '-',
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
                'height, power draw and price - or add one with "New '
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
                fieldId: 'model_${key}_$_modelFieldRevision',
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
        // Said at the moment it becomes true — as the number is typed, on the
        // entry it was typed on — rather than only in the toolbar count. A
        // part number already in the catalog means this box is in the catalog
        // twice, and the offer to fix it belongs next to the field that
        // caused it.
        _duplicateWarning(provider, library, entry),
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
            // THE CATEGORIES THE APP ITSELF UNDERSTANDS. Typed text still
            // works — see [kTrackedCategories] on why the set is not closed —
            // but these are the spellings that make an entry price off the
            // base card, show up on the rack editor's parts list or land in
            // the cabling section, which are exactly the ones a typo silently
            // costs you.
            //
            // GROUPED, because the list is now three different kinds of
            // answer: the device kinds a room's config maps onto, the rack
            // parts, and the three billing buckets. Twenty-nine items in one
            // undivided column is a menu people give up on and type into
            // instead.
            PopupMenuButton<String>(
              key: ValueKey('cat_pick_$key'),
              tooltip: 'Use a category the app tracks',
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
                _categoryHeading(ctx, 'Tracked to a config section'),
                for (final c in kTrackedCategories)
                  PopupMenuItem(value: c, child: Text(c)),
                const PopupMenuDivider(),
                _categoryHeading(ctx, 'Rack parts'),
                for (final c in kRackItemCategories)
                  PopupMenuItem(value: c, child: Text(c)),
                const PopupMenuDivider(),
                _categoryHeading(ctx, 'Billed, not drawn'),
                for (final c in const [
                  kCategoryConsumable,
                  kCategoryCable,
                  kCategoryMisc,
                ])
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
              width: 140,
              child: LiveTextField(
                fieldId: 'lead_$key',
                // Blank is a real answer and NOT the same as 0 — see
                // [AvDeviceTemplate.leadTimeDays]. Blank means nobody has
                // asked the vendor; 0 means it is on the shelf. A schedule
                // that folded them together would make every product nobody
                // has checked look available tomorrow.
                initial: entry.leadTimeDays == null
                    ? ''
                    : '${entry.leadTimeDays}',
                label: 'Lead time',
                suffix: 'days',
                helper: entry.leadTimeDays == 0
                    ? 'in stock'
                    : 'blank = not asked',
                numeric: true,
                onChanged: (v) {
                  final typed = v.trim();
                  final days = typed.isEmpty ? null : int.tryParse(typed);
                  setState(
                    () => _apply(
                      entry.copyWith(
                        leadTimeDays: days,
                        clearLeadTime: days == null,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 140,
              child: LiveTextField(
                fieldId: 'life_$key',
                // How long the product lasts, which the replacement plan is
                // built from - see [AvDeviceTemplate.lifeYears]. Beside the
                // lead time because the two are the same kind of fact: when it
                // arrives, and when it has to be bought again.
                initial: entry.lifeYears == 0 ? '' : '${entry.lifeYears}',
                label: 'Life',
                suffix: 'yrs',
                helper: 'blank = $kDefaultEquipmentLifeYears',
                numeric: true,
                onChanged: (v) => setState(
                  () => _apply(
                    entry.copyWith(lifeYears: int.tryParse(v.trim()) ?? 0),
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
                        ? 'Minimum space around this part in a frame - leave '
                              'blank when it does not need any. The rails are '
                              'shaded light red on the rack elevation as a '
                              'warning; nothing is ever refused.'
                        : 'The rack elevation shades '
                              '${entry.clearanceAboveU} U above and '
                              '${entry.clearanceBelowU} U below every one of '
                              'these light red. A warning to whoever is '
                              'planning the frame, not a lock - anything can '
                              'still be placed there.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        // A FACT ABOUT THE PRODUCT, not about one room's drawing. A USB
        // capture stick or a passive splitter has no control interface
        // anywhere, and without this every room that draws one carries it
        // forever in the "devices without a control module" list — a warning
        // about something that can never be fixed is a warning people learn
        // to scroll past.
        CheckboxListTile(
          key: const ValueKey('catalog_never_controlled'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: entry.neverControlled,
          onChanged: (v) => setState(
            () => _apply(entry.copyWith(neverControlled: v ?? false)),
          ),
          title: const Text('Never in the room config'),
          subtitle: const Text(
            'Nothing can drive it - a USB interface, a passive splitter, a '
            'plate. It is still drawn, racked and quoted; it just stops being '
            'reported as a device waiting for a control module, and the '
            'config prefill leaves it alone.',
          ),
        ),
        // Retiring a part keeps everything it knows — ports, prices, rack
        // height — for the rooms that already have one, and takes it out of
        // the pickers that specify new work.
        CheckboxListTile(
          key: const ValueKey('catalog_retired'),
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
        // WHAT YOU WOULD BUY INSTEAD, asked at the one moment somebody knows
        // it: they are retiring the entry because a successor came out, and
        // the successor's name is the thing they have just been reading.
        //
        // Only when the entry is retired. A current product has no successor,
        // and a box asking for one on every entry in the catalog is a box
        // nobody fills in on the one entry where it matters.
        if (entry.retired) _replacedBy(context, entry),
        // A cable entry says what it carries. That is the whole hinge of the
        // cabling estimate: every run of this signal type on the AV flow is
        // quoted at this entry's price.
        if (entry.isCable) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
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
              const SizedBox(width: 12),
              // THE LENGTH IT IS BOUGHT IN. A room does not buy "HDMI cable",
              // it buys a 3 ft one and a 25 ft one at different prices — so a
              // type is broken down into an entry per length, and the estimate
              // puts every drawn run on the shortest one that reaches it.
              SizedBox(
                width: 130,
                child: LiveTextField(
                  fieldId: 'cablelen_$key',
                  initial: entry.cableLengthFt == 0
                      ? ''
                      : trimNumber(entry.cableLengthFt),
                  label: 'Length',
                  suffix: 'ft',
                  helper: 'blank = bulk',
                  numeric: true,
                  onChanged: (v) => setState(
                    () => _apply(
                      entry.copyWith(
                        cableLengthFt: double.tryParse(v.trim()) ?? 0,
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
                    _cableLengthNote(library, entry),
                    style: theme.textTheme.bodySmall,
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
                    'Passive - a speaker, a cable, a blanking plate.',
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
              'Connectors - ${entry.inputCount} in / ${entry.outputCount} out',
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
              'counted - it just cannot be cabled on the AV diagram.',
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
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
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
  ///
  /// THE ROOM THAT IS OPEN GETS ASKED ABOUT. Everything outside the catalog
  /// records a model by NAME — the boxes on the diagram, the items in the
  /// frames, the lines on the quote, the blocks in the config — so a rename
  /// that stopped at the entry left every one of them naming a part the
  /// catalog no longer had, and quietly unpriced with it. Asked rather than
  /// assumed: renaming an entry to correct a typo and renaming it because the
  /// part is now something else are the same keystrokes, and only the person
  /// typing knows which one this is.
  ///
  /// Silent when the open room does not use the part at all, which is most
  /// renames — the catalog is edited far more often than the room it is being
  /// edited beside.
  Future<void> _rename(
    AvDeviceLibrary library,
    AvDeviceTemplate entry,
    String proposed,
  ) async {
    final name = proposed.trim();
    if (name.isEmpty || name == entry.model) return;
    final clash = library.templateForModel(name);
    if (clash != null &&
        AvDeviceLibrary.normalizeModel(clash.model) !=
            AvDeviceLibrary.normalizeModel(entry.model)) {
      _snack(
        '"$name" is already in the catalog - rename or remove that one '
        'first.',
        error: true,
      );
      _revertModelField();
      return;
    }

    final provider = context.read<AppStateProvider>();
    final uses = provider.avUsesOfModel(entry.model);
    final total =
        uses.nodes + uses.rackItems + uses.costLines + uses.blocks;
    var follow = true;
    if (total > 0) {
      final answer = await _confirmRename(entry.model, name, uses);
      if (!mounted) return;
      if (answer == null) {
        _revertModelField();
        return;
      }
      follow = answer;
    }

    setState(
      () => _apply(entry.copyWith(model: name), previousModel: entry.model),
    );
    if (!follow) return;
    final moved = provider.renameAvCatalogModel(entry.model, name);
    final said = [
      if (moved.rackItems > 0) '${moved.rackItems} in the racks',
      if (moved.nodes > 0) '${moved.nodes} on the diagram',
      if (moved.blocks > 0)
        '${moved.blocks} config block${moved.blocks == 1 ? '' : 's'}',
      if (moved.costLines > 0)
        '${moved.costLines} quote line${moved.costLines == 1 ? '' : 's'}',
    ];
    if (said.isNotEmpty) {
      _snack('"${entry.model}" is now "$name", and so ${said.join(', ')}.');
    }
  }

  /// Asks whether the open room should follow a catalog rename. Null is
  /// cancel, and cancel means the entry is not renamed either — nothing has
  /// been written when this is asked.
  Future<bool?> _confirmRename(
    String from,
    String to,
    ({int nodes, int rackItems, int costLines, int blocks}) uses,
  ) {
    var follow = true;
    final using = [
      if (uses.rackItems > 0)
        '${uses.rackItems} item${uses.rackItems == 1 ? '' : 's'} in the racks',
      if (uses.nodes > 0)
        '${uses.nodes} box${uses.nodes == 1 ? '' : 'es'} on the diagram',
      if (uses.blocks > 0)
        '${uses.blocks} config block${uses.blocks == 1 ? '' : 's'}',
      if (uses.costLines > 0)
        '${uses.costLines} line${uses.costLines == 1 ? '' : 's'} on the quote',
    ].join(', ');

    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Rename "$from" to "$to"?'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The room that is open uses this part: $using.',
                  style: Theme.of(ctx).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const ValueKey('catalog_rename_follow'),
                  value: follow,
                  onChanged: (v) => setLocal(() => follow = v ?? false),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Rename them too'),
                  subtitle: Text(
                    follow
                        ? 'They become "$to", keeping their prices and their '
                              'places. Only the part of a name that WAS the '
                              'old model moves.'
                        : 'They keep the name "$from" - which nothing in the '
                              'catalog answers to any more, so they lose their '
                              'connectors and their price until somebody '
                              'repoints them.',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: follow ? null : Theme.of(ctx).colorScheme.error,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Other rooms are not touched either way - they are not open, '
                  'and each keeps its own record of what it was specified as.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(follow),
              child: const Text('Rename'),
            ),
          ],
        ),
      ),
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
          'next time the app starts - this only drops your edits to it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: snackErrorFill(context)),
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
                    ? 'A billable line rather than a box - a license, a '
                          'mount, a rental, a trip charge. Filed under '
                          '"$kCategoryMisc" with a price and no connectors, '
                          'and offered on the estimate\'s Other items.'
                    : copyFrom == null
                    ? 'Everything else - connectors, rack height, power, '
                          'price - is filled in on the next screen.'
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
      // No inlet and no connectors: a license does not draw power, and giving
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
                    'current search and category filter - narrow those first '
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

  // --- one part number, one entry -------------------------------------------

  /// The line under the part number field when this entry's number is on
  /// somebody else's entry too. Nothing at all when it isn't, which is the
  /// normal case and should take no space.
  Widget _duplicateWarning(
    AppStateProvider provider,
    AvDeviceLibrary library,
    AvDeviceTemplate entry,
  ) {
    final theme = Theme.of(context);
    final others = library.othersWithPartNumber(
      entry.partNumber,
      exceptModel: entry.model,
    );
    if (others.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(Icons.copy_all, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Part ${entry.partNumber.trim()} is also on '
              '${others.map((t) => t.model).join(', ')}. Two entries for one '
              'box drift apart - one gets the price, the other the '
              'connectors.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const ValueKey('entry_duplicate_merge'),
            onPressed: () => _showDuplicates(provider, partNumber: entry.partNumber),
            child: const Text('Merge...'),
          ),
        ],
      ),
    );
  }

  /// The review: every part number on more than one entry, each foldable into
  /// a single entry. [partNumber] opens straight onto one group, for the
  /// button beside the field.
  Future<void> _showDuplicates(
    AppStateProvider provider, {
    String partNumber = '',
  }) async {
    final merged = await showDialog<int>(
      context: context,
      builder: (ctx) => _DuplicatePartsDialog(
        library: provider.avDeviceLibrary,
        openPartNumber: partNumber,
      ),
    );
    if (merged == null || merged == 0 || !mounted) return;

    setState(() {
      _dirty = true;
      // The entry that was open may be one of the ones just merged away.
      if (_selected(provider.avDeviceLibrary) == null) _selectedKey = '';
    });
    provider.avDeviceLibraryChanged();
    _snack(
      'Merged $merged entr${merged == 1 ? 'y' : 'ies'} away - Save catalog to '
      'write it to disk.',
    );
  }

  /// The tidy-up: every category in the catalog, and what to refile it as.
  ///
  /// See [kTrackedCategories] for why this exists at all. The dialog hands
  /// back a category -> category map; applying it here rather than inside the
  /// dialog keeps the same shape as every other bulk edit on this tab — the
  /// catalog is changed in memory and Save is still what writes it.
  Future<void> _tidyCategories(AppStateProvider provider) async {
    final mapping = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => _TidyCategoriesDialog(library: provider.avDeviceLibrary),
    );
    if (mapping == null || mapping.isEmpty || !mounted) return;

    final moved = provider.avDeviceLibrary.retagCategories(mapping);
    if (moved == 0) {
      _snack('Nothing needed moving.');
      return;
    }
    setState(() {
      _dirty = true;
      // The filter may name a category that no longer has anything in it,
      // which would leave the list empty and nothing on screen saying why.
      if (_categoryFilter.isNotEmpty &&
          mapping.keys.any(
            (k) => k.toLowerCase() == _categoryFilter.toLowerCase(),
          )) {
        _categoryFilter = '';
      }
    });
    provider.avDeviceLibraryChanged();
    _snack(
      'Refiled $moved entr${moved == 1 ? 'y' : 'ies'} - Save catalog to write '
      'it to disk.',
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
        'Nothing to merge - ${path.basename(chosen)} says the same as your '
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
      '${path.basename(chosen)} - Save catalog to write it to disk.',
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

/// A heading inside the category menu, disabled so it cannot be chosen.
///
/// [PopupMenuDivider] alone says "these are two groups" and never says what
/// either group IS, which on a menu whose three halves mean genuinely
/// different things - a config section, a rack part, a billing bucket - is
/// the only thing worth saying.
PopupMenuItem<String> _categoryHeading(BuildContext context, String text) {
  final theme = Theme.of(context);
  return PopupMenuItem<String>(
    enabled: false,
    height: 30,
    child: Text(
      text.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// ============================================================================
///  TIDYING THE CATALOG'S VOCABULARY
/// ============================================================================
///  Every category the catalog actually uses, with what it holds and how much
///  of it, and a picker to refile the whole block. See [kTrackedCategories] for
///  what is being tidied onto and why it matters: a category the app does not
///  understand prices at nothing and groups under nothing, quietly, with a
///  perfectly sensible-looking word in the column.
///
///  IT SUGGESTS AND IT DOES NOT DECIDE. 'Matrix' is filled in as 'Switcher'
///  because every product ever filed under it is one. 'Audio' is left blank,
///  because it holds DSPs, amplifiers, microphones and loudspeakers, and an
///  app that guessed there would retag a $90 microphone as a $4,000 processor
///  with nothing on screen to say so. The three example models on every row are
///  there for exactly that judgment — they are what tells a reader at a glance
///  whether a family is one kind of box or four.
///
///  NOTHING IS APPLIED UNTIL "Refile" IS PRESSED, and nothing is written to
///  disk until Save. A retag of two hundred entries is the sort of edit people
///  want to look at before it happens.
class _TidyCategoriesDialog extends StatefulWidget {
  final AvDeviceLibrary library;

  const _TidyCategoriesDialog({required this.library});

  @override
  State<_TidyCategoriesDialog> createState() => _TidyCategoriesDialogState();
}

class _TidyCategoriesDialogState extends State<_TidyCategoriesDialog> {
  /// Source category (as spelled in the catalog) -> what to refile it as.
  /// A row not in here, or in here with a blank, is a row being left alone.
  final Map<String, String> _target = {};

  /// Categories the app already understands, folded away.
  ///
  /// On a catalog of a thousand parts most rows are already right, and a list
  /// that opens with eighteen finished lines above the six that need a
  /// decision buries the work. The finished ones are still reachable, because
  /// "refile every Projector as Display" is a legitimate thing to want.
  bool _showTracked = false;

  /// Fills in every suggestion the app is confident about, in one press.
  void _suggestAll(List<({String category, int count})> rows) {
    setState(() {
      for (final row in rows) {
        final suggestion = catalogCategorySuggestion(row.category);
        if (suggestion.isNotEmpty) _target[row.category] = suggestion;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final all = widget.library.categoryCounts;
    final untracked = [
      for (final row in all)
        if (!isTrackedCategory(row.category)) row,
    ];
    final tracked = [
      for (final row in all)
        if (isTrackedCategory(row.category)) row,
    ];
    final rows = _showTracked ? [...untracked, ...tracked] : untracked;

    // What would actually move, so the button can say so rather than reading
    // "Refile" over a form nobody has filled in.
    var moving = 0;
    for (final entry in _target.entries) {
      final to = entry.value.trim();
      if (to.isEmpty || to.toLowerCase() == entry.key.toLowerCase()) continue;
      for (final row in all) {
        if (row.category == entry.key) moving += row.count;
      }
    }

    final canSuggest = rows.any(
      (r) =>
          catalogCategorySuggestion(r.category).isNotEmpty &&
          (_target[r.category] ?? '').isEmpty,
    );

    return AlertDialog(
      key: const ValueKey('tidy_categories_dialog'),
      title: const Text('Tidy the catalog categories'),
      content: SizedBox(
        width: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              untracked.isEmpty
                  ? 'Every category in this catalog is one the app tracks. A '
                        'category on this list maps onto a room config section, '
                        'so a part filed under it prices off the base-cost card '
                        'and lands in the right group on the estimate.'
                  : '${untracked.length} categor'
                        '${untracked.length == 1 ? 'y is' : 'ies are'} words '
                        'the app does not track. Parts filed under them still '
                        'work, and they price off nothing and group under '
                        'nothing - a room with one on it falls back to what its '
                        'config section says it is. Pick what each one should '
                        'be, or leave it alone.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            // A WRAP, not a Row with a Spacer between them. A Spacer gives
            // way to nothing: once the two controls are wider than the dialog
            // - which they are the moment the type scales up - the Row paints
            // the chip off the edge under a yellow-and-black bar instead of
            // dropping it onto a second line.
            Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  key: const ValueKey('tidy_categories_suggest'),
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: const Text('Fill in what is obvious'),
                  onPressed: canSuggest ? () => _suggestAll(rows) : null,
                ),
                FilterChip(
                  key: const ValueKey('tidy_categories_show_tracked'),
                  label: Text('Show the ${tracked.length} already tracked'),
                  selected: _showTracked,
                  onSelected: (v) => setState(() => _showTracked = v),
                ),
              ],
            ),
            const Divider(height: 16),
            Flexible(
              child: rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'Nothing to tidy.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 12),
                      itemBuilder: (context, i) =>
                          _row(theme, muted, rows[i]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('tidy_categories_apply'),
          onPressed: moving == 0
              ? null
              : () => Navigator.of(context).pop(Map<String, String>.of(_target)),
          child: Text(
            moving == 0
                ? 'Refile'
                : 'Refile $moving part${moving == 1 ? '' : 's'}',
          ),
        ),
      ],
    );
  }

  Widget _row(
    ThemeData theme,
    Color muted,
    ({String category, int count}) row,
  ) {
    final examples = widget.library.examplesIn(row.category);
    final chosen = _target[row.category] ?? '';
    final suggestion = catalogCategorySuggestion(row.category);
    final isTracked = isTrackedCategory(row.category);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isTracked ? Icons.check_circle_outline : Icons.help_outline,
                    size: 16,
                    color: muted,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      row.category,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${row.count}',
                    style: theme.textTheme.labelMedium?.copyWith(color: muted),
                  ),
                ],
              ),
              // WHAT IS ACTUALLY IN IT. The only thing on the row that can
              // answer "is this family one kind of box", which is the question
              // the whole decision turns on.
              if (examples.isNotEmpty)
                Text(
                  examples.join(', ') + (row.count > examples.length ? '...' : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Icon(Icons.arrow_forward, size: 16, color: muted),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            key: ValueKey('tidy_target_${row.category}'),
            initialValue: chosen.isEmpty ? '' : chosen,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(
                  suggestion.isEmpty
                      ? 'Leave as is'
                      : 'Leave as is (suggested: $suggestion)',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final c in kWellKnownCategories)
                if (c.toLowerCase() != row.category.toLowerCase())
                  DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (v) => setState(() {
              if (v == null || v.isEmpty) {
                _target.remove(row.category);
              } else {
                _target[row.category] = v;
              }
            }),
          ),
        ),
      ],
    );
  }
}

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

// ---------------------------------------------------------------------------
//  DUPLICATE PART NUMBERS
// ---------------------------------------------------------------------------

/// Every part number that is on more than one catalog entry, each foldable
/// into a single entry.
///
/// The catalog is keyed by model NAME, and a name is whatever the page an
/// entry was imported from called it: "IN1608" off the price list and
/// "IN1608 xi" off the product site are one box in two entries, each holding
/// half the facts. The part number is the only thing that says so.
///
/// Merging is deliberately not automatic. Which name survives decides what
/// every existing room resolves against, and which side of a disagreement to
/// keep is a judgment — the price on one entry may be the current one or the
/// stale one, and only the person looking at it knows. So: pick the entry to
/// keep, tick what to take from the others, and the others go.
class _DuplicatePartsDialog extends StatefulWidget {
  final AvDeviceLibrary library;

  /// Opened from a specific entry's part number field: that group is shown
  /// first and already open.
  final String openPartNumber;

  const _DuplicatePartsDialog({
    required this.library,
    this.openPartNumber = '',
  });

  @override
  State<_DuplicatePartsDialog> createState() => _DuplicatePartsDialogState();
}

class _DuplicatePartsDialogState extends State<_DuplicatePartsDialog> {
  /// Part number (normalized) -> the model being kept.
  final Map<String, String> _keepers = {};

  /// Part number (normalized) -> the decisions for the entries it absorbs.
  final Map<String, List<DeviceDiff>> _diffs = {};

  /// Which groups are open. One group opens itself; a catalog with eleven of
  /// them opens none, because a wall of forty checkboxes is not a review.
  final Set<String> _open = {};

  int _merged = 0;

  @override
  void initState() {
    super.initState();
    final groups = widget.library.duplicateParts;
    final wanted = AvDeviceLibrary.normalizePartNumber(widget.openPartNumber);
    if (wanted.isNotEmpty) {
      _open.add(wanted);
    } else if (groups.length == 1) {
      _open.add(AvDeviceLibrary.normalizePartNumber(groups.first.partNumber));
    }
  }

  String _key(DuplicatePartGroup g) =>
      AvDeviceLibrary.normalizePartNumber(g.partNumber);

  /// The entry this group folds into — the first one that has a price, else
  /// the first with connectors, else simply the first. A guess, and the radio
  /// buttons are right there when it guesses wrong.
  AvDeviceTemplate _keeper(DuplicatePartGroup group) {
    final chosen = _keepers[_key(group)];
    if (chosen != null) {
      for (final t in group.entries) {
        if (AvDeviceLibrary.normalizeModel(t.model) == chosen) return t;
      }
    }
    return group.entries.firstWhere(
      (t) => t.price > 0 || t.educationPrice > 0,
      orElse: () => group.entries.firstWhere(
        (t) => t.ports.isNotEmpty,
        orElse: () => group.entries.first,
      ),
    );
  }

  List<DeviceDiff> _decisions(DuplicatePartGroup group) {
    final keeper = _keeper(group);
    return _diffs[_key(group)] ??= duplicateDiffs(
      keeper,
      group.entries.where(
        (t) =>
            AvDeviceLibrary.normalizeModel(t.model) !=
            AvDeviceLibrary.normalizeModel(keeper.model),
      ),
    );
  }

  void _chooseKeeper(DuplicatePartGroup group, String model) {
    setState(() {
      _keepers[_key(group)] = AvDeviceLibrary.normalizeModel(model);
      // The decisions were written against the old keeper and mean nothing
      // against the new one.
      _diffs.remove(_key(group));
    });
  }

  void _merge(DuplicatePartGroup group) {
    final keeper = _keeper(group);
    final removed = applyDuplicateMerge(
      widget.library,
      keeper,
      _decisions(group),
    );
    setState(() {
      _merged += removed;
      _keepers.remove(_key(group));
      _diffs.remove(_key(group));
      _open.remove(_key(group));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = [...widget.library.duplicateParts];
    final wanted = AvDeviceLibrary.normalizePartNumber(widget.openPartNumber);
    if (wanted.isNotEmpty) {
      groups.sort((a, b) {
        final aWanted = _key(a) == wanted ? 0 : 1;
        final bWanted = _key(b) == wanted ? 0 : 1;
        return aWanted.compareTo(bWanted);
      });
    }

    return AlertDialog(
      title: const Text('Duplicate part numbers'),
      content: SizedBox(
        width: math.min(860, MediaQuery.of(context).size.width - 120),
        height: math.min(620, MediaQuery.of(context).size.height - 180),
        child: groups.isEmpty
            ? Center(
                child: Text(
                  _merged == 0
                      ? 'Every part number in the catalog is on one entry.'
                      : 'All merged - every part number is on one entry now.',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            : ListView(
                children: [
                  Text(
                    'One product is in the catalog more than once, under more '
                    'than one model name. Pick the entry to keep, tick '
                    'anything worth taking from the others, and the others '
                    'are removed.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  for (final group in groups) _groupCard(theme, group),
                ],
              ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('dup_close'),
          onPressed: () => Navigator.of(context).pop(_merged),
          child: Text(_merged == 0 ? 'Close' : 'Done'),
        ),
      ],
    );
  }

  Widget _groupCard(ThemeData theme, DuplicatePartGroup group) {
    final key = _key(group);
    final open = _open.contains(key);
    final keeper = _keeper(group);
    final going = group.entries
        .where(
          (t) =>
              AvDeviceLibrary.normalizeModel(t.model) !=
              AvDeviceLibrary.normalizeModel(keeper.model),
        )
        .map((t) => t.model)
        .toList();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(Icons.copy_all, color: theme.colorScheme.error),
            title: Text(group.partNumber),
            subtitle: Text(
              '${group.entries.length} entries · ${group.modelList}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(open ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(
              () => open ? _open.remove(key) : _open.add(key),
            ),
          ),
          if (open) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Keep', style: theme.textTheme.labelLarge),
                  RadioGroup<String>(
                    groupValue: AvDeviceLibrary.normalizeModel(keeper.model),
                    onChanged: (v) {
                      if (v != null) _chooseKeeper(group, v);
                    },
                    child: Column(
                      children: [
                        for (final entry in group.entries)
                          RadioListTile<String>(
                            key: ValueKey('dup_keep_${key}_${entry.model}'),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: AvDeviceLibrary.normalizeModel(entry.model),
                            title: Text(entry.model),
                            subtitle: Text(_describe(entry)),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._decisionTiles(theme, group),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          going.isEmpty
                              ? ''
                              : 'Removes ${going.join(', ')} from the '
                                  'catalog. A room that names one of those '
                                  'loses its connectors and its price, so '
                                  'keep the name your rooms use.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.hintColor,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        key: ValueKey('dup_merge_$key'),
                        icon: const Icon(Icons.merge_type, size: 18),
                        label: Text('Merge into ${keeper.model}'),
                        onPressed: () => _merge(group),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The decisions for one group: every field an absorbed entry says
  /// something about, with the keeper's value beside it.
  List<Widget> _decisionTiles(ThemeData theme, DuplicatePartGroup group) {
    final decisions = _decisions(group);
    if (!decisions.any((d) => d.fields.isNotEmpty)) {
      return [
        Text(
          'The other entries say nothing this one does not - merging just '
          'removes them.',
          style: theme.textTheme.bodySmall,
        ),
      ];
    }
    return [
      Text('Take from the others', style: theme.textTheme.labelLarge),
      for (final diff in decisions)
        if (diff.fields.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(
              'from ${diff.model}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ),
          for (final f in diff.fields)
            CheckboxListTile(
              key: ValueKey('dup_field_${diff.model}_${f.field.name}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: f.selected,
              onChanged: (v) => setState(() => f.selected = v ?? false),
              title: Text(f.label, style: theme.textTheme.bodySmall),
              subtitle: Text(
                // Which way round the swap goes, in the order it happens.
                '${f.mine}  ->  ${f.theirs}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      f.selected ? theme.colorScheme.primary : theme.hintColor,
                ),
              ),
            ),
        ],
    ];
  }

  /// What an entry brings to the merge, in one line, so the radio buttons can
  /// be chosen between without opening each one.
  String _describe(AvDeviceTemplate t) {
    final bits = <String>[
      if (t.category.trim().isNotEmpty) t.category.trim(),
      if (t.price > 0) formatMoney(t.price),
      if (t.educationPrice > 0) '${formatMoney(t.educationPrice)} edu',
      if (t.ports.isNotEmpty) describePorts(t.ports),
      if (t.rackUnits > 0) '${t.rackUnits}U',
      if (t.custom) 'yours',
    ];
    return bits.isEmpty ? 'nothing recorded' : bits.join(' · ');
  }
}
