import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'contrast.dart';
import 'pdf_viewer_dialog.dart';
import 'project_schedule.dart' show formatScheduleDate;

// ---------------------------------------------------------------------------
//  WHERE THE QUOTES HAVE GOT TO
// ---------------------------------------------------------------------------
//  This app builds the request per package and hands you a copy of it for
//  every vendor being asked. Everything after that - it went out on the 4th to
//  three of them, two came back, one of those won, the third has never replied
//  - lived in somebody's inbox, and on a six-package job "which of these are we
//  still waiting on" is the single most-asked question on this screen.
//
//  The dates on the BIDS answer it, and the award does work. See [RfqStage]
//  for the states and [AppStateProvider.awardRfq] for what awarding actually
//  does: it raises the PO, points it at the winning vendor, puts every part in
//  the package onto it - which is the LINK BACK from a PO number to the
//  equipment it bought - and finally gives those parts a supplier at all.
//
//  THIS FILE IS THE SHARED HALF. The package card owns the editing - the
//  comparison table, the dialogs, the buttons - and lives on the Packages
//  pane. What is here is everything a SECOND screen needs to say the same
//  thing the same way: the colors, the icon, the one-line sentence, the chip,
//  and the way a quote document is found and opened. The timeline reads all of
//  it, and a copy of it there would be two screens disagreeing about what
//  "quoted" looks like.

/// The color a stage is drawn in — read against the card's own fill, never
/// straight out of the scheme. See contrast.dart.
Color rfqInk(ThemeData theme, RfqStage stage) => switch (stage) {
  RfqStage.draft => theme.colorScheme.onSurfaceVariant,
  RfqStage.out => theme.colorScheme.onSurfaceVariant,
  // Part-quoted is a WAIT with something in it: still chasing somebody, so it
  // reads as the waiting states do rather than as an answer.
  RfqStage.partial => theme.colorScheme.onSurfaceVariant,
  // The two that are an ANSWER rather than a wait.
  RfqStage.quoted => foregroundOn(theme.colorScheme, theme.cardColor),
  RfqStage.awarded => foregroundOn(theme.colorScheme, theme.cardColor),
};

/// Where a bid's quote document actually is on this machine.
///
/// Resolved against the project file exactly the way a room's config, a
/// building plan and a purchase order are, so a job folder that has been moved
/// or handed over still finds its own paperwork.
String resolveVendorQuoteFile(AppStateProvider provider, String stored) {
  if (stored.trim().isEmpty) return '';
  return BuildingProject.resolvePath(
    stored.trim(),
    provider.currentProjectPath,
  );
}

/// Whether the app can draw this document itself, off its extension.
bool quoteDrawableHere(String filePath) {
  final ext = path.extension(filePath).replaceFirst('.', '').toLowerCase();
  return kViewablePlanExtensions.contains(ext);
}

/// Picks the document a quote came back as. ANY file, not only a PDF - a scan,
/// a screenshot of the vendor's portal, their acknowledgement as an .msg - for
/// the reason given on [attachPoFile]. Returns the absolute path, or blank
/// when nothing was chosen.
Future<String> pickVendorQuoteFile(String vendorName) async {
  final picked = await FilePicker.pickFiles(
    dialogTitle: 'Pick the quote from $vendorName',
  );
  final chosen = picked?.files.single.path;
  return chosen == null || chosen.isEmpty ? '' : chosen;
}

/// Opens a quote: IN THE APP where it can be drawn, otherwise in whatever this
/// machine opens it with. The same bargain [openPoFile] makes, for the same
/// reason - the thing somebody is doing with the quote (reading a line off it
/// against the package beside it) is a thing they are doing HERE.
///
/// Takes the STORED path rather than the vendor, so the dialog can open a file
/// that has just been picked and not yet saved.
Future<void> openVendorQuoteFile(
  BuildContext context,
  AppStateProvider provider, {
  required String stored,
  required String vendorName,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final resolved = resolveVendorQuoteFile(provider, stored);

  // SAID, NOT THROWN. A quote that has been moved or renamed is a fact about
  // the file, and "the viewer failed" would send somebody looking in the wrong
  // place for it.
  if (resolved.isEmpty || !File(resolved).existsSync()) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(
          '$vendorName\'s quote is not where the project says it '
          'is${resolved.isEmpty ? '' : ' ($resolved)'}.',
        ),
      ),
    );
    return;
  }

  if (!quoteDrawableHere(resolved)) {
    final error = await provider.openInDesktop(resolved);
    if (error != null) {
      showTimedSnackBar(messenger, SnackBar(content: Text(error)));
    }
    return;
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => PdfViewerDialog(
      filePath: resolved,
      title: '$vendorName\'s quote',
      screenshotStem: path.basenameWithoutExtension(resolved),
      onOpenExternally: () => provider.openInDesktop(resolved),
    ),
  );
}

