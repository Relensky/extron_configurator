import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'contrast.dart';
import 'equipment_lifecycle.dart';
import 'project_estimate.dart' show roomCodeFromConfig;
import 'stepped_date_picker.dart';

/// ============================================================================
///  THE ROOM'S LIFECYCLE TAB
/// ============================================================================
///  What is in this room, how old it is, and the year each of it falls due.
///
///  Every other tab is about the room being BUILT. This is the only one about
///  the room as it stands — which is the state a refresh budget is written
///  against, and the state that was previously only recorded on a spreadsheet
///  somebody maintained by hand.
///
///  IT IS A SURVEY SCREEN AS MUCH AS A REPORT. The whole thing derives from one
///  field per box ([AvNode.installedOn]), and on a room nobody has surveyed
///  every one of them is blank. So the dates are editable HERE, in a list, one
///  press each — walking a room and typing eleven dates into eleven separate
///  device dialogs is the version of this feature nobody would ever finish.
///
///  THE COLOURS ARE THE RYG SHEET'S COLOURS, and they are backed by text on
///  every row. A red/amber/green chip that is only a colour is a chip that says
///  nothing to somebody printing in mono or reading with a colour deficiency,
///  and this is a document that gets printed.
/// ============================================================================

class LifecycleView extends StatelessWidget {
  const LifecycleView({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final model = buildAvFlowModel(provider);
    final room = buildRoomLifecycle(
      model: model,
      roomName: roomCodeFromConfig(provider.roomConfig),
      library: provider.avDeviceLibrary,
      tier: provider.pricingTier,
    );

    if (room.items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nothing to age yet.\n\n'
            'The replacement plan is built from the equipment on the AV Flow '
            'tab - add devices there and record when each of them went in.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Summary(room: room, currency: provider.currencySymbol),
        _RoomActions(room: room),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: room.items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _ItemRow(
              item: room.items[i],
              currency: provider.currencySymbol,
            ),
          ),
        ),
      ],
    );
  }
}

/// The one thing this screen does to the whole room at once.
///
/// A room is usually dated ONCE — everything in a room refreshed in 2018 went
/// in that summer, one crew, one week — so the honest record and the fastest
/// one are the same thing. See [AppStateProvider.setRoomInstalledOn].
class _RoomActions extends StatelessWidget {
  final RoomLifecycle room;

