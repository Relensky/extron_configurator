import 'package:flutter/material.dart';

import 'equipment_lifecycle.dart' show assumedCycleLabel, kAssumedCycleYears;

/// ============================================================================
///  WHAT IF WE DID EVERY ROOM AT TEN YEARS?
/// ============================================================================
///  The control behind the restatement - see the note above
///  [kAssumedCycleYears] in equipment_lifecycle.dart for why a plan can be
///  restated at all.
///
///  ONE CONTROL, THREE SCREENS. A room, a building and an estate are the same
///  question asked at three sizes, and three controls that looked different
///  would read as three different features.
///
///  IT COSTS NOTHING WHILE IT IS OFF. This lives above sheets that are the
///  point of their screen - the year grid, the campus calendar, the job list -
///  and a block of chrome over a document pushes the document's own controls
///  below the fold on a laptop at 150%, which is a worse fault than the one it
///  fixes. So the control is [AssumedCycleControl]: a label and a dropdown, on
///  the sheet's own header row beside the zoom, taking no height of its own.
///
///  IT GROWS ONLY ONCE SOMEBODY HAS ASKED SOMETHING. With a cycle picked, the
///  screen adds [AssumedCycleNote] above the sheet: what is being assumed, and
///  what it moved. That is a state the reader chose, and the one state where
///  the extra line has to be there - a control that silently changed forty
///  figures is one somebody presses once and then distrusts.
///
///  AND IT SAYS IT IS NOT SAVED. The most important line on it: nothing is
///  written to any room, catalog or job, and the plan is one press from being
///  itself again.
/// ============================================================================

/// One figure the restatement moved: what it is, what it was, what it is now.
typedef CycleShift = ({String label, String was, String now});

/// The picker itself, sized to sit on a sheet's header row.
///
/// No border and no fill: it is one control among the sheet's other controls,
/// and a boxed one beside a bare zoom stepper reads as a different KIND of
/// thing. The tint on the icon and the label is what says it is in force.
class AssumedCycleControl extends StatelessWidget {
  /// The cycle in force, or null for the plan as recorded.
  final int? assumed;

  final ValueChanged<int?> onChanged;

  /// Used in widget keys, so two of these on one page never collide and a test
  /// can name the one it means.
  final String keyPrefix;

  const AssumedCycleControl({
    super.key,
    required this.assumed,
    required this.onChanged,
    required this.keyPrefix,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final on = assumed != null && assumed! > 0;
    final ink = on ? scheme.tertiary : scheme.onSurfaceVariant;

    return Tooltip(
      message: on
          ? 'A what-if. The sheet is restated on a $assumed-year cycle; '
                'nothing is saved.'
          : 'See what this would cost on a different refresh cycle. Nothing '
                'is saved.',
      child: Row(
        key: ValueKey('${keyPrefix}_assumed_cycle'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.published_with_changes, size: 16, color: ink),
          const SizedBox(width: 5),
          Text(
            'Cycle',
            style: theme.textTheme.labelMedium?.copyWith(color: ink),
          ),
          const SizedBox(width: 6),
          DropdownButton<int?>(
            key: ValueKey('${keyPrefix}_cycle_picker'),
            value: on ? assumed : null,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: on ? scheme.tertiary : scheme.onSurface,
              fontWeight: on ? FontWeight.bold : FontWeight.normal,
            ),
            items: [
              DropdownMenuItem(
                key: ValueKey('${keyPrefix}_cycle_recorded'),
                value: null,
                child: Text(assumedCycleLabel(null)),
              ),
              for (final years in kAssumedCycleYears)
                DropdownMenuItem(
                  key: ValueKey('${keyPrefix}_cycle_$years'),
                  value: years,
                  child: Text('$years-year cycle'),
                ),
            ],
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// WHAT IS BEING ASSUMED, AND WHAT IT MOVED.
///
/// Drawn only while a cycle is in force - see the note at the head of this
/// file. Returns nothing at all when the plan is the plan as recorded, so the
/// screen can place it unconditionally and pay nothing for it.
class AssumedCycleNote extends StatelessWidget {
  final int? assumed;

  /// What the restatement covers, in the words that screen would use:
  /// 'every room on this campus', 'everything in this room'.
  final String scope;

  /// The figures worth printing as `was -> now`. Empty is fine.
  final List<CycleShift> shifts;

  final String keyPrefix;

  const AssumedCycleNote({
    super.key,
    required this.assumed,
    required this.scope,
    required this.keyPrefix,
    this.shifts = const [],
  });

  @override
  Widget build(BuildContext context) {
    final years = assumed;
    if (years == null || years <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      key: ValueKey('${keyPrefix}_assumed_cycle_note'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: scheme.tertiary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.tertiary),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              'What-if only: $scope restated on a $years-year cycle, whatever '
              'life is recorded. Nothing is saved, positions held off the '
              'cycle are unchanged, and anything exported now says so on it.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.tertiary,
              ),
            ),
          ),
          for (final shift in shifts)
            _Shift(
              key: ValueKey('${keyPrefix}_shift_${shift.label}'),
              shift: shift,
            ),
        ],
      ),
    );
  }
}

/// One figure, before and after.
class _Shift extends StatelessWidget {
  final CycleShift shift;

  const _Shift({super.key, required this.shift});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final same = shift.was == shift.now;

    // BOTH FIGURES, NOT THE DIFFERENCE. 'Up 240,000' is a number nobody can
    // check; 'was 1.2M, now 1.44M' is two numbers that are each on a sheet
    // somewhere.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${shift.label}  ',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        Text(
          shift.was,
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
            decoration: same ? null : TextDecoration.lineThrough,
          ),
        ),
        if (!same) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Icon(
              Icons.arrow_forward,
              size: 13,
              color: scheme.onSurfaceVariant,
            ),
          ),
          Text(
            shift.now,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: scheme.tertiary,
            ),
          ),
        ],
      ],
    );
  }
}
