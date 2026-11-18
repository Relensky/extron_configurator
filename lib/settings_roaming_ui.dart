// ============================================================================
// [SETTINGS ROAMING]: the screens for services/settings_roaming.dart - the
// question asked the first time a PC finds your settings on the share, and
// the Settings Sync section.
// ============================================================================

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'services/ios_share.dart' show uncPath;
import 'settings_roaming.dart';
import 'settings_kit/settings_kit.dart';

/// Asks what to do with the settings found on the share for this login.
/// Null when the dialog was dismissed (ask again next start).
Future<RoamingChoice?> showSettingsRoamingChoice(
  BuildContext context,
  SettingsRoaming roaming, {
  required String appName,
}) {
  return showDialog<RoamingChoice>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      // iPhone / iPad: a device, not a PC, and Windows-encrypted passwords
      // can't be opened there - they stay on the share for the PCs.
      final here = Platform.isIOS ? 'device' : 'PC';
      final where = uncPath(roaming.userFolder);
      return AlertDialog(
        icon: const Icon(Icons.sync),
        title: const Text('Your settings are on the share'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            '$appName settings saved by ${roaming.login} on another computer '
            'were found in:\n$where\n\n'
            '${Platform.isIOS ? 'Use them here? Saved passwords are encrypted '
                      'for Windows, so they stay on the share for your PCs - sign in '
                      'again here where one is needed.' : 'Use them here? Saved '
                      'passwords and sign-ins come too; they are encrypted so only '
                      'your Windows account can open them.'}\n\n'
            'Keep this $here\'s settings puts this $here\'s settings on the '
            'share instead. Either way, changes you make from now on are saved '
            'to the share and reach your other computers the next time the app '
            'starts there.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, RoamingChoice.off),
            child: Text('Don\'t sync on this $here'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, RoamingChoice.keepThisPc),
            child: Text('Keep this $here\'s settings'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, RoamingChoice.useShared),
            child: const Text('Use my saved settings'),
          ),
        ],
      );
    },
  );
}

/// The Settings Sync section: on/off for this PC, what happened last, sync
/// now and the folder.
class SettingsRoamingSection extends StatefulWidget {
  const SettingsRoamingSection({
    super.key,
    required this.roaming,
    required this.appName,
    required this.applyChoice,
  });

  final SettingsRoaming roaming;
  final String appName;

  /// Runs a first sync with [RoamingChoice] and reloads what it pulled.
  final Future<void> Function(RoamingChoice choice) applyChoice;

  @override
  State<SettingsRoamingSection> createState() => _SettingsRoamingSectionState();
}

class _SettingsRoamingSectionState extends State<SettingsRoamingSection> {
  bool? _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.roaming.isEnabled().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    try {
      final result = await widget.roaming.sync();
      if (result.needsChoice && mounted) {
        final choice = await showSettingsRoamingChoice(
          context,
          widget.roaming,
          appName: widget.appName,
        );
        if (choice != null) await widget.applyChoice(choice);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _enabled = await widget.roaming.isEnabled();
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _setEnabled(bool on) async {
    await widget.roaming.setEnabled(on);
    setState(() => _enabled = on);
    if (on) await _syncNow();
  }

  @override
  Widget build(BuildContext context) {
    final roaming = widget.roaming;
    final folder = roaming.userFolder;
    final muted = Theme.of(context).textTheme.bodySmall;
    return SettingsSection(
      id: 'settings_sync',
      title: 'Settings Sync',
      summary: 'Keep your settings on the share for every PC you sign in to',
      icon: Icons.sync,
      children: [
        Text(
          'Your settings, saved passwords and sign-ins are kept in a folder '
          'named after your Windows login (${roaming.login}) on the share, so '
          'any PC you sign in to picks them up when the app starts. Passwords '
          'are encrypted to your own Windows account. Window positions and '
          'paths on this PC\'s own drives stay on this PC.',
          style: muted,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep my settings on the share'),
          subtitle: Text(
            folder.isEmpty
                ? 'No team folder is set, so there is nowhere to keep them'
                : folder,
          ),
          value: _enabled ?? true,
          onChanged: _enabled == null || folder.isEmpty
              ? null
              : (v) => _setEnabled(v),
        ),
        ValueListenableBuilder<String>(
          valueListenable: roaming.status,
          builder: (context, s, _) =>
              s.isEmpty ? const SizedBox.shrink() : Text(s, style: muted),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy || folder.isEmpty || _enabled != true
                  ? null
                  : _syncNow,
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Save to the share now'),
            ),
            OutlinedButton.icon(
              onPressed: folder.isEmpty
                  ? null
                  : () async {
                      await Directory(folder).create(recursive: true);
                      await Process.run('explorer.exe', [folder]);
                    },
              icon: const Icon(Icons.folder_open),
              label: const Text('Open my folder'),
            ),
          ],
        ),
      ],
    );
  }
}
