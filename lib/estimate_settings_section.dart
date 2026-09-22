import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'image_color_picker.dart';
import 'main.dart' show AccentColorPicker;

/// Deep tones that print well behind white text, for the estimate's accent.
/// The built-in navy is the Default swatch in front of them.
const List<Color> kEstimateAccentSwatches = [
  Color(0xFF263238), // charcoal
  Color(0xFF0D47A1), // blue
  Color(0xFF006064), // teal
  Color(0xFF1B5E20), // green
  Color(0xFF4A148C), // purple
  Color(0xFF880E4F), // plum
  Color(0xFFB71C1C), // red
  Color(0xFFBF360C), // rust
];

/// App Config: what goes on every estimate PDF - the logo, which corner it
/// prints in, the accent color and who prepared it.
class EstimateSettingsSection extends StatelessWidget {
  const EstimateSettingsSection({super.key});

  Future<void> _pickFromLogo(
    BuildContext context,
    AppStateProvider provider,
    String logoPath,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    Uint8List bytes;
    try {
      bytes = await File(logoPath).readAsBytes();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not read the logo file.')),
      );
      return;
    }
    if (!context.mounted) return;
    final image = await decodeImageForPicking(bytes);
    if (!context.mounted) return;
    if (image == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('The logo is not an image this can read.')),
      );
      return;
    }
    final picked = await pickColorFromImage(context, bytes);
    if (picked == null) return;
    provider.updateSetting(
      'estimateAccent',
      (picked.toARGB32() & 0xFFFFFF)
          .toRadixString(16)
          .padLeft(6, '0')
          .toUpperCase(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final logoPath = provider.estimateLogoPath;
    final logoMissing = logoPath.isNotEmpty && !File(logoPath).existsSync();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Estimate PDF', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            SizedBox(
              width: 280,
              child: TextFormField(
                key: const ValueKey('estimate_prepared_by'),
                initialValue: provider.estimatePreparedBy,
                decoration: const InputDecoration(
                  labelText: 'Prepared by',
                  helperText: 'Your name, as it prints on the estimate',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    provider.updateSetting('estimatePreparedBy', v),
              ),
            ),
            SizedBox(
              width: 280,
              child: TextFormField(
                key: const ValueKey('estimate_preparer_contact'),
                initialValue: provider.estimatePreparerContact,
                decoration: const InputDecoration(
                  labelText: 'Contact (optional)',
                  helperText: 'Email or phone under your name',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    provider.updateSetting('estimatePreparerContact', v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                key: ValueKey('estimate_logo_$logoPath'),
                initialValue: logoPath,
                decoration: InputDecoration(
                  labelText: 'Logo',
                  helperText: 'PNG or JPEG, printed in a top corner',
                  errorText: logoMissing ? 'File not found' : null,
                  border: const OutlineInputBorder(),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (logoPath.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Remove the logo',
                          onPressed: () =>
                              provider.updateSetting('estimateLogoPath', ''),
                        ),
                      IconButton(
                        icon: const Icon(Icons.image_outlined),
                        tooltip: 'Choose an image',
                        onPressed: () async {
                          final result = await FilePicker.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: const ['png', 'jpg', 'jpeg'],
                          );
                          final picked = result?.files.single.path;
                          if (picked != null) {
                            provider.updateSetting('estimateLogoPath', picked);
                          }
                        },
                      ),
                    ],
                  ),
                ),
                onChanged: (v) =>
                    provider.updateSetting('estimateLogoPath', v),
              ),
            ),
            if (logoPath.isNotEmpty && !logoMissing) ...[
              const SizedBox(width: 16),
              Container(
                width: 160,
                height: 60,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: theme.dividerColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Image.file(
                  File(logoPath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Center(
                    child: Text(
                      'Not an image',
                      style: TextStyle(color: Colors.black54, fontSize: 11),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Logo corner', style: theme.textTheme.titleSmall),
            SegmentedButton<String>(
              key: const ValueKey('estimate_logo_side'),
              segments: const [
                ButtonSegment(
                  value: 'left',
                  icon: Icon(Icons.align_horizontal_left),
                  label: Text('Left'),
                ),
                ButtonSegment(
                  value: 'right',
                  icon: Icon(Icons.align_horizontal_right),
                  label: Text('Right'),
                ),
              ],
              selected: {provider.estimateLogoSide},
              onSelectionChanged: (v) =>
                  provider.updateSetting('estimateLogoSide', v.first),
            ),
            Text(
              'The Estimate title and room go on the other side.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Accent color', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Headings, rules and the total band on the PDF, and the title and '
          'header bands on the Excel reports.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        const AccentColorPicker(
          settingKey: 'estimateAccent',
          swatches: kEstimateAccentSwatches,
          allowAuto: true,
          autoLabel: 'Default (navy)',
          autoColor: Color(0xFF1F3A5F),
        ),
        const SizedBox(height: 8),
        // TAKE THE COLOR OFF THE LOGO, so the report matches the brand.
        OutlinedButton.icon(
          key: const ValueKey('estimate_accent_from_logo'),
          icon: const Icon(Icons.colorize, size: 18),
          label: const Text('Pick from logo...'),
          onPressed: logoPath.isEmpty || logoMissing
              ? null
              : () => _pickFromLogo(context, provider, logoPath),
        ),
        if (logoPath.isEmpty || logoMissing)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Choose a logo above to pick a color from it.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
