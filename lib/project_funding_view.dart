import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'cost_estimate.dart' show formatMoney;
import 'live_text_field.dart';

/// ============================================================================
///  PRIORITIES AND FUNDING
/// ============================================================================
///  The job's rooms by priority, with who pays for each and the money set
///  aside for it out of the budget. The budget is the maximum: targets can be
///  moved between rooms, and a target that would take the total past it is
///  refused. The budget itself is locked here and unlocked on purpose.
///
///  Line items and drawn rooms are listed together, because a line built into
///  a room keeps its priority and its target.
/// ============================================================================

/// One room on the card, whichever list it is on.
typedef _FundedRoom = ({
  String manualId,
  String roomId,
  String name,
  bool isLine,
  int priority,
  String funding,
  double target,
});

/// Whether the card has anything to say - see [ProjectFundingCard].
bool projectHasFunding(AppStateProvider provider) {
  final p = provider.project;
  return p.budget > 0 ||
      p.budgetLocked ||
      p.manualRooms.any((r) => r.priority > 0 || r.targetPrice > 0) ||
      p.rooms.any((r) => r.priority > 0 || r.targetPrice > 0);
}

class ProjectFundingCard extends StatefulWidget {
  const ProjectFundingCard({super.key});

  @override
  State<ProjectFundingCard> createState() => _ProjectFundingCardState();
}

class _ProjectFundingCardState extends State<ProjectFundingCard> {
  bool _expanded = true;

  /// Bumped when a target is refused, so its box goes back to the figure the
  /// job actually holds.
  int _revision = 0;

  double _parse(String v) =>
      double.tryParse(v.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;

  void _set(
    AppStateProvider provider,
    _FundedRoom room, {
    int? priority,
    String? funding,
    double? target,
  }) {
    final error = provider.setRoomFunding(
      manualId: room.manualId,
      roomId: room.roomId,
      priority: priority,
      funding: funding,
      targetPrice: target,
    );
    if (error.isEmpty) return;
    setState(() => _revision++);
    final messenger = ScaffoldMessenger.of(context);
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(error),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
  }

  Future<void> _toggleLock(AppStateProvider provider) async {
    if (!provider.project.budgetLocked) {
      provider.setProjectBudgetLocked(true);
      return;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unlock the maximum?'),
        content: const Text(
          'The budget is the most this job can spend. Unlock it only to '
          'change that figure, then lock it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('funding_unlock_confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    if (go == true) provider.setProjectBudgetLocked(false);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final project = provider.project;
    final theme = Theme.of(context);
    final cur = project.currency;
    String money(double v) => formatMoney(v, cur);

    final rooms = <_FundedRoom>[
      for (final r in project.manualRooms)
        (
          manualId: r.id,
          roomId: '',
          name: r.name,
          isLine: true,
          priority: r.priority,
          funding: r.funding,
          target: r.targetPrice,
        ),
      for (final r in project.includedRooms)
        (
          manualId: '',
          roomId: r.id,
          name: provider.projectRoomLogName(r.id),
          isLine: false,
          priority: r.priority,
          funding: r.funding,
          target: r.targetPrice,
        ),
    ];
    final priorities = {for (final r in rooms) r.priority}.toList()
      ..sort((a, b) => a == 0 ? 1 : (b == 0 ? -1 : a.compareTo(b)));
    final highest = priorities.fold(0, (a, b) => a > b ? a : b);

    final allocated = project.targetTotal;
    final free = project.budget - allocated;
    final over = project.budget > 0 && free < -0.005;

    Widget figure(String label, String value, {Color? color, String? key}) =>
        Padding(
          padding: const EdgeInsets.only(right: 24, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelSmall),
              Text(
                value,
                key: key == null ? null : ValueKey(key),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        );

    Widget row(_FundedRoom room) => Padding(
      key: ValueKey('funding_row_${room.manualId}${room.roomId}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            room.isLine ? Icons.playlist_add_check : Icons.meeting_room_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Tooltip(
              message: room.isLine ? 'Line item' : 'Room config',
              child: Text(room.name, style: theme.textTheme.bodyMedium),
            ),
          ),
          SizedBox(
            width: 110,
            child: DropdownButton<int>(
              key: ValueKey('funding_priority_${room.manualId}${room.roomId}'),
              value: room.priority,
              isDense: true,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: 0, child: Text('None')),
                for (var p = 1; p <= highest + 1; p++)
                  DropdownMenuItem(value: p, child: Text('Priority $p')),
              ],
              onChanged: (v) => _set(provider, room, priority: v ?? 0),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: LiveTextField(
              fieldId: 'funding_src_${room.manualId}${room.roomId}',
              initial: room.funding,
              hint: 'Central',
              onChanged: (v) => _set(provider, room, funding: v),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 130,
            child: LiveTextField(
              key: ValueKey('funding_target_${room.manualId}${room.roomId}'),
              fieldId:
                  'funding_target_${room.manualId}${room.roomId}_$_revision',
              initial: room.target > 0 ? room.target.toStringAsFixed(2) : '',
              prefix: cur,
              numeric: true,
              onChanged: (_) {},
              onSubmitted: (v) => _set(provider, room, target: _parse(v)),
            ),
          ),
        ],
      ),
    );

    return Card(
      key: const ValueKey('project_funding_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.format_list_numbered),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Priorities and funding',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                // Locked, it is a figure, not a box.
                if (project.budgetLocked)
                  Text(
                    money(project.budget),
                    key: const ValueKey('funding_max'),
                    style: theme.textTheme.titleMedium,
                  )
                else
                  SizedBox(
                    width: 180,
                    child: LiveTextField(
                      key: const ValueKey('funding_max'),
                      fieldId: 'funding_max',
                      initial: project.budget == 0
                          ? ''
                          : project.budget.toStringAsFixed(2),
                      label: 'Maximum ($cur)',
                      numeric: true,
                      onChanged: (v) => provider.setProjectBudget(_parse(v)),
                    ),
                  ),
                IconButton(
                  key: const ValueKey('funding_lock'),
                  tooltip: project.budgetLocked
                      ? 'Locked. Unlock to change the maximum'
                      : 'Lock the maximum',
                  icon: Icon(
                    project.budgetLocked ? Icons.lock : Icons.lock_open,
                  ),
                  onPressed: () => _toggleLock(provider),
                ),
                IconButton(
                  tooltip: _expanded ? 'Hide the rooms' : 'Show the rooms',
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              children: [
                figure('Maximum', money(project.budget)),
                figure('Set aside for rooms', money(allocated)),
                figure(
                  over ? 'Over by' : 'Free',
                  money(free.abs()),
                  key: 'funding_free',
                  color: over ? theme.colorScheme.error : null,
                ),
              ],
            ),
            if (_expanded)
              for (final p in priorities) ...[
                const Divider(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        p == 0 ? 'Not prioritized' : 'Priority $p',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      money(
                        rooms
                            .where((r) => r.priority == p)
                            .fold(0.0, (a, r) => a + r.target),
                      ),
                      key: ValueKey('funding_subtotal_$p'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final r in rooms.where((r) => r.priority == p)) row(r),
              ],
          ],
        ),
      ),
    );
  }
}
