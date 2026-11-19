import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'cost_estimate.dart' show trimNumber;
import 'estimate_pdf.dart'
    show estimateAccentColor, loadEstimatePdfTheme, readEstimateLogo;
import 'file_dialogs.dart';
import 'pdf_preview_dialog.dart';
import 'project_estimate.dart';
import 'project_workbook.dart';
import 'report_pdf.dart';

/// Which files to write.
enum RfqFormat { xlsx, pdf, both }

/// The header and footer text typed on the edit screen. Blank title is the
/// project's; blank subtitle is the package name.
typedef RfqHeaderText = ({String title, String subtitle, String footer});

/// What the edit screen hands back: the format, the header and footer, and
/// per package id what was left off.
typedef RfqEditChoice = ({
  RfqFormat format,
  RfqHeaderText header,
  Map<String, RfqEdits> edits,
});

// The edit screen's last choices, kept until the app closes so the next
// export starts where the last one left off.
RfqFormat _lastFormat = RfqFormat.xlsx;
RfqHeaderText _lastHeader = (title: '', subtitle: '', footer: '');
final Map<String, RfqEdits> _lastEdits = {};

/// The bidders a package's request goes to; [null] alone when nobody has
/// been invited, for one unaddressed draft.
List<ProjectVendor?> _bidders(AppStateProvider provider, VendorPackage p) {
  final found = <ProjectVendor?>[
    for (final b in p.rfq?.bids ?? const <RfqBid>[])
      provider.project.vendorById(b.vendorId),
  ]..removeWhere((v) => v == null);
  return found.isEmpty ? [null] : found;
}

/// [p] with only the lines the job buys at least one of.
VendorPackage _paidOnly(VendorPackage p) {
  final lines = [
    for (final l in p.lines)
      if (l.boughtQty > 0) l,
  ];
  if (lines.length == p.lines.length) return p;
  return VendorPackage(
    rfq: p.rfq,
    awardedVendor: p.awardedVendor,
    lines: lines,
    total: lines.fold(0.0, (sum, l) => sum + l.total),
    qty: lines.fold(0.0, (sum, l) => sum + l.boughtQty),
  );
}

/// The PDF's header and footer: the typed text, and the logo, accent and
/// preparer from App Config, as the estimate PDF has them.
ReportPdfDress _dress(
  AppStateProvider provider,
  VendorPackage package,
  RfqHeaderText header,
) => ReportPdfDress(
  subtitle: header.subtitle.trim().isEmpty
      ? package.packageName
      : header.subtitle.trim(),
  logo: readEstimateLogo(provider.estimateLogoForExport),
  logoOnLeft: provider.estimateLogoSide == 'left',
  accent: estimateAccentColor(provider.estimateAccent),
  preparedBy: provider.estimatePreparedBy.trim(),
  preparerContact: provider.estimatePreparerContact.trim(),
  footer: header.footer,
);

