import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'vendor_book.dart' show DefaultVendor;

/// ============================================================================
///  TAKING COMPANIES OFF THE SHARED LIST, ONE AT A TIME
/// ============================================================================
///  A new job is seeded from the department's vendor list already. This is the
///  way in for the job that was started before a company was added, and for
///  the one somebody trimmed - and it used to add ALL of them, because that is
///  what a job that had never been seeded wanted.
///
///  That is the wrong default the moment the job HAS been seeded. A shop with
///  nineteen suppliers on the shared list is not asking eleven of them to
///  quote a two-room refresh, and 'Add 11 saved vendors' followed by deleting
///  nine is not a shortcut. So the list is offered and the reader ticks.
///
///  WHAT LANDS ON THE JOB IS A COPY, as it always was: renaming a vendor here,
///  or dropping the ones this job is not using, changes nothing on the share.
/// ============================================================================

/// Asks which of the shared list to put on the job, and puts them on. Returns
/// how many were added.
Future<int> pickVendorsFromBook(BuildContext context) async {
  final provider = context.read<AppStateProvider>();
  final offList = provider.vendorsOffProject;
  if (offList.isEmpty) return 0;

  final picked = await showDialog<List<String>>(
    context: context,
    builder: (_) => _VendorPickDialog(offList: offList),
  );
  if (picked == null || picked.isEmpty) return 0;
  return provider.addProjectVendorsFromBook(ids: picked);
}

class _VendorPickDialog extends StatefulWidget {
  final List<DefaultVendor> offList;

  const _VendorPickDialog({required this.offList});

  @override
  State<_VendorPickDialog> createState() => _VendorPickDialogState();
}

class _VendorPickDialogState extends State<_VendorPickDialog> {
  /// NOTHING TICKED TO START WITH. The button that added everything is the one
  /// this replaces; opening with every box ticked would be the same button
  /// with an extra press in front of it.
  final Set<String> _picked = {};

  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<DefaultVendor> get _shown {
    final needle = _search.text.trim();
    if (needle.isEmpty) return widget.offList;
    return [
      for (final v in widget.offList)
        if (v.matches(needle)) v,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _shown;

    return AlertDialog(
      key: const ValueKey('vendor_pick_dialog'),
      title: const Text('Add vendors from the saved list'),
      content: SizedBox(
        width: 620,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The department list, minus the companies this job already has. '
              'What lands on the job is a copy: renaming one here, or dropping '
              'it later, changes nothing on the share.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('vendor_pick_search'),
                    controller: _search,
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: 'Find a company',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                // Still there for the job that has never been seeded, which is
                // the case the old button was right for. It ticks the list
                // rather than committing it, so it is still one look away from
                // being wrong.
                TextButton(
                  key: const ValueKey('vendor_pick_all'),
                  onPressed: () => setState(() {
                    _picked.addAll(shown.map((v) => v.id));
                  }),
                  child: const Text('Tick all'),
                ),
                TextButton(
                  key: const ValueKey('vendor_pick_none'),
                  onPressed: _picked.isEmpty
                      ? null
                      : () => setState(_picked.clear),
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        'No company on the shared list matches that.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final vendor = shown[i];
                        final facts = [
                          if (vendor.contact.trim().isNotEmpty)
                            vendor.contact.trim(),
                          if (vendor.notes.trim().isNotEmpty)
                            vendor.notes.trim(),
                        ].join('  ·  ');
                        return CheckboxListTile(
                          key: ValueKey('vendor_pick_${vendor.id}'),
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _picked.contains(vendor.id),
                          onChanged: (on) => setState(() {
                            if (on == true) {
                              _picked.add(vendor.id);
                            } else {
                              _picked.remove(vendor.id);
                            }
                          }),
                          title: Text(vendor.name),
                          subtitle: facts.isEmpty ? null : Text(facts),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('vendor_pick_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('vendor_pick_ok'),
          onPressed: _picked.isEmpty
              ? null
              : () => Navigator.of(context).pop(_picked.toList()),
          child: Text(
            _picked.length == 1
                ? 'Add 1 vendor'
                : 'Add ${_picked.length} vendors',
          ),
        ),
      ],
    );
  }
}
