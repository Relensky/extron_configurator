import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_rack_view.dart';
import 'export_tools.dart';
import 'screenshot_tools.dart';

/// ============================================================================
///  RACKS TAB
/// ============================================================================
///  The rack elevations, as a tab of their own rather than a page inside AV
///  Flow. They answer a different question from the signal path — where the
///  boxes physically live, how much space is left and how much heat the frame
///  has to lose — and they get looked at by different people, so they get
///  their own place in the rail.
///
///  The elevation itself is [AvRackView], unchanged; this adds the chrome the
///  page used to borrow from the AV Flow toolbar: edit mode, save, and the
///  image export.
/// ============================================================================

class RackTabView extends StatefulWidget {
  const RackTabView({super.key});

  @override
  State<RackTabView> createState() => _RackTabViewState();
}

class _RackTabViewState extends State<RackTabView> {
  final GlobalKey _captureKey = GlobalKey();
  bool _editMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The racks live in the AV sidecar, which is only read on the first
      // visit to whichever tab gets there first.
      context.read<AppStateProvider>().ensureAvFlowForCurrentConfig();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    if (provider.roomConfig.isEmpty) {
      return const Center(child: Text('No configuration loaded.'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Rack Elevations',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(width: 4),
              FilterChip(
                avatar: Icon(
                  _editMode ? Icons.edit : Icons.edit_outlined,
                  size: 18,
                ),
                label: const Text('Edit'),
                selected: _editMode,
                onSelected: (v) => setState(() => _editMode = v),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save AV Flow'),
                onPressed: () async {
                  final saved = await provider.saveAvFlow();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        saved.isEmpty
                            ? 'Failed to save the AV flow.'
                            : 'AV flow saved to $saved',
                      ),
                    ),
                  );
                },
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.image, size: 18),
                label: const Text('Export PNG'),
                onPressed: () => _exportPng(provider),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: AvRackView(captureKey: _captureKey, editMode: _editMode),
        ),
      ],
    );
  }

  Future<void> _exportPng(AppStateProvider provider) async {
    // Taken before the first await: a messenger captured after one is a
    // BuildContext used across an async gap.
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await captureBoundary(_captureKey, pixelRatio: 2.0);
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Nothing to export — add a rack first.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save Rack Elevation Image',
      fileName: '${roomFileStem(provider, 'racks')}.png',
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.png')) outputFile += '.png';
    final saved = outputFile;
    try {
      await File(saved).writeAsBytes(bytes);
      messenger.showSnackBar(
        SnackBar(content: Text('Rack elevation saved to $saved')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to save image: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