/// Opens the edit screen for [packages], then writes one request per bidder
/// (Excel, PDF or both) into a folder the user picks. One package is one
/// quote; the whole list is every quote on the job.
Future<void> exportQuoteRequests(
  BuildContext context,
  AppStateProvider provider,
  ProjectEstimate estimate,
  List<VendorPackage> all,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  // Only what the job pays for: nothing already in the room, in kind or
  // furnished by others.
  final packages = [
    for (final p in all)
      if (_paidOnly(p) case final paid when paid.lines.isNotEmpty) paid,
  ];
  if (packages.isEmpty) {
    showTimedSnackBar(
      messenger,
      const SnackBar(
        duration: Duration(seconds: 5),
        content: Text(
          'Nothing to quote - every part here is already in the room, in '
          'kind or furnished by others.',
        ),
      ),
    );
    return;
  }
  final choice = await showRfqEditDialog(
    context,
    provider: provider,
    estimate: estimate,
    packages: packages,
  );
  if (choice == null) return;
  final wantXlsx = choice.format != RfqFormat.pdf;
  final wantPdf = choice.format != RfqFormat.xlsx;

  final folder = await getDirectoryPathCompat(
    dialogTitle: packages.length == 1
        ? 'Where should the ${packages.single.packageName} quote request go?'
        : 'Where should the quote requests go?',
  );
  if (folder == null) return;

  final pdfTheme = wantPdf ? loadEstimatePdfTheme() : null;
  final written = <String>[];
  final failed = <String>[];
  for (final package in packages) {
    final edits = choice.edits[package.id] ?? const RfqEdits();
    // Nothing left on it: no request for this package.
    final left = package.lines.where(
      (l) =>
          !edits.leaveOut.contains(l.key) &&
          rfqLineQty(l, edits.leaveOutRooms) > 0,
    );
    if (left.isEmpty) continue;
    for (final vendor in _bidders(provider, package)) {
      final stem = vendorRfqFileStem(provider.project, package, vendor: vendor);
      if (wantXlsx) {
        final name = '$stem.xlsx';
        try {
          await File(path.join(folder, name)).writeAsBytes(
            buildVendorRfqBytes(
              estimate: estimate,
              package: package,
              vendor: vendor,
              edits: edits,
              title: choice.header.title,
            ),
          );
          written.add(name);
        } catch (e) {
          failed.add('$name - $e');
        }
      }
      if (wantPdf) {
        final name = '$stem.pdf';
        try {
          await File(path.join(folder, name)).writeAsBytes(
            await buildVendorRfqPdf(
              estimate: estimate,
              package: package,
              vendor: vendor,
              edits: edits,
              theme: pdfTheme,
              title: choice.header.title,
              dress: _dress(provider, package, choice.header),
            ),
          );
          written.add(name);
        } catch (e) {
          failed.add('$name - $e');
        }
      }
    }
  }

  if (written.isEmpty) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(
          failed.isEmpty
              ? 'Nothing was left on the quote requests.'
              : 'No quote requests were written: ${failed.join('; ')}',
        ),
        backgroundColor: snackErrorFillFor(theme),
      ),
    );
    return;
  }
  showSavedSnackBar(
    messenger: messenger,
    theme: theme,
    provider: provider,
    message: failed.isEmpty
        ? '${written.length} quote request file'
              '${written.length == 1 ? '' : 's'} written'
        : '${written.length} written, ${failed.length} failed '
              '(${failed.first})',
    savedPath: folder,
    isFolder: true,
  );
}

/// The request as it will go out, as the PDF, full screen.
Future<void> showRfqPreview(
  BuildContext context, {
  required AppStateProvider provider,
  required ProjectEstimate estimate,
  required VendorPackage package,
  required RfqHeaderText header,
  ProjectVendor? vendor,
  RfqEdits edits = const RfqEdits(),
}) async {
  final bytes = await buildVendorRfqPdf(
    estimate: estimate,
    package: package,
    vendor: vendor,
    edits: edits,
    theme: loadEstimatePdfTheme(),
    title: header.title,
    dress: _dress(provider, package, header),
  );
  if (!context.mounted) return;
  await showPdfBytesPreview(
    context,
    key: const ValueKey('rfq_preview_dialog'),
    bytes: bytes,
    title: vendor == null
        ? package.packageName
        : '${package.packageName} - ${vendor.name}',
  );
}

/// The quote request edit screen: the format, the header and footer, and per
/// quote the items and rooms on it. Null when cancelled. The choices are
/// kept for the next time it opens.
Future<RfqEditChoice?> showRfqEditDialog(
  BuildContext context, {
  required AppStateProvider provider,
  required ProjectEstimate estimate,
  required List<VendorPackage> packages,
}) async {
  final choice = await showDialog<RfqEditChoice>(
    context: context,
    builder: (_) => _RfqEditDialog(
      provider: provider,
      estimate: estimate,
      packages: packages,
    ),
  );
  if (choice != null) {
    _lastFormat = choice.format;
    _lastHeader = choice.header;
    _lastEdits.addAll(choice.edits);
  }
  return choice;
}

class _RfqEditDialog extends StatefulWidget {
  final AppStateProvider provider;
  final ProjectEstimate estimate;
  final List<VendorPackage> packages;

  const _RfqEditDialog({
    required this.provider,
    required this.estimate,
    required this.packages,
  });

  @override
  State<_RfqEditDialog> createState() => _RfqEditDialogState();
}

class _RfqEditDialogState extends State<_RfqEditDialog> {
  late RfqFormat _format = _lastFormat;
  late final _title = TextEditingController(text: _lastHeader.title);
  late final _subtitle = TextEditingController(text: _lastHeader.subtitle);
  late final _footer = TextEditingController(text: _lastHeader.footer);

