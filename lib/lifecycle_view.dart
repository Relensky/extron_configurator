import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'contrast.dart';
import 'equipment_lifecycle.dart';
import 'project_lifecycle_view.dart' show LifecycleYearGrid;
import 'pinned_grid.dart' show gridMetric;
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

class LifecycleView extends StatefulWidget {
  const LifecycleView({super.key});

  @override
  State<LifecycleView> createState() => _LifecycleViewState();
}

class _LifecycleViewState extends State<LifecycleView> {
  /// Whether the positions taken off the refresh cycle are on screen.
  ///
  /// OFF BY DEFAULT, which is the whole point of taking one off: a mount and a
  /// pole among nine live positions are four rows nobody reads and two more
  /// undated items on the count. HELD ON THE SCREEN rather than in the file,
  /// because it is a way of looking at the room and not a fact about it — and
  /// a room that opened with them showing because somebody once looked would
  /// be a plan that reads differently for two people.
  bool _showNever = false;

  /// ONE SCROLL REGION FOR THE WHOLE TAB, and the bar that says so.
  ///
  /// The strip at the top used to be nailed in place above a list that
  /// scrolled under it. On a machine at 150% that strip is half the window -
  /// six bands, a bar and a key, all at the reader's type size - and the list
  /// it was pinned above had nothing left to stand in. It scrolls away with
  /// everything else now, and there is one thumb on the screen rather than a
  /// list that moves under a header that cannot.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final model = buildAvFlowModel(provider);
    final room = buildRoomLifecycle(
      model: model,
      roomName: roomCodeFromConfig(provider.roomConfig),
      library: provider.avDeviceLibrary,
      baseCosts: provider.baseCosts,
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

    // The plan, and then — only when asked for — the positions held off it.
    final rows = <({EquipmentLife item, bool never})>[
      for (final i in room.items) (item: i, never: false),
      if (_showNever)
        for (final i in room.neverReplaced) (item: i, never: true),
    ];

    return Scrollbar(
      controller: _scroll,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: _Summary(room: room, currency: provider.currencySymbol),
          ),
          SliverToBoxAdapter(
            child: _RoomActions(
              room: room,
              showNever: _showNever,
              onShowNever: () => setState(() => _showNever = !_showNever),
            ),
          ),
          // THE SAME CALENDAR THE PROJECT DRAWS, FOR THIS ROOM.
          //
          // This tab answered "how old is everything in here" as a list of
          // positions, and left "what year does it land, in how many tranches,
          // and what does each cost" to the Project tab - which is a different
          // screen, on a job the room may not even be on. They are the same
          // facts about the same room, and this is where somebody is standing
          // when the question comes up.
          //
          // A building of ONE. Nothing in the grid cares how many rooms it is
          // given, and handing it the room this way means the two screens can
          // never draw the same room two different ways.
          SliverToBoxAdapter(
            child: LifecycleYearGrid(
              // The key is already on the strip above this, under the timing
              // bar it explains. Twice on one page reads as two keys.
              showKey: false,
              building: BuildingLifecycle(
                rooms: [room],
                asOf: room.asOf,
                currency: provider.currencySymbol,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          if (rows.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Every item in this room is off the refresh cycle.\n\n'
                  'Nothing here falls due, which is a real answer for a '
                  'room of brackets and plates - and the toggle above '
                  'shows them.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          else
            SliverList.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _ItemRow(
                item: rows[i].item,
                currency: provider.currencySymbol,
                never: rows[i].never,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

/// Which record a life is written onto.
enum EquipmentLifeScope {
  /// This box, in this room. Somebody looked at THIS projector.
  position,

  /// The product, in the catalog. Follows the model into every other room and
  /// into next year's job.
  catalog,
}

/// Asks how long a position lasts, and which record to keep the answer on.
///
/// THE SECOND HALF OF THE DUE DATE. The plan is the install date plus the
/// life, and until now only the date could be edited from the list: the life
/// came off the catalog page, which is a different screen, a different
/// document, and a trip nobody makes while walking a room. A five-year life on
/// a projector that runs eight hours a day is exactly the sort of thing that
/// gets noticed standing in front of it.
Future<void> showEquipmentLifeDialog(
  BuildContext context,
  EquipmentLife item,
) => showDialog<void>(
  context: context,
  builder: (_) => _EquipmentLifeDialog(item: item),
);

class _EquipmentLifeDialog extends StatefulWidget {
  final EquipmentLife item;

  const _EquipmentLifeDialog({required this.item});

  @override
  State<_EquipmentLifeDialog> createState() => _EquipmentLifeDialogState();
}

class _EquipmentLifeDialogState extends State<_EquipmentLifeDialog> {
  late final TextEditingController _years = TextEditingController(
    text: '${widget.item.lifeYears}',
  );
  EquipmentLifeScope _scope = EquipmentLifeScope.position;

  @override
  void dispose() {
    _years.dispose();
    super.dispose();
  }

  String get _model => widget.item.node.model.trim();

  /// What was typed, or null when it is not a life.
  int? get _typed {
    final text = _years.text.trim();
    if (text.isEmpty) return 0;
    final years = int.tryParse(text);
    if (years == null || years < 0 || years > 100) return null;
    return years;
  }

  Future<void> _apply() async {
    final years = _typed;
    if (years == null) return;
    final provider = context.read<AppStateProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final id = widget.item.node.id;

    if (_scope == EquipmentLifeScope.position) {
      provider.setAvNodeLifeYears(id, years);
      if (mounted) Navigator.of(context).pop();
      showTimedSnackBar(
        messenger,
        SnackBar(
          content: Text(
            years == 0
                ? '${widget.item.node.label} follows the catalog again.'
                : '${widget.item.node.label} is held to $years years.',
          ),
        ),
      );
      return;
    }

    final result = await provider.setModelLifeYears(_model, years);
    // A life typed on THIS box would shadow the one just written onto the
    // product, which is the opposite of what "keep it with the model" means.
    if (result.ok) provider.setAvNodeLifeYears(id, 0);
    if (!mounted) return;
    Navigator.of(context).pop();
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(result.message),
        backgroundColor: result.ok ? null : snackErrorFill(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppStateProvider>();
    final item = widget.item;
    final typed = _typed;

    // The catalog rung is only offered when there is an entry to write onto.
    // Creating one from here would put a model and a life in the catalog with
    // no maker, no part number and no price behind them - see
    // [AppStateProvider.setModelLifeYears].
    final catalogEntry = _model.isEmpty
        ? null
        : provider.avDeviceLibrary.templateForModel(_model);

    return AlertDialog(
      key: const ValueKey('equipment_life_dialog'),
      title: const Text('How long does this last?'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${item.node.label} is on a ${item.lifeYears}-year life '
              '(${kEquipmentLifeSourceLabels[item.lifeSource]}). The date it '
              'falls due is the day it went in plus this.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('equipment_life_years'),
              controller: _years,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Life',
                suffixText: 'yrs',
                border: const OutlineInputBorder(),
                helperText: 'blank or 0 = follow the catalog '
                    '($kDefaultEquipmentLifeYears by default)',
                errorText: typed == null ? 'A whole number of years, up to 100'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            RadioGroup<EquipmentLifeScope>(
              groupValue: _scope,
              onChanged: (v) =>
                  setState(() => _scope = v ?? EquipmentLifeScope.position),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<EquipmentLifeScope>(
                    key: const ValueKey('equipment_life_scope_position'),
                    value: EquipmentLifeScope.position,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'This one only',
                      style: theme.textTheme.bodyMedium,
                    ),
                    subtitle: Text(
                      'A fact about this box in this room - it runs longer '
                      'hours, it was used, or refurbished.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  RadioListTile<EquipmentLifeScope>(
                    key: const ValueKey('equipment_life_scope_catalog'),
                    value: EquipmentLifeScope.catalog,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    // Nothing to write onto is a disabled choice with the
                    // reason under it, rather than a choice that fails when it
                    // is pressed.
                    enabled: catalogEntry != null,
                    title: Text(
                      catalogEntry == null
                          ? 'Keep it with the model'
                          : 'Keep it with $_model',
                      style: theme.textTheme.bodyMedium,
                    ),
                    subtitle: Text(
                      catalogEntry == null
                          ? (_model.isEmpty
                                ? 'This position has no model on it yet.'
                                : '"$_model" is not in the catalog yet - add '
                                      'it there first.')
                          : 'Saved into the catalog, so every one of these on '
                                'this job and the next follows it.',
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
          key: const ValueKey('equipment_life_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('equipment_life_apply'),
          onPressed: typed == null ? null : _apply,
          child: Text(
            _scope == EquipmentLifeScope.catalog ? 'Save to catalog' : 'Set',
          ),
        ),
      ],
    );
  }
}

/// THE SIZE EVERY BUTTON ON THIS SCREEN IS.
///
/// Material's default is sized for a phone's thumb against a phone's type. On
/// a desktop at 150% the type inside the button grew and the button did not,
/// which left labels touching both edges of a control that had stopped looking
/// pressable. This grows the box with the words in it - see [gridMetric] - and
/// keeps a minimum height a mouse can hit without aiming.
ButtonStyle lifecycleButtonStyle(BuildContext context) {
  final unit = gridMetric(context, 12);
  return ButtonStyle(
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: unit * 1.4, vertical: unit * 0.9),
    ),
    minimumSize: WidgetStatePropertyAll(Size(0, gridMetric(context, 44))),
    textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.titleSmall),
  );
}

/// The one thing this screen does to the whole room at once.
///
/// A room is usually dated ONCE — everything in a room refreshed in 2018 went
/// in that summer, one crew, one week — so the honest record and the fastest
/// one are the same thing. See [AppStateProvider.setRoomInstalledOn].
class _RoomActions extends StatelessWidget {
  final RoomLifecycle room;

  /// Whether the positions off the cycle are on screen, and the way to change
  /// it. Owned by the screen — see [_LifecycleViewState._showNever].
  final bool showNever;
  final VoidCallback onShowNever;

  const _RoomActions({
    required this.room,
    required this.showNever,
    required this.onShowNever,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final undated = room.undated;
    final never = room.neverCount;
    final gap = gridMetric(context, 12);

    final date = FilledButton.tonalIcon(
      key: const ValueKey('lifecycle_date_room'),
      style: lifecycleButtonStyle(context),
      onPressed: () => showRoomInstallDateDialog(context),
      icon: Icon(Icons.event_repeat, size: gridMetric(context, 20)),
      label: const Text('Date the whole room…'),
    );

    final note = Text(
      undated == 0
          ? 'Every item has a date. Use this to move them all to a new one '
                'after a refresh.'
          : '$undated of ${room.items.length} item'
                '${room.items.length == 1 ? '' : 's'} still have no date. '
                'One press sets them all.',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: undated == 0
            ? theme.colorScheme.onSurfaceVariant
            : theme.colorScheme.tertiary,
      ),
    );

    // WHAT IS BEING HELD BACK, AND THE WAY TO SEE IT. Only once there is
    // something: a toggle for a thing that has never happened is one more
    // control to read past. It says the COUNT rather than 'show hidden',
    // because a plan that is quietly shorter than the room is exactly what
    // this had to avoid.
    final reveal = never == 0
        ? null
        : TextButton.icon(
            key: const ValueKey('lifecycle_show_never'),
            style: lifecycleButtonStyle(context),
            onPressed: onShowNever,
            icon: Icon(
              showNever ? Icons.visibility_off : Icons.visibility,
              size: gridMetric(context, 20),
            ),
            label: Text(
              showNever
                  ? 'Hide the $never that never need replacing'
                  : 'Show $never that never need replacing',
            ),
          );

    // THE SENTENCE GIVES WAY BEFORE THE BUTTONS DO. On a narrow window - or a
    // display at 150%, which is the same thing - a row of two buttons with a
    // paragraph wedged between them squeezes both buttons until neither of
    // them reads. Below a threshold the note drops to its own line and the
    // controls keep their full size.
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, gap * 0.8),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth < gridMetric(context, 720)) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: gap,
                  runSpacing: gap * 0.5,
                  children: [date, ?reveal],
                ),
                SizedBox(height: gap * 0.6),
                note,
              ],
            );
          }
          return Row(
            children: [
              date,
              SizedBox(width: gap),
              Expanded(child: note),
              if (reveal != null) ...[SizedBox(width: gap), reveal],
            ],
          );
        },
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
      spacing: gridMetric(context, 14),
      runSpacing: gridMetric(context, 6),
      children: [
        for (final timing in ramp)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: gridMetric(context, 14),
                height: gridMetric(context, 14),
                decoration: BoxDecoration(
                  color: equipmentTimingFill(context, timing, alpha: 0.85),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              SizedBox(width: gridMetric(context, 6)),
              Text(
                kEquipmentTimingLabels[timing]!,
                style: theme.textTheme.labelMedium?.copyWith(
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

    final gap = gridMetric(context, 12);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, gap, 16, gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: gap * 1.6,
            runSpacing: gap * 0.9,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    equipmentTimingIcon(timing),
                    size: gridMetric(context, 26),
                    color: headline,
                  ),
                  SizedBox(width: gap * 0.7),
                  Text(
                    kEquipmentTimingLabels[timing]!,
                    key: const ValueKey('lifecycle_room_condition'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
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
          SizedBox(height: gap * 0.9),
          _TimingBar(room: room, currency: currency),
          SizedBox(height: gap * 0.7),
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
            height: gridMetric(context, 16),
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
        SizedBox(height: gridMetric(context, 5)),
        Text(
          [
            for (final band in bands)
              '${kEquipmentTimingLabels[band.timing]!} '
                  '${formatEquipmentBand(band.count, band.cost, currency)}',
          ].join('  ·  '),
          key: const ValueKey('lifecycle_bar_summary'),
          style: theme.textTheme.bodyMedium?.copyWith(
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
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// One position: what it is, how old, and the date field that drives all of it.
class _ItemRow extends StatelessWidget {
  final EquipmentLife item;
  final String currency;

  /// True for a position that has been taken off the refresh cycle. It is
  /// drawn as what it is — a box in the room with no replacement date — rather
  /// than left off the screen entirely, so a decision somebody made can be
  /// seen and undone.
  final bool never;

  const _ItemRow({
    required this.item,
    required this.currency,
    this.never = false,
  });

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
    final color = never
        ? theme.colorScheme.onSurfaceVariant
        : equipmentTimingColor(context, timing);
    final detail = [
      if (item.node.model.isNotEmpty) item.node.model,
      if (item.locationName.isNotEmpty) item.locationName,
      '${formatEquipmentAge(item.ageYears)} old',
      // A due date is the one thing a position off the cycle does not have,
      // and 'no install date' would be the wrong reason for it.
      if (!never) formatEquipmentDue(item),
      if (!never) 'life ${item.lifeYears} yrs',
      if (item.hasHistory) 'replaced ${item.node.swaps.length}x before',
    ].join('  ·  ');

    final gap = gridMetric(context, 12);

    // The row's controls, built once and then placed by how much room there
    // is. A price, the date - the one fact this screen exists to collect - and
    // the two judgements about the position itself.
    final controls = <Widget>[
      if (item.replacementCost > 0)
        Padding(
          padding: EdgeInsets.only(right: gap * 0.5),
          // A TYPICAL PRICE SAYS SO. When the catalog has no figure for this
          // model the plan falls back to the base card's figure for its
          // category, which is the right number to budget from and the wrong
          // one to quote from - so it is marked, not quietly mixed in with the
          // prices that are this box's own.
          child: Tooltip(
            message: item.costIsEstimate
                ? 'Typical price for its category - the catalog has no price '
                      'for this model'
                : 'Catalog price for this model',
            child: Text(
              item.costIsEstimate
                  ? '~${formatLifecycleMoney(item.replacementCost, currency)}'
                  : formatLifecycleMoney(item.replacementCost, currency),
              style: theme.textTheme.titleSmall?.copyWith(
                fontStyle: item.costIsEstimate
                    ? FontStyle.italic
                    : FontStyle.normal,
                color: item.costIsEstimate
                    ? theme.colorScheme.onSurfaceVariant
                    : null,
              ),
            ),
          ),
        ),
      // The one control on the row, because the date is the one fact this
      // screen exists to collect. Everything else about the box is edited
      // where the box is drawn.
      OutlinedButton.icon(
        key: ValueKey('lifecycle_install_${item.node.id}'),
        style: lifecycleButtonStyle(context),
        onPressed: () => _pickInstall(context),
        icon: Icon(Icons.event_available, size: gridMetric(context, 18)),
        label: Text(
          item.installedOn == null
              ? 'Set install date'
              : formatEquipmentDate(item.installedOn!),
        ),
      ),
      // HOW LONG IT LASTS, beside WHEN IT WENT IN. The two together are the
      // whole of the due date, and before this only one of them could be
      // edited from the list - the other was a field on the catalog page,
      // which is a different screen and a different document.
      if (!never)
        IconButton(
          key: ValueKey('lifecycle_life_${item.node.id}'),
          tooltip: 'How long this lasts (${item.lifeYears} yrs, '
              '${kEquipmentLifeSourceLabels[item.lifeSource]})',
          iconSize: gridMetric(context, 20),
          constraints: BoxConstraints.tightFor(
            width: gridMetric(context, 40),
            height: gridMetric(context, 40),
          ),
          icon: const Icon(Icons.hourglass_bottom),
          onPressed: () => showEquipmentLifeDialog(context, item),
        ),
      if (item.installedOn != null && !never)
        IconButton(
          key: ValueKey('lifecycle_install_clear_${item.node.id}'),
          tooltip: 'Nobody knows when this went in',
          iconSize: gridMetric(context, 20),
          constraints: BoxConstraints.tightFor(
            width: gridMetric(context, 40),
            height: gridMetric(context, 40),
          ),
          icon: const Icon(Icons.close),
          onPressed: () => context
              .read<AppStateProvider>()
              .setAvNodeInstalledOn(item.node.id, null),
        ),
      // ON OR OFF THE CYCLE, on the row itself. It is a judgement about one
      // position - this bracket, this pole - made while looking at the list it
      // is cluttering, and a screen somewhere else to make it in is a screen
      // nobody goes to.
      IconButton(
        key: ValueKey('lifecycle_never_${item.node.id}'),
        tooltip: never
            ? 'Put this back on the refresh cycle'
            : 'This never needs replacing - take it off the plan',
        iconSize: gridMetric(context, 20),
        constraints: BoxConstraints.tightFor(
          width: gridMetric(context, 40),
          height: gridMetric(context, 40),
        ),
        icon: Icon(
          never ? Icons.restart_alt : Icons.do_not_disturb_on_outlined,
        ),
        onPressed: () => context
            .read<AppStateProvider>()
            .setAvNodeNeverReplaced(item.node.id, !never),
      ),
    ];

    final leading = Tooltip(
      message: never ? kEquipmentNeverLabel : kEquipmentTimingLabels[timing]!,
      child: Icon(
        never ? Icons.do_not_disturb_on_outlined : equipmentTimingIcon(timing),
        size: gridMetric(context, 24),
        color: color,
      ),
    );

    final title = Text(item.node.label, style: theme.textTheme.titleMedium);

    final subtitle = Text.rich(
      TextSpan(
        children: [
          // The step in words, in its own colour, at the front of the line:
          // the colour says which of the six it is at a glance and the word
          // says it to a mono print and to a reader who cannot tell the amber
          // from the orange.
          TextSpan(
            text: never
                ? kEquipmentNeverLabel
                : kEquipmentTimingLabels[timing]!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: '  ·  $detail'),
        ],
      ),
      style: theme.textTheme.bodyMedium,
    );

    return Container(
      // The row's own band, down the edge a list is scanned along. The wash
      // behind it is faint enough that the text on top of it is the text
      // everywhere else on this screen; the edge is where the colour is.
      decoration: BoxDecoration(
        color: never
            ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.05)
            : equipmentTimingFill(context, timing, alpha: 0.10),
        border: Border(
          left: BorderSide(
            color: never
                ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
                : equipmentTimingFill(context, timing, alpha: 0.9),
            width: 4,
          ),
        ),
      ),
      // THE CONTROLS DROP UNDER THE NAME RATHER THAN SHRINK BESIDE IT. A
      // device name, a line of detail and four controls do not fit on one line
      // of a narrow window - and at 150% no window is wide - so below a
      // threshold the row becomes two rows instead of squeezing 'Set install
      // date' down to an ellipsis.
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth >= gridMetric(context, 760)) {
            return ListTile(
              key: ValueKey('lifecycle_item_${item.node.id}'),
              contentPadding: EdgeInsets.symmetric(
                horizontal: gap * 1.3,
                vertical: gap * 0.5,
              ),
              leading: leading,
              title: title,
              subtitle: subtitle,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: controls),
            );
          }
          return Padding(
            key: ValueKey('lifecycle_item_${item.node.id}'),
            padding: EdgeInsets.fromLTRB(gap * 1.3, gap, gap, gap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    leading,
                    SizedBox(width: gap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [title, SizedBox(height: gap * 0.3), subtitle],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: gap * 0.5),
                Wrap(
                  spacing: gap * 0.5,
                  runSpacing: gap * 0.5,
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: controls,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
