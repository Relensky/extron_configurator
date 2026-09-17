import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';

/// App Config: what goes on every estimate PDF - the logo in the top right
/// corner and who prepared it.
class EstimateSettingsSection extends StatelessWidget {
  const EstimateSettingsSection({super.key});

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
                  helperText: 'PNG or JPEG, printed in the top right corner',
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
      ],
    );
  }
}