  const _RoomActions({required this.room});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final undated = room.undated;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          FilledButton.tonalIcon(
            key: const ValueKey('lifecycle_date_room'),
            onPressed: () => showRoomInstallDateDialog(context),
            icon: const Icon(Icons.event_repeat, size: 18),
            label: const Text('Date the whole room…'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              undated == 0
                  ? 'Every item has a date. Use this to move them all to a new '
                      'one after a refresh.'
                  : '$undated of ${room.items.length} item'
                      '${room.items.length == 1 ? '' : 's'} still have no '
                      'date. One press sets them all.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: undated == 0
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.tertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Which boxes a room-wide date lands on.
enum RoomInstallDateScope {
  /// Finish the survey: only the ones nobody has dated.
  undatedOnly,

  /// The room was redone: every item moves to the new date.
  everything,
}

/// Asks for one date and who it applies to, then applies it.
///
/// THE SCOPE IS A CHOICE, NOT A DEFAULT, because the two answers destroy
/// different things. "Only the undated ones" finishes a survey and cannot lose
/// anything. "Everything" is right after a refresh and DOES overwrite — a room
/// where somebody recorded the projector's real date last month would lose it.
/// Undo takes the whole sweep back in one press either way, but a bulk edit
/// that guessed which of those you meant is one people press once.
Future<void> showRoomInstallDateDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _RoomInstallDateDialog(),
);

class _RoomInstallDateDialog extends StatefulWidget {
  const _RoomInstallDateDialog();

  @override
  State<_RoomInstallDateDialog> createState() => _RoomInstallDateDialogState();
}

class _RoomInstallDateDialogState extends State<_RoomInstallDateDialog> {
  DateTime _date = DateTime.now();
  RoomInstallDateScope _scope = RoomInstallDateScope.undatedOnly;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _date = DateTime(now.year, now.month, now.day);
  }

  bool get _onlyUndated => _scope == RoomInstallDateScope.undatedOnly;

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showSteppedDatePicker(
      context,
      initialDate: _date,
      firstDate: DateTime(now.year - 25, 1, 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: 'When did this room go in?',
    );
    if (picked == null) return;
    setState(() => _date = picked);
  }

  void _apply() {
    final provider = context.read<AppStateProvider>();
    final changed = provider.setRoomInstalledOn(
      _date,
      onlyUndated: _onlyUndated,
    );
    Navigator.of(context).pop();
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        content: Text(
          changed == 0
              ? 'Nothing to change - every item already carries that date.'
              : '$changed item${changed == 1 ? '' : 's'} dated '
                  '${formatEquipmentDate(_date)}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final undated = provider.roomInstallDateCount(onlyUndated: true);
    final all = provider.roomInstallDateCount();
    final target = _onlyUndated ? undated : all;

    return AlertDialog(
      key: const ValueKey('room_install_date_dialog'),
      title: const Text('Date the whole room'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Everything in a room that was refreshed together went in the '
              'same week. Set that date once here rather than eleven times '
              'down the list.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const ValueKey('room_install_date_pick'),
              onPressed: _pickDate,
              icon: const Icon(Icons.event_available, size: 18),
              label: Text('Installed ${formatEquipmentDate(_date)}'),
            ),
            const SizedBox(height: 16),
            RadioGroup<RoomInstallDateScope>(
              groupValue: _scope,
              onChanged: (v) =>
                  setState(() => _scope = v ?? RoomInstallDateScope.undatedOnly),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<RoomInstallDateScope>(
                    key: const ValueKey('room_install_scope_undated'),
                    value: RoomInstallDateScope.undatedOnly,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Only the $undated with no date yet',
                      style: theme.textTheme.bodyMedium,
                    ),
                    subtitle: Text(
                      'Finishes the survey. Nothing already recorded is '
                      'touched.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  RadioListTile<RoomInstallDateScope>(
                    key: const ValueKey('room_install_scope_all'),
                    value: RoomInstallDateScope.everything,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'All $all items',
                      style: theme.textTheme.bodyMedium,
                    ),
                    subtitle: Text(
                      'The room was redone. This OVERWRITES dates that are '
                      'already there - one press of Undo takes it back.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('room_install_date_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('room_install_date_apply'),
          // Nothing to change is a disabled button rather than a press that
          // appears to do nothing.
          onPressed: target == 0 ? null : _apply,
          child: Text(
            target == 0
                ? 'Nothing to date'
                : 'Date $target item${target == 1 ? '' : 's'}',
          ),
        ),
      ],
    );
  }
}

/// THE RAMP, AS COLOUR.
///
/// Green, yellow, amber, orange, red, deeper red — the six steps of
/// [EquipmentTiming], which is the whole point of grading the warning band: a
/// projector with three years left and one with three months left are both
/// "due soon", and painting them the same amber says they are the same
/// problem.
///
/// FIXED HUES, NOT SCHEME ROLES. These mean what a traffic light means, and
/// this app's accent is a colour somebody picked out of a wheel — a warning
/// band that turned violet with the theme would stop being a warning band and
/// would stop matching the key beside it and the sheet it is printed on. Only
/// "past its life" defers to the scheme, whose error colour is red on every
/// theme here, so the sheet's red and the app's red are one red.
const Map<EquipmentTiming, Color> kEquipmentTimingHues = {
  EquipmentTiming.inService: Color(0xFF2E9E4F),
  EquipmentTiming.watch: Color(0xFFF2C200),
  EquipmentTiming.approaching: Color(0xFFF29D00),
  EquipmentTiming.imminent: Color(0xFFEF6C00),
  EquipmentTiming.overdue: Color(0xFFD93025),
  EquipmentTiming.wellOverdue: Color(0xFFA31515),
};

/// The colour one step of the ramp reads in, as TEXT or as an icon.
///
/// Moved along its own lightness until it clears [kContrastStrong] on the
/// surface it is painted on — so yellow on a white card is a darkened yellow
/// rather than an unreadable one, and the same yellow on a dark card is
/// lightened instead. It stays yellow either way, which is what [legibleTone]
/// is for.
Color equipmentTimingColor(BuildContext context, EquipmentTiming timing) {
  final theme = Theme.of(context);
  final ground = theme.cardColor;
  if (timing == EquipmentTiming.unknown) {
    return theme.colorScheme.onSurfaceVariant;
  }
  if (timing == EquipmentTiming.overdue) {
    return errorTextOn(theme.colorScheme, ground);
  }
  return legibleTone(kEquipmentTimingHues[timing]!, ground);
}

/// The same step as a FILL — a cell on the year grid, the band down the side
/// of a row, a swatch in the key.
///
/// The raw hue at low alpha rather than [equipmentTimingColor]: a fill carries
/// no text of its own, so it keeps the pure colour the key names, and the
/// legible tone goes on top of it.
Color equipmentTimingFill(
  BuildContext context,
  EquipmentTiming timing, {
  double alpha = 0.20,
}) {
  if (timing == EquipmentTiming.unknown) {
    return Theme.of(context)
        .colorScheme
        .onSurfaceVariant
        .withValues(alpha: alpha * 0.5);
  }
  return kEquipmentTimingHues[timing]!.withValues(alpha: alpha);
}

IconData equipmentTimingIcon(EquipmentTiming timing) => switch (timing) {
      EquipmentTiming.wellOverdue => Icons.report_gmailerrorred,
      EquipmentTiming.overdue => Icons.error_outline,
      EquipmentTiming.imminent => Icons.alarm,
      EquipmentTiming.approaching => Icons.schedule,
      EquipmentTiming.watch => Icons.hourglass_bottom,
      EquipmentTiming.inService => Icons.check_circle_outline,
      EquipmentTiming.unknown => Icons.help_outline,
    };

/// The step a whole CONDITION reads as, for the places that only have the
/// coarse answer: a count of "due soon" items has no single position on the
/// ramp, so it takes the middle of the band.
EquipmentTiming timingOfCondition(EquipmentCondition condition) =>
    switch (condition) {
      EquipmentCondition.overdue => EquipmentTiming.overdue,
      EquipmentCondition.ageing => EquipmentTiming.approaching,
      EquipmentCondition.good => EquipmentTiming.inService,
      EquipmentCondition.unknown => EquipmentTiming.unknown,
    };

/// The colour one condition reads in.
///
/// Kept in one place because the chip on a row, the band in the header and the
/// project's own roll-up all have to agree — three shades of "past its life"
/// would read as three different states.
Color equipmentConditionColor(
  BuildContext context,
  EquipmentCondition condition,
) => equipmentTimingColor(context, timingOfCondition(condition));

IconData equipmentConditionIcon(EquipmentCondition condition) =>
    equipmentTimingIcon(timingOfCondition(condition));

/// The key to the ramp, which is what makes six shades readable as anything
/// other than decoration.
///
/// Every step is a swatch AND a word, because a colour on its own says nothing
/// to somebody printing in mono or reading with a colour deficiency — the same
/// bargain every coloured thing on this screen makes.
class EquipmentTimingKey extends StatelessWidget {
  const EquipmentTimingKey({super.key});

  /// The ramp in order, greenest first. Unknown is left off: it is not a step
  /// on the way to anything, it is a date nobody has entered.
  static const List<EquipmentTiming> ramp = [
    EquipmentTiming.inService,
    EquipmentTiming.watch,
    EquipmentTiming.approaching,
    EquipmentTiming.imminent,
    EquipmentTiming.overdue,
    EquipmentTiming.wellOverdue,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (final timing in ramp)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: equipmentTimingFill(context, timing, alpha: 0.85),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                kEquipmentTimingLabels[timing]!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// The header strip: what the room reads as, HOW MANY ITEMS have to be
/// replaced, and what they cost.
///
/// THE COUNT AND THE MONEY TOGETHER, on every band. This strip is read while
/// the dates below it are being edited — a life shortened on the projector, a
/// date corrected on a display — and the question being asked on every one of
/// those edits is what it does to the job. 'Two items' does not answer that
/// and a bare figure does not either; the pair does, and it moves with the
/// list because it is derived from the same items the list is.
class _Summary extends StatelessWidget {
  final RoomLifecycle room;
  final String currency;

  const _Summary({required this.room, required this.currency});

  @override
  Widget build(BuildContext context) {
    final timing = room.timing;
    final headline = equipmentTimingColor(context, timing);
    final overdue = room.countOf(EquipmentCondition.overdue) > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 20,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(equipmentTimingIcon(timing), color: headline),
                  const SizedBox(width: 8),
                  Text(
                    kEquipmentTimingLabels[timing]!,
                    key: const ValueKey('lifecycle_room_condition'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: headline,
                    ),
                  ),
                ],
              ),
              // The figure a refresh request is written from: everything past
              // its life plus everything inside the planning window, counted
              // and priced in one place.
              if (room.toReplaceCount > 0)
                _Stat(
                  key: const ValueKey('lifecycle_to_replace'),
                  label: 'To replace',
                  value: formatEquipmentBand(
                    room.toReplaceCount,
                    room.toReplaceCost,
                    currency,
                  ),
                  color: equipmentConditionColor(
                    context,
                    overdue
                        ? EquipmentCondition.overdue
                        : EquipmentCondition.ageing,
                  ),
                ),
              for (final c in kEquipmentConditionSeverity)
                if (room.countOf(c) > 0)
                  _Stat(
                    key: ValueKey('lifecycle_room_band_${c.name}'),
                    label: kEquipmentConditionLabels[c]!,
                    value: formatEquipmentBand(
                      room.countOf(c),
                      room.costOf(c),
                      currency,
                    ),
                    color: equipmentConditionColor(context, c),
                  ),
              _Stat(
                label: 'Room last done',
                value: room.oldestInstall == null
                    ? 'not recorded'
                    : '${room.oldestInstall!.year}',
              ),
              _Stat(
                label: 'First replacement due',
                value: room.firstDueYear == null
                    ? 'not recorded'
                    : '${room.firstDueYear}',
              ),
              _Stat(
                label: 'Full refresh',
                value: room.refreshCost <= 0
                    ? 'nothing priced'
                    : formatLifecycleMoney(room.refreshCost, currency),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TimingBar(room: room, currency: currency),
          const SizedBox(height: 8),
          const EquipmentTimingKey(),
        ],
      ),
    );
  }
}