IconData rfqIcon(RfqStage stage) => switch (stage) {
  RfqStage.draft => Icons.outbox_outlined,
  RfqStage.out => Icons.hourglass_empty,
  RfqStage.partial => Icons.hourglass_bottom,
  RfqStage.quoted => Icons.request_quote_outlined,
  RfqStage.awarded => Icons.check_circle_outline,
};

/// The one-line state, for the collapsed card. A list of six packages has to
/// be readable as a list of six states without opening any of them.
class VendorRfqChip extends StatelessWidget {
  final ProjectRfq rfq;

  /// The winner's name, when there is one — resolved by the caller, which has
  /// the project to hand.
  final String awardedVendorName;

  const VendorRfqChip({
    super.key,
    required this.rfq,
    this.awardedVendorName = '',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stage = rfq.stage;
    // A package nobody has sent anything to is the ordinary state of a job
    // that has not gone out yet, and a row of gray "Draft" chips down a fresh
    // list is noise about nothing.
    if (stage == RfqStage.draft) return const SizedBox.shrink();
    // How many are still owed, on the chip itself: "2 of 4 in" is the whole
    // answer on a competition, and 'Part quoted' alone is not.
    final owed = rfq.outstanding.length;
    final label = switch (stage) {
      RfqStage.awarded when rfq.poNumber.trim().isNotEmpty =>
        rfq.poNumber.trim(),
      RfqStage.partial => '${rfq.bids.length - owed} of ${rfq.bids.length} in',
      _ => stage.label,
    };
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: rfqSentence(rfq, awardedVendorName: awardedVendorName),
        child: Chip(
          key: ValueKey('rfq_chip_${rfq.id}'),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          avatar: Icon(rfqIcon(stage), size: 16, color: rfqInk(theme, stage)),
          label: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: rfqInk(theme, stage),
            ),
          ),
        ),
      ),
    );
  }
}

/// The whole story of one package's quotes as a sentence — what the chip's
/// tooltip says, and what a report would print.
String rfqSentence(ProjectRfq rfq, {String awardedVendorName = ''}) {
  final parts = <String>[];
  final sent = [
    for (final b in rfq.bids)
      if (b.isSent) b,
  ];
  if (sent.isNotEmpty) {
    // The EARLIEST send is the one that dates the round. A vendor added late
    // has their own date on their own row, and putting it here would make the
    // package look as though it went out a week after it did.
    final first = sent
        .map((b) => b.sentOn!)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    parts.add(
      'sent to ${sent.length} vendor${sent.length == 1 ? '' : 's'} '
      '${formatScheduleDate(first)}',
    );
  }
  final back = [
    for (final b in rfq.bids)
      if (b.quotedOn != null) b,
  ].length;
  if (back > 0) parts.add('$back quoted');
  final declined = [
    for (final b in rfq.bids)
      if (b.declined) b,
  ].length;
  if (declined > 0) parts.add('$declined declined');
  final owed = rfq.outstanding.length;
  if (owed > 0) parts.add('$owed still out');
  if (rfq.awardedOn != null || rfq.awardedVendorId.isNotEmpty) {
    parts.add(
      'awarded${awardedVendorName.trim().isEmpty ? '' : ' to '
          '${awardedVendorName.trim()}'}'
      '${rfq.awardedOn == null ? '' : ' ${formatScheduleDate(rfq.awardedOn!)}'}',
    );
  }
  if (rfq.poNumber.trim().isNotEmpty) parts.add('on ${rfq.poNumber.trim()}');
  return parts.isEmpty ? 'No quote request out yet.' : parts.join(' · ');
}
