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
//  WHERE THE QUOTE HAS GOT TO
// ---------------------------------------------------------------------------
//  This app builds the RFQ per vendor and hands you the .xlsx. Everything after
//  that - it went out on the 4th, two came back, one turned into a PO, the
//  third has never replied - lived in somebody's inbox, and on a six-vendor job
//  "which of these are we still waiting on" is the single most-asked question
//  on this screen.
//
//  Three dates answer it, and one of them does work. See [VendorRfqStage] for
//  the states and [AppStateProvider.markVendorOrdered] for what ordering
//  actually does: it raises the PO, points it at this vendor, and puts every
//  part this vendor is quoting onto it - which is the LINK BACK from a PO
//  number to the equipment it bought, and the thing nobody could produce
//  before.
//
//  THIS FILE IS THE SHARED HALF. The vendor card owns the editing - the strip,
//  the dialogs, the buttons - and lives on the Vendors pane. What is here is
//  everything a SECOND screen needs to say the same thing the same way: the
//  colors, the icon, the one-line sentence, the chip, and the way a quote
//  document is found and opened. The timeline reads all of it, and a copy of
//  it there would be two screens disagreeing about what "quoted" looks like.

/// The color a stage is drawn in — read against the card's own fill, never
/// straight out of the scheme. See contrast.dart.
Color rfqInk(ThemeData theme, VendorRfqStage stage) => switch (stage) {
  VendorRfqStage.none => theme.colorScheme.onSurfaceVariant,
  VendorRfqStage.sent => theme.colorScheme.onSurfaceVariant,
  // The two that are an ANSWER rather than a wait.
  VendorRfqStage.quoted => foregroundOn(
    theme.colorScheme,
    theme.cardColor,
  ),
  VendorRfqStage.ordered => foregroundOn(theme.colorScheme, theme.cardColor),
};

/// Where a vendor's quote document actually is on this machine.
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

IconData rfqIcon(VendorRfqStage stage) => switch (stage) {
  VendorRfqStage.none => Icons.outbox_outlined,
  VendorRfqStage.sent => Icons.hourglass_empty,
  VendorRfqStage.quoted => Icons.request_quote_outlined,
  VendorRfqStage.ordered => Icons.check_circle_outline,
};

/// The one-line state, for the collapsed card. A list of six vendors has to be
/// readable as a list of six states without opening any of them.
class VendorRfqChip extends StatelessWidget {
  final ProjectVendor vendor;

  const VendorRfqChip({super.key, required this.vendor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stage = vendor.rfqStage;
    // A vendor nobody has sent anything to is the ordinary state of a job that
    // has not gone out yet, and a row of gray "Not sent" chips down a fresh
    // list is noise about nothing.
    if (stage == VendorRfqStage.none) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: vendorRfqSentence(vendor),
        child: Chip(
          key: ValueKey('vendor_rfq_chip_${vendor.id}'),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          avatar: Icon(
            rfqIcon(stage),
            size: 16,
            color: rfqInk(theme, stage),
          ),
          label: Text(
            stage == VendorRfqStage.ordered && vendor.poNumber.trim().isNotEmpty
                ? vendor.poNumber.trim()
                : stage.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: rfqInk(theme, stage),
            ),
          ),
        ),
      ),
    );
  }
}

/// The whole story of one vendor's quote as a sentence — what the chip's
/// tooltip says, and what a report would print.
String vendorRfqSentence(ProjectVendor vendor) {
  final parts = <String>[];
  if (vendor.rfqSentOn != null) {
    parts.add('RFQ sent ${formatScheduleDate(vendor.rfqSentOn!)}');
  }
  if (vendor.quotedOn != null) {
    parts.add('quoted ${formatScheduleDate(vendor.quotedOn!)}');
  }
  if (vendor.quoteRef.trim().isNotEmpty) {
    parts.add('quote ${vendor.quoteRef.trim()}');
  }
  if (vendor.orderedOn != null) {
    parts.add('ordered ${formatScheduleDate(vendor.orderedOn!)}');
  }
  if (vendor.poNumber.trim().isNotEmpty) {
    parts.add('on ${vendor.poNumber.trim()}');
  }
  return parts.isEmpty ? 'No quote request out yet.' : parts.join(' · ');
}
