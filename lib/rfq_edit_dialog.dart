import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:pdfrx/pdfrx.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'cost_estimate.dart' show trimNumber;
import 'estimate_pdf.dart' show loadEstimatePdfTheme;
import 'file_dialogs.dart';
import 'project_estimate.dart';
import 'project_workbook.dart';

/// Which files to write.
enum RfqFormat { xlsx, pdf, both }

// The edit screen's last choices, kept until the app closes so the next
// export starts where the last one left off.
RfqFormat _lastFormat = RfqFormat.xlsx;
final Map<String, Set<String>> _lastLeaveOut = {};

/// The bidders a package's request goes to; [null] alone when nobody has
/// been invited, for one unaddressed draft.
List<ProjectVendor?> _bidders(AppStateProvider provider, VendorPackage p) {
  final found = <ProjectVendor?>[
    for (final b in p.rfq?.bids ?? const <RfqBid>[])
      provider.project.vendorById(b.vendorId),
  ]..removeWhere((v) => v == null);
  return found.isEmpty ? [null] : found;
}

/// Opens the edit screen for [packages], then writes one request per bidder
/// (Excel, PDF or both) into a folder the user picks. One package is one
/// quote; the whole list is every quote on the job.
Future<void> exportQuoteRequests(
  BuildContext context,
  AppStateProvider provider,
  ProjectEstimate estimate,
  List<VendorPackage> packages,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  final choice = await showRfqEditDialog(
    context,
    estimate: estimate,
    packages: packages,
    format: _lastFormat,
    leaveOut: _lastLeaveOut,
  );
  if (choice == null) return;
  _lastFormat = choice.format;
  _lastLeaveOut.addAll(choice.leaveOut);
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
    final leaveOut = choice.leaveOut[package.id] ?? const <String>{};
    // Every item edited out: no request for this package.
    if (leaveOut.length >= package.lines.length) continue;
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
              leaveOut: leaveOut,
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
              leaveOut: leaveOut,
              theme: pdfTheme,
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
        content: Text('No quote requests were written: ${failed.join('; ')}'),
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

/// The request as it will go out, as the PDF, in a dialog.
Future<void> showRfqPreview(
  BuildContext context, {
  required ProjectEstimate estimate,
  required VendorPackage package,
  ProjectVendor? vendor,
  Set<String> leaveOut = const {},
}) async {
  final bytes = await buildVendorRfqPdf(
    estimate: estimate,
    package: package,
    vendor: vendor,
    leaveOut: leaveOut,
    theme: loadEstimatePdfTheme(),
  );
  if (!context.mounted) return;
  final size = MediaQuery.sizeOf(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      key: const ValueKey('rfq_preview_dialog'),
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: size.width * 0.9 > 1000 ? 1000 : size.width * 0.9,
        height: size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      vendor == null
                          ? package.packageName
                          : '${package.packageName} - ${vendor.name}',
                      style: Theme.of(ctx).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: PdfViewer.data(
                bytes,
                // Unique, so an edited request is not served from cache.
                sourceName: 'rfq_preview_${package.id}_'
                    '${DateTime.now().microsecondsSinceEpoch}.pdf',
                params: const PdfViewerParams(margin: 8),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

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
  required ProjectEstimate estimate,
  required List<VendorPackage> packages,
  RfqFormat format = RfqFormat.xlsx,
  Map<String, Set<String>> leaveOut = const {},
}) {
  return showDialog<RfqEditChoice>(
    context: context,
    builder: (_) => _RfqEditDialog(
      estimate: estimate,
      packages: packages,
      format: format,
      leaveOut: leaveOut,
    ),
  );
}

class _RfqEditDialog extends StatefulWidget {
  final ProjectEstimate estimate;
  final List<VendorPackage> packages;
  final RfqFormat format;
  final Map<String, Set<String>> leaveOut;

  const _RfqEditDialog({
    required this.estimate,
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
                widget.packages.length == 1
                    ? '${widget.packages.single.packageName} quote request'
                    : 'Quote requests',
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
                'Untick anything that should not be on the request. '
                'Preview shows it as it will go out.',
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

  // The preview is addressed to the first bidder, as the first copy is.
  ProjectVendor? _firstBidder(VendorPackage p) =>
      _bidders(context.read<AppStateProvider>(), p).first;

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
        secondary: TextButton.icon(
          key: ValueKey('rfq_preview_${p.id}'),
          icon: const Icon(Icons.visibility_outlined, size: 18),
          label: const Text('Preview'),
          onPressed: none
              ? null
              : () => showRfqPreview(
                  context,
                  estimate: widget.estimate,
                  package: p,
                  vendor: _firstBidder(p),
                  leaveOut: out,
                ),
        ),
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
