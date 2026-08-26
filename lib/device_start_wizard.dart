import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'control_prefill.dart';
import 'cost_estimate.dart' show formatMoney;

/// ============================================================================
///  START FROM THE COST ESTIMATOR
/// ============================================================================
///  Pick the room's equipment out of the catalog, with quantities and a
///  running total, before drawing anything.
///
///  This is how a room is actually specified — a list of parts and a number —
///  and the point of doing it here rather than in a spreadsheet is that the
///  list is not thrown away afterwards. Each pick becomes a box on the signal
///  flow canvas with the model's real connectors, a rack height and a draw, so
///  the same entries drive the cabling, the rack elevations and the estimate
///  without being typed a second time.
///
///  Devices go on the canvas AND into the room config's control blocks. That
///  second half used to be left for later, on the grounds that nobody had yet
///  said which of these boxes the processor talks to — but "later" meant the
///  room's own hardware counts read zero on the Wizard tab while the estimate
///  underneath listed twenty devices, and every one of them had to be told to
///  the config a second time by hand.
///
///  The catalog already answers the question that was being deferred. Each
///  entry carries a DEVICE TYPE, and that is what decides the family a block
///  lands in; the module library says which driver claims the model, and its
///  DEVICE_INFO says how the box is reached. What nothing claims — a speaker,
///  a mount, a passive plate — gets no block, which is the same answer it
///  would have got by hand. See [planControlSide] and [applyControlSide],
///  which the "add a device" dialog and the cost page's catalog picker go
///  through as well, so a room specified from any of the three is one room.
/// ============================================================================

/// One line of the wizard: a catalog model and how many of it.
///
/// The quantity box owns a controller rather than taking an `initialValue`,
/// because the count changes from BOTH ends — typed in the box, and bumped by
/// clicking the model again in the list. A field seeded once from its initial
/// value shows the first number forever, which is a count that quietly
/// disagrees with the total underneath it.
class _Pick {
  final AvDeviceTemplate template;
  final TextEditingController qtyController;
  int qty;

  _Pick(this.template)
    : qty = 1,
      qtyController = TextEditingController(text: '1');

  /// Sets the count from outside the box, keeping the box in step.
  void bump() {
    qty++;
    qtyController.text = '$qty';
  }

  void dispose() => qtyController.dispose();
}

/// What a run of the wizard did: boxes on the canvas, and the control blocks
/// built from them.
typedef DeviceStartResult = ({
  /// Devices placed on the signal flow canvas.
  int placed,

  /// Config blocks created for them, which is what the Wizard tab's hardware
  /// counts and the Devices tab read.
  int blocks,

  /// How many of those blocks have no python module yet — a device the room
  /// has and nothing can drive until somebody picks a driver.
  int withoutModule,
});

const DeviceStartResult _nothingPlaced =
    (placed: 0, blocks: 0, withoutModule: 0);

/// Runs the wizard. Everything is zero when it is canceled.
Future<DeviceStartResult> showDeviceStartWizard(
  BuildContext context,
  AppStateProvider provider,
) async {
  final result = await showDialog<DeviceStartResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const _DeviceStartWizard(),
  );
  return result ?? _nothingPlaced;
}

class _DeviceStartWizard extends StatefulWidget {
  const _DeviceStartWizard();

  @override
  State<_DeviceStartWizard> createState() => _DeviceStartWizardState();
}

class _DeviceStartWizardState extends State<_DeviceStartWizard> {
  final TextEditingController _search = TextEditingController();
  final List<_Pick> _picks = [];
  String _categoryFilter = '';

  /// Retired parts are out by default: this wizard specifies NEW work, and a
  /// discontinued model is the one thing you can be sure not to order.
  bool _showRetired = false;

  @override
  void dispose() {
    _search.dispose();
    for (final p in _picks) {
      p.dispose();
    }
    super.dispose();
  }

  /// What one of [t] costs for the running total: the catalog price, else the
  /// base cost for its category. Returns null when neither exists, so the
  /// total can say how much of the room it is NOT counting.
  double? _unitPrice(AppStateProvider provider, AvDeviceTemplate t) {
    final catalog = t.priceForTier(provider.pricingTier);
    if (catalog.price > 0) return catalog.price;
    final base = provider.baseCosts.priceFor(t.category, provider.pricingTier);
    return base.price > 0 ? base.price : null;
  }