  // Per package: items off, rooms off, rooms column. Only keys still on the
  // package, so a part or room gone from the job is dropped.
  late final Map<String, Set<String>> _out = {
    for (final p in widget.packages)
      p.id: {
        for (final l in p.lines)
          if (_lastEdits[p.id]?.leaveOut.contains(l.key) ?? false) l.key,
      },
  };
  late final Map<String, Set<String>> _roomsOff = {
    for (final p in widget.packages)
      p.id: {
        for (final id in _roomIds(p))
          if (_lastEdits[p.id]?.leaveOutRooms.contains(id) ?? false) id,
      },
  };
  late final Map<String, bool> _showRooms = {
    for (final p in widget.packages)
      p.id: _lastEdits[p.id]?.showRooms ?? false,
  };
  // One quote opens expanded; several start folded.
  late final Set<String> _open = {
    if (widget.packages.length == 1) widget.packages.single.id,
  };

  late final Map<String, String> _roomNames = {
    for (final r in widget.estimate.rooms) r.ref.id: r.codeName,
  };

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    _footer.dispose();
    super.dispose();
  }

  /// The rooms the job buys parts of [p] for, in job order.
  List<String> _roomIds(VendorPackage p) {
    final ids = {
      for (final l in p.lines)
        for (final id in l.qtyByRoom.keys)
          if (l.boughtInRoom(id) > 0) id,
    };
    return [
      for (final r in widget.estimate.rooms)
        if (ids.contains(r.ref.id)) r.ref.id,
    ];
  }

  RfqEdits _edits(VendorPackage p) => RfqEdits(
    leaveOut: _out[p.id]!,
    leaveOutRooms: _roomsOff[p.id]!,
    showRooms: _showRooms[p.id]!,
  );

  int _left(VendorPackage p) => p.lines
      .where(
        (l) =>
            !_out[p.id]!.contains(l.key) &&
            rfqLineQty(l, _roomsOff[p.id]!) > 0,
      )
      .length;

  int get _included =>
      widget.packages.fold(0, (sum, p) => sum + _left(p));

  RfqHeaderText get _header =>
      (title: _title.text, subtitle: _subtitle.text, footer: _footer.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final single = widget.packages.length == 1;
    return Dialog(
      key: const ValueKey('rfq_edit_dialog'),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 1100,
          maxHeight: size.height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                single
                    ? '${widget.packages.single.packageName} quote request'
                    : 'Quote requests',
                style: theme.textTheme.titleLarge,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Align(
                      alignment: Alignment.centerLeft,
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
                        onSelectionChanged: (s) =>
                            setState(() => _format = s.first),
                      ),
                    ),
                  ),
                  _headerFields(theme),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                    child: Text(
                      'Untick any item or room that should not be on the '
                      'request. Preview shows it as it will go out.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const Divider(height: 1),
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
                            header: _header,
                            edits: {
                              for (final p in widget.packages)
                                p.id: _edits(p),
                            },
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

  /// Title, subtitle and footer. The logo, color and preparer come from
  /// App Config, as on the estimate PDF.
  Widget _headerFields(ThemeData theme) {
    Widget field(TextEditingController c, String key, String label,
            String hint) =>
        SizedBox(
          width: 300,
          child: TextField(
            key: ValueKey(key),
            controller: c,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              isDense: true,
            ),
          ),
        );
    return ExpansionTile(
      key: const ValueKey('rfq_header_footer'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 20),
      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      expandedAlignment: Alignment.centerLeft,
      title: const Text('Header and footer'),
      subtitle: Text(
        'Logo, color and Prepared by come from App Config.',
        style: theme.textTheme.bodySmall,
      ),
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            field(
              _title,
              'rfq_header_title',
              'Title',
              vendorRfqTitle(widget.provider.project),
            ),
            field(
              _subtitle,
              'rfq_header_subtitle',
              'Subtitle',
              'The package name',
            ),
            field(_footer, 'rfq_footer', 'Footer', ''),
          ],
        ),
      ],
    );
  }

  List<Widget> _package(VendorPackage p, ThemeData theme) {
    final out = _out[p.id]!;
    final all = out.isEmpty;
    final none = out.length == p.lines.length;
    final open = _open.contains(p.id);
    final left = _left(p);
    return [
      ListTile(
        key: ValueKey('rfq_edit_package_${p.id}'),
        contentPadding: const EdgeInsets.only(left: 8, right: 12),
        onTap: () => setState(
          () => open ? _open.remove(p.id) : _open.add(p.id),
        ),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(open ? Icons.expand_more : Icons.chevron_right),
            Checkbox(
              key: ValueKey('rfq_edit_package_check_${p.id}'),
              tristate: true,
              value: all ? true : (none ? false : null),
              onChanged: (_) => setState(() {
                if (all) {
                  out.addAll(p.lines.map((l) => l.key));
                } else {
                  out.clear();
                }
              }),
            ),
          ],
        ),
        title: Text(p.packageName, style: theme.textTheme.titleSmall),
        subtitle: Text('$left of ${p.lines.length} items'),
        trailing: TextButton.icon(
          key: ValueKey('rfq_preview_${p.id}'),
          icon: const Icon(Icons.visibility_outlined, size: 18),
          label: const Text('Preview'),
          onPressed: left == 0
              ? null
              : () => showRfqPreview(
                  context,
                  provider: widget.provider,
                  estimate: widget.estimate,
                  package: p,
                  header: _header,
                  // Addressed to the first bidder, as the first copy is.
                  vendor: _bidders(widget.provider, p).first,
                  edits: _edits(p),
                ),
        ),
      ),
      if (open)
        LayoutBuilder(
          builder: (context, box) {
            final items = _items(p);
            final rooms = _rooms(p, theme);
            // Side by side when there is room for both.
            if (box.maxWidth >= 760) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: items),
                  const VerticalDivider(width: 1),
                  Expanded(flex: 2, child: rooms),
                ],
              );
            }
            return Column(children: [items, rooms]);
          },
        ),
      const Divider(height: 1),
    ];
  }

  Widget _items(VendorPackage p) {
    final out = _out[p.id]!;
    final roomsOff = _roomsOff[p.id]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 40, top: 4),
          child: Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                key: ValueKey('rfq_check_all_${p.id}'),
                icon: const Icon(Icons.check_box_outlined, size: 18),
                label: const Text('Check all'),
                onPressed: out.isEmpty ? null : () => setState(out.clear),
              ),
              TextButton.icon(
                key: ValueKey('rfq_uncheck_all_${p.id}'),
                icon: const Icon(Icons.check_box_outline_blank, size: 18),
                label: const Text('Uncheck all'),
                onPressed: out.length == p.lines.length
                    ? null
                    : () => setState(
                        () => out.addAll(p.lines.map((l) => l.key)),
                      ),
              ),
            ],
          ),
        ),
        for (final l in p.lines)
          CheckboxListTile(
            key: ValueKey('rfq_edit_line_${p.id}_${l.key}'),
            dense: true,
            contentPadding: const EdgeInsets.only(left: 48, right: 16),
            value: !out.contains(l.key),
            onChanged: (v) => setState(() {
              if (v ?? false) {
                out.remove(l.key);
              } else {
                out.add(l.key);
              }
            }),
            title: Text(l.model.trim().isEmpty ? l.description : l.model),
            subtitle: Text(
              [
                if (l.manufacturer.trim().isNotEmpty) l.manufacturer,
                'Qty ${trimNumber(rfqLineQty(l, roomsOff))}',
              ].join('  ·  '),
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
      ],
    );
  }

  Widget _rooms(VendorPackage p, ThemeData theme) {
    final ids = _roomIds(p);
    final off = _roomsOff[p.id]!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: ValueKey('rfq_show_rooms_${p.id}'),
            dense: true,
            title: const Text('Show rooms on the request'),
            subtitle: const Text('Each item lists its rooms and counts.'),
            value: _showRooms[p.id]!,
            onChanged: (v) => setState(() => _showRooms[p.id] = v),
          ),
          if (ids.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Rooms on this quote',
                style: theme.textTheme.labelLarge,
              ),
            ),
          for (final id in ids)
            CheckboxListTile(
              key: ValueKey('rfq_edit_room_${p.id}_$id'),
              dense: true,
              value: !off.contains(id),
              onChanged: (v) => setState(() {
                if (v ?? false) {
                  off.remove(id);
                } else {
                  off.add(id);
                }
              }),
              title: Text(_roomNames[id] ?? id),
              controlAffinity: ListTileControlAffinity.leading,
            ),
        ],
      ),
    );
  }
}
