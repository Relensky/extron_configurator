import 'package:material_ui/material_ui.dart';

import 'cost_estimate.dart' show trimNumber;
import 'project_estimate.dart';

/// Which files to write.
enum RfqFormat { xlsx, pdf, both }

/// What the edit screen hands back: the format, and per package id the master
/// line keys left out of that package's request.
typedef RfqEditChoice = ({
  RfqFormat format,
  Map<String, Set<String>> leaveOut,
});

/// The quote request edit screen: pick the format and untick any item that
/// should not go out. Null when cancelled.
Future<RfqEditChoice?> showRfqEditDialog(
  BuildContext context, {
  required List<VendorPackage> packages,
  RfqFormat format = RfqFormat.xlsx,
  Map<String, Set<String>> leaveOut = const {},
}) {
  return showDialog<RfqEditChoice>(
    context: context,
    builder: (_) => _RfqEditDialog(
      packages: packages,
      format: format,
      leaveOut: leaveOut,
    ),
  );
}

class _RfqEditDialog extends StatefulWidget {
  final List<VendorPackage> packages;
  final RfqFormat format;
  final Map<String, Set<String>> leaveOut;

  const _RfqEditDialog({
    required this.packages,
    required this.format,
    required this.leaveOut,
  });

  @override
  State<_RfqEditDialog> createState() => _RfqEditDialogState();
}

class _RfqEditDialogState extends State<_RfqEditDialog> {
  late RfqFormat _format = widget.format;
  // Only keys still on each package, so a part gone from the job is dropped.
  late final Map<String, Set<String>> _out = {
    for (final p in widget.packages)
      p.id: {
        for (final l in p.lines)
          if (widget.leaveOut[p.id]?.contains(l.key) ?? false) l.key,
      },
  };

  int get _included => widget.packages.fold(
    0,
    (sum, p) => sum + p.lines.length - _out[p.id]!.length,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      key: const ValueKey('rfq_edit_dialog'),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                'Quote requests',
                style: theme.textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SegmentedButton<RfqFormat>(
                key: const ValueKey('rfq_format'),
                segments: const [
                  ButtonSegment(
                    value: RfqFormat.xlsx,
                    label: Text('Excel'),
                    icon: Icon(Icons.grid_on_outlined),
                  ),
                  ButtonSegment(
                    value: RfqFormat.pdf,
                    label: Text('PDF'),
                    icon: Icon(Icons.picture_as_pdf_outlined),
                  ),
                  ButtonSegment(
                    value: RfqFormat.both,
                    label: Text('Both'),
                    icon: Icon(Icons.library_books_outlined),
                  ),
                ],
                selected: {_format},
                onSelectionChanged: (s) => setState(() => _format = s.first),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'Untick anything that should not be on the request.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in widget.packages) ..._package(p, theme),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$_included item${_included == 1 ? '' : 's'}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('rfq_edit_save'),
                    onPressed: _included == 0
                        ? null
                        : () => Navigator.of(context).pop((
                            format: _format,
                            leaveOut: _out,
                          )),
                    child: const Text('Save...'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _package(VendorPackage p, ThemeData theme) {
    final out = _out[p.id]!;
    final all = out.isEmpty;
    final none = out.length == p.lines.length;
    return [
      CheckboxListTile(
        key: ValueKey('rfq_edit_package_${p.id}'),
        tristate: true,
        value: all ? true : (none ? false : null),
        onChanged: (_) => setState(() {
          if (all) {
            out.addAll(p.lines.map((l) => l.key));
          } else {
            out.clear();
          }
        }),
        title: Text(
          p.packageName,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text('${p.lines.length - out.length} of ${p.lines.length}'),
        controlAffinity: ListTileControlAffinity.leading,
      ),
      for (final l in p.lines)
        CheckboxListTile(
          key: ValueKey('rfq_edit_line_${p.id}_${l.key}'),
          dense: true,
          contentPadding: const EdgeInsets.only(left: 40, right: 16),
          value: !out.contains(l.key),
          onChanged: (v) => setState(() {
            if (v ?? false) {
              out.remove(l.key);
            } else {
              out.add(l.key);
            }
          }),
          title: Text(
            l.model.trim().isEmpty ? l.description : l.model,
          ),
          subtitle: Text(
            [
              if (l.manufacturer.trim().isNotEmpty) l.manufacturer,
              'Qty ${trimNumber(l.qty)}',
            ].join('  ·  '),
          ),
          controlAffinity: ListTileControlAffinity.leading,
        ),
    ];
  }
}