  void _add(AvDeviceTemplate t) {
    final existing = _picks
        .where((p) => p.template.model == t.model)
        .firstOrNull;
    setState(() {
      if (existing != null) {
        existing.bump();
      } else {
        _picks.add(_Pick(t));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final library = provider.avDeviceLibrary;
    final currency = provider.avCost.currency;

    // Cable, consumables and rack hardware are bought by the meter and the
    // bag; they belong on the estimate, not as boxes on a signal flow. This
    // wizard is for the devices.
    final catalog = library.all
        .where((t) => _showRetired || !t.retired)
        .where((t) => !t.isCable && !t.isConsumable && !t.isRackHardware)
        .where(
          (t) =>
              _categoryFilter.isEmpty ||
              t.category.trim() == _categoryFilter,
        )
        .toList();
    final matches = searchCatalog(catalog, _search.text, limit: 400);

    double total = 0;
    int unpriced = 0;
    for (final p in _picks) {
      final unit = _unitPrice(provider, p.template);
      if (unit == null) {
        unpriced += p.qty;
      } else {
        total += unit * p.qty;
      }
    }

    return AlertDialog(
      title: const Text('Start from the cost estimator'),
      content: SizedBox(
        width: math.min(980, MediaQuery.of(context).size.width - 100),
        height: math.min(620, MediaQuery.of(context).size.height - 160),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pick what goes in the room. Everything chosen here is placed on '
              'the signal flow canvas with its real connectors, so it also '
              'fills the racks, the cabling and the estimate - and anything '
              'the processor drives gets its device block, on the driver the '
              'catalog names for it.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _catalogPane(library, matches)),
                  const VerticalDivider(width: 24),
                  Expanded(
                    flex: 2,
                    child: _pickedPane(provider, theme, currency),
                  ),
                ],
              ),
            ),
            const Divider(),
            Row(
              children: [
                Text(
                  '${_picks.fold(0, (m, p) => m + p.qty)} device'
                  '${_picks.fold(0, (m, p) => m + p.qty) == 1 ? '' : 's'}',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                if (unpriced > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      '$unpriced not priced',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                Text(
                  'Running total ${formatMoney(total, currency)}',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            if (provider.baseCosts.allUnset)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Models with no catalog price fall back to the base cost for '
                  'their category - none are set yet, so those lines show as '
                  'not priced. Set them once under "Base costs" on the Cost '
                  'tab.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_nothingPlaced),
          child: const Text('Skip'),
        ),
        ElevatedButton(
          onPressed: _picks.isEmpty
              ? null
              : () => Navigator.of(context).pop(_placeAll(provider)),
          child: const Text('Add to the room'),
        ),
      ],
    );
  }

  Widget _catalogPane(
    AvDeviceLibrary library,
    List<AvDeviceTemplate> matches,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Search the catalog',
                  hintText: 'model, part number or maker',
                  prefixIcon: Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('Retired'),
              selected: _showRetired,
              onSelected: (v) => setState(() => _showRetired = v),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                initialValue: _categoryFilter.isEmpty ? null : _categoryFilter,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('All')),
                  for (final c in library.categories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setState(() => _categoryFilter = v ?? ''),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: matches.isEmpty
              ? Center(
                  child: Text(
                    'Nothing matches. Add the model on the Catalog tab, or '
                    'clear the search and pick something close.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (ctx, i) {
                    final t = matches[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        t.model,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (t.manufacturer.isNotEmpty) t.manufacturer,
                          if (t.category.isNotEmpty) t.category,
                          '${t.inputCount} in / ${t.outputCount} out',
                          if (t.rackUnits > 0) '${t.rackUnits}U',
                          if (t.retired) 'RETIRED',
                          if (t.price > 0) '${formatMoney(t.price)} MSRP',
                          if (t.educationPrice > 0)
                            '${formatMoney(t.educationPrice)} edu',
                        ].join(' · '),
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.add, size: 18),
                      onTap: () => _add(t),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _pickedPane(
    AppStateProvider provider,
    ThemeData theme,
    String currency,
  ) {
    if (_picks.isEmpty) {
      return Center(
        child: Text(
          'Nothing picked yet. Click a model on the left to add it; click it '
          'again for a second one.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    return ListView(
      children: [
        for (final pick in _picks)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pick.template.model,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Builder(
                        builder: (context) {
                          final unit = _unitPrice(provider, pick.template);
                          final catalog =
                              pick.template.priceForTier(provider.pricingTier);
                          return Text(
                            unit == null
                                ? 'not priced'
                                : '${formatMoney(unit, currency)} each'
                                      '${catalog.price <= 0
                                          ? ' (base cost)'
                                          : catalog.fallback
                                          ? ' (other tier)'
                                          : ''}',
                            style: TextStyle(
                              fontSize: 11,
                              color: unit == null
                                  ? theme.colorScheme.error
                                  : theme.disabledColor,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 62,
                  child: TextField(
                    controller: pick.qtyController,
                    textAlign: TextAlign.right,
                    decoration: const InputDecoration(isDense: true),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    // The controller is left alone here: rewriting it on every
                    // keystroke is what moves the cursor to the front.
                    onChanged: (v) => setState(
                      () => pick.qty = math.max(1, int.tryParse(v) ?? 1),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'Remove',
                  onPressed: () => setState(() {
                    _picks.remove(pick);
                    pick.dispose();
                  }),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Puts every pick on the canvas, laid out in signal-flow reading order:
  /// sources on the left, switching in the middle, destinations on the right,
  /// the same columns the auto-arrange uses — and then builds the control side
  /// of what was just placed.
  DeviceStartResult _placeAll(AppStateProvider provider) {
    int placed = 0;
    // The ids the boxes actually landed on, so the config blocks are built for
    // exactly these and not for anything already on the canvas.
    final ids = <String>[];
    // Where the next box in each column goes. Kept per column so a room with
    // eight sources and one switcher doesn't come out as one long diagonal.
    final nextY = <int, double>{};

    for (final pick in _picks) {
      for (int i = 0; i < pick.qty; i++) {
        final t = pick.template;
        final column = _columnForCategory(t.category);
        final y = nextY[column] ?? 60.0;
        final node = AvNode(
          id: '',
          // Numbered when there is more than one, because "Display" twice on
          // a diagram is two boxes nobody can tell apart in the pack list.
          label: pick.qty == 1 ? t.model : '${t.model} ${i + 1}',
          model: t.model,
          pos: Offset(40 + column * 340.0, y),
          ports: withPowerInlet(t.ports, t.powerInput),
          rackUnits: t.rackUnits,
          powerWatts: t.powerWatts,
          btuPerHour: t.btuPerHour,
          powerSource: powerSourceForInput(t.powerInput),
        );
        final stored = provider.addAvNode(node);
        nextY[column] = y + stored.height + 30;
        ids.add(stored.id);
        placed++;
      }
    }
    final control = _buildControlSide(provider, ids);
    return (
      placed: placed,
      blocks: control.blocks,
      withoutModule: control.withoutModule,
    );
  }

  /// The config blocks for the boxes just placed.
  ///
  /// The counts are RAISED rather than set, and the numbering runs past
  /// whatever the room already has, so a wizard run on a room built from a
  /// room-type preset adds to that preset's devices instead of renumbering
  /// them. Nothing is created for a room with no config open, or for a part no
  /// device family claims.
  ({int blocks, int withoutModule}) _buildControlSide(
    AppStateProvider provider,
    List<String> ids,
  ) {
    if (ids.isEmpty) return (blocks: 0, withoutModule: 0);
    if (provider.roomConfig['SYSTEM_SETUP'] is! Map) {
      return (blocks: 0, withoutModule: 0);
    }
    final plan = planControlSide(provider, nodeIds: ids);
    if (plan.creatable.isEmpty) return (blocks: 0, withoutModule: 0);
    final result = applyControlSide(provider, plan);
    return (blocks: result.created, withoutModule: result.withoutModule);
  }

  /// Reading order by category, matching the AV tab's own column rule so a
  /// wizard-built room and a config-seeded one look alike.
  static int _columnForCategory(String category) {
    switch (category.trim().toLowerCase()) {
      case 'switcher':
        return 1;
      case 'dsp':
      case 'amplifier':
      case 'recorder / streamer':
        return 2;
      case 'projector':
      case 'display':
      case 'screen':
      case 'speaker':
        return 3;
      default:
        return 0;
    }
  }
}