/// The room as one bar: a slice per band, coloured by where it sits on the
/// ramp, worst first.
///
/// BANDS, NOT A GRADIENT. Each slice is a real set of items and says how many
/// and how much when it is hovered, so the bar is a picture of the list under
/// it rather than an impression of one. The line of words below it says the
/// same thing for the print and for anybody who would rather read it than
/// hover it — which is the same bargain the colours themselves make.
class _TimingBar extends StatelessWidget {
  final RoomLifecycle room;
  final String currency;

  const _TimingBar({required this.room, required this.currency});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bands = [
      for (final t in kEquipmentTimingSeverity)
        if (room.countOfTiming(t) > 0)
          (
            timing: t,
            count: room.countOfTiming(t),
            cost: room.costOfTiming(t),
          ),
    ];
    if (bands.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 12,
            child: Row(
              children: [
                for (final band in bands)
                  Expanded(
                    flex: band.count,
                    child: Tooltip(
                      message: '${kEquipmentTimingLabels[band.timing]!}: '
                          '${formatEquipmentBand(
                        band.count,
                        band.cost,
                        currency,
                      )}',
                      child: Container(
                        key: ValueKey('lifecycle_bar_${band.timing.name}'),
                        margin: const EdgeInsets.only(right: 1),
                        color: equipmentTimingFill(
                          context,
                          band.timing,
                          alpha: 0.85,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          [
            for (final band in bands)
              '${kEquipmentTimingLabels[band.timing]!} '
                  '${formatEquipmentBand(band.count, band.cost, currency)}',
          ].join('  ·  '),
          key: const ValueKey('lifecycle_bar_summary'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Stat({
    super.key,
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// One position: what it is, how old, and the date field that drives all of it.
class _ItemRow extends StatelessWidget {
  final EquipmentLife item;
  final String currency;

  const _ItemRow({required this.item, required this.currency});

  Future<void> _pickInstall(BuildContext context) async {
    final provider = context.read<AppStateProvider>();
    final now = DateTime.now();
    final picked = await showSteppedDatePicker(
      context,
      initialDate: item.installedOn ?? now,
      firstDate: DateTime(now.year - 25, 1, 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: 'When did ${item.node.label} go in?',
    );
    if (picked == null) return;
    provider.setAvNodeInstalledOn(item.node.id, picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timing = item.timing;
    final color = equipmentTimingColor(context, timing);
    final detail = [
      if (item.node.model.isNotEmpty) item.node.model,
      if (item.locationName.isNotEmpty) item.locationName,
      '${formatEquipmentAge(item.ageYears)} old',
      formatEquipmentDue(item),
      'life ${item.lifeYears} yrs',
      if (item.hasHistory) 'replaced ${item.node.swaps.length}x before',
    ].join('  ·  ');

    return Container(
      // The row's own band, down the edge a list is scanned along. The wash
      // behind it is faint enough that the text on top of it is the text
      // everywhere else on this screen; the edge is where the colour is.
      decoration: BoxDecoration(
        color: equipmentTimingFill(context, timing, alpha: 0.10),
        border: Border(
          left: BorderSide(
            color: equipmentTimingFill(context, timing, alpha: 0.9),
            width: 4,
          ),
        ),
      ),
      child: ListTile(
        key: ValueKey('lifecycle_item_${item.node.id}'),
        leading: Tooltip(
          message: kEquipmentTimingLabels[timing]!,
          child: Icon(equipmentTimingIcon(timing), color: color),
        ),
        title: Text(
          item.node.label,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text.rich(
          TextSpan(
            children: [
              // The step in words, in its own colour, at the front of the
              // line: the colour says which of the six it is at a glance and
              // the word says it to a mono print and to a reader who cannot
              // tell the amber from the orange.
              TextSpan(
                text: kEquipmentTimingLabels[timing]!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(text: '  ·  $detail'),
            ],
          ),
          style: theme.textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.replacementCost > 0)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  formatLifecycleMoney(item.replacementCost, currency),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            // The one control on the row, because the date is the one fact
            // this screen exists to collect. Everything else about the box is
            // edited where the box is drawn.
            OutlinedButton.icon(
              key: ValueKey('lifecycle_install_${item.node.id}'),
              onPressed: () => _pickInstall(context),
              icon: const Icon(Icons.event_available, size: 16),
              label: Text(
                item.installedOn == null
                    ? 'Set install date'
                    : formatEquipmentDate(item.installedOn!),
              ),
            ),
            if (item.installedOn != null)
              IconButton(
                key: ValueKey('lifecycle_install_clear_${item.node.id}'),
                tooltip: 'Nobody knows when this went in',
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => context
                    .read<AppStateProvider>()
                    .setAvNodeInstalledOn(item.node.id, null),
              ),
          ],
        ),
      ),
    );
  }
}
