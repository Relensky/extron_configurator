// ============================================================================
// [FEATURE - APP UPDATES]: the two pieces of update UI.
//
//   * [UpdateNoticeHost] wraps the app (MaterialApp.builder) and shows a small
//     card in the corner when a newer release is in the folder. It never
//     blocks anything: "Later" hides it for that version, it waits to appear
//     while the updater is marked userBusy (once up, it stays), and nothing
//     installs until the user presses
//     Update and then confirms.
//   * [UserActivityWatcher] marks the updater busy while someone is typing or
//     clicking, so neither the checks nor the card land in the middle of it.
//   * [UpdateSettingsSection] goes in a settings screen: the running version,
//     the folder being watched - which can be changed there and is remembered
//     - the last check, Check now / Update, and Desktop / Start menu shortcut
//     buttons. The card's "Close and Update" step also offers the shortcuts
//     the app does not have yet.
//
// The card sits above the Navigator, so it uses no dialogs, tooltips or
// routes - only what MaterialApp.builder's context already provides.
// ============================================================================

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'folder_updater.dart';

class UpdateNoticeHost extends StatefulWidget {
  final FolderUpdater? updater;
  final Widget child;

  /// Keeps the card out of sight - e.g. while a kiosk is showing to the
  /// public. Checks still run, and the settings section still works.
  final bool hidden;

  const UpdateNoticeHost({
    super.key,
    required this.updater,
    required this.child,
    this.hidden = false,
  });

  @override
  State<UpdateNoticeHost> createState() => _UpdateNoticeHostState();
}

class _UpdateNoticeHostState extends State<UpdateNoticeHost> {
  /// Whether the card is on screen. userBusy keeps a card from appearing,
  /// never takes one away: the click on the card's own Update button marks
  /// the user busy on pointer-down, and hiding the card then swallowed the
  /// tap, so "Close and Update" was never reached.
  bool _onScreen = false;

  @override
  Widget build(BuildContext context) {
    final u = widget.updater;
    if (u == null) return widget.child;
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        ListenableBuilder(
          listenable: u,
          builder: (context, _) {
            // Hidden still shows an install the user started from settings.
            final started = u.confirming ||
                u.installFailed ||
                u.status == UpdateStatus.installing;
            final heldBack =
                widget.hidden || (u.userBusy && !_onScreen);
            _onScreen = u.showNotice && (!heldBack || started);
            if (!_onScreen) return const SizedBox.shrink();
            return Positioned(
              right: 16,
              bottom: 16,
              child: _UpdateCard(updater: u),
            );
          },
        ),
      ],
    );
  }
}

class _UpdateCard extends StatefulWidget {
  final FolderUpdater updater;
  const _UpdateCard({required this.updater});

  @override
  State<_UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<_UpdateCard> {
  Timer? _autoHide;

  @override
  void initState() {
    super.initState();
    // "Updated to X" is news, not a question - it goes away by itself.
    if (widget.updater.lastOutcome?.succeeded == true) {
      _autoHide = Timer(const Duration(seconds: 12), () {
        if (widget.updater.lastOutcome?.succeeded == true) {
          widget.updater.clearOutcome();
        }
      });
    }
  }

  @override
  void dispose() {
    _autoHide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.updater;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    final width = (media.size.width - 32).clamp(200.0, 380.0);

    IconData icon = Icons.system_update_alt;
    Color iconColor = scheme.primary;
    String title;
    String body;
    List<Widget> actions;
    Widget? progress;
    Widget? extra;

    final available = u.available;
    final outcome = u.lastOutcome;

    if (u.status == UpdateStatus.installing) {
      title = 'Updating ${u.appName}';
      body = u.progress?.stage ?? 'Working…';
      progress = LinearProgressIndicator(value: u.progress?.fraction);
      actions = const [];
    } else if (outcome != null) {
      if (outcome.succeeded) {
        icon = Icons.check_circle_outline;
        iconColor = Colors.green;
        title = 'Updated to version ${outcome.toVersion}';
        body = '${u.appName} is now up to date.';
      } else {
        icon = Icons.error_outline;
        iconColor = scheme.error;
        title = 'The update was not installed';
        body = '${outcome.message}\n\nYou are still on version '
            '${u.currentVersion ?? outcome.fromVersion}.';
      }
      actions = [
        TextButton(onPressed: u.clearOutcome, child: const Text('OK')),
      ];
    } else if (u.installFailed) {
      icon = Icons.error_outline;
      iconColor = scheme.error;
      title = 'The update was not installed';
      body = u.errorMessage ?? 'Something went wrong.';
      actions = [
        TextButton(onPressed: u.dismissNotice, child: const Text('Dismiss')),
        if (available != null)
          FilledButton(
              onPressed: u.requestInstall, child: const Text('Try Again')),
      ];
    } else if (u.confirming && available != null) {
      title = 'Update to version ${available.version}?';
      body = '${u.appName} will close, install the update and open again. '
          'Save any work first. Your settings and files are kept.';
      // Only the shortcuts the app does not have yet, once they are known.
      final have = u.shortcuts;
      if (u.canManageShortcuts &&
          have != null &&
          (!have.desktop || !have.startMenu)) {
        extra = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!have.desktop)
              _ShortcutCheckbox(
                label: 'Add a Desktop shortcut',
                value: u.addDesktopShortcut,
                onChanged: u.setAddDesktopShortcut,
              ),
            if (!have.startMenu)
              _ShortcutCheckbox(
                label: 'Add a Start menu shortcut',
                value: u.addStartMenuShortcut,
                onChanged: u.setAddStartMenuShortcut,
              ),
          ],
        );
      }
      actions = [
        TextButton(onPressed: u.cancelInstall, child: const Text('Cancel')),
        FilledButton(
          onPressed: u.canInstall ? () => unawaited(u.install()) : null,
          child: const Text('Close and Update'),
        ),
      ];
      if (!u.canInstall) {
        body = 'Updates can only be installed from a release build.';
      }
    } else if (available != null) {
      title = 'Update available';
      body = '${u.appName} ${available.version} is ready to install. '
          'You have ${u.currentVersion}.';
      // ONE CLICK: Close and Update downloads, closes and reopens on the new
      // version straight away (unsaved work is still asked about first - see
      // confirmClose). Options... is the step that also offers shortcuts.
      actions = [
        TextButton(onPressed: u.dismissNotice, child: const Text('Later')),
        TextButton(
          key: const ValueKey('update_options'),
          onPressed: u.requestInstall,
          child: const Text('Options...'),
        ),
        FilledButton(
          key: const ValueKey('update_close_and_update'),
          onPressed: u.canInstall ? () => unawaited(u.install()) : null,
          child: const Text('Close and Update'),
        ),
      ];
      if (!u.canInstall) {
        body = '$body\nUpdates can only be installed from a release build.';
      }
    } else {
      return const SizedBox.shrink();
    }

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      color: scheme.surfaceContainerHigh,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: iconColor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(color: scheme.onSurface)),
                        const SizedBox(height: 4),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 180),
                          child: SingleChildScrollView(
                            child: Text(body,
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (extra != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: extra,
                ),
              ],
              if (progress != null) ...[
                const SizedBox(height: 12),
                progress,
                const SizedBox(height: 8),
              ],
              if (actions.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(spacing: 8, children: actions),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One "add a shortcut" choice on the update card. Checkbox and label are
/// one click target, so it is not a hunt for the little box.
class _ShortcutCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ShortcutCheckbox({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) => onChanged(v ?? false),
          ),
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurface)),
        ],
      ),
    );
  }
}

/// Version, release folder, last check and the Check now / Update buttons.
///
/// The release folder is editable here. Someone testing a build before it
/// goes on the share, or working from a copy of the folder, points the app at
/// it without a rebuild, and the choice is remembered for the next launch.
class UpdateSettingsSection extends StatefulWidget {
  final FolderUpdater updater;

  /// Opens the app's own folder picker for the Browse button. Apps without a
  /// picker leave it off and the path is typed or pasted instead.
  final Future<String?> Function()? pickFolder;

  const UpdateSettingsSection({
    super.key,
    required this.updater,
    this.pickFolder,
  });

  @override
  State<UpdateSettingsSection> createState() => _UpdateSettingsSectionState();
}

class _UpdateSettingsSectionState extends State<UpdateSettingsSection> {
  late final TextEditingController _folder =
      TextEditingController(text: widget.updater.releaseFolder);
  late final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.updater.addListener(_syncFromUpdater);
    unawaited(widget.updater.refreshShortcuts());
  }

  bool _addingShortcut = false;

  Future<void> _addShortcut({bool desktop = false, bool startMenu = false}) async {
    setState(() => _addingShortcut = true);
    try {
      await widget.updater
          .createShortcuts(desktop: desktop, startMenu: startMenu);
    } catch (_) {
      // Shown from updater.shortcutError.
    }
    if (mounted) setState(() => _addingShortcut = false);
  }

  /// "Add" while the shortcut is missing, a tick once it is there.
  Widget _shortcutButton(String label, bool? exists, VoidCallback onAdd) {
    if (exists == true) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.check, size: 18),
        label: Text('$label shortcut added'),
        onPressed: null,
      );
    }
    return OutlinedButton.icon(
      icon: const Icon(Icons.add_link, size: 18),
      label: Text('Add $label shortcut'),
      onPressed: exists == null || _addingShortcut ? null : onAdd,
    );
  }

  @override
  void dispose() {
    widget.updater.removeListener(_syncFromUpdater);
    _folder.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Keeps the field on the folder actually in use - after Use Default, or
  /// after another part of the app changed it - without stealing what someone
  /// is part way through typing.
  void _syncFromUpdater() {
    final current = widget.updater.releaseFolder;
    if (_focus.hasFocus || _folder.text == current) return;
    _folder.text = current;
  }

  /// True when the field says something other than the folder in use, so Save
  /// is worth pressing.
  bool get _edited => _folder.text.trim() != widget.updater.releaseFolder;

  void _save() {
    final v = _folder.text.trim();
    if (v.isEmpty) {
      _folder.text = widget.updater.releaseFolder;
      return;
    }
    _focus.unfocus();
    widget.updater.releaseFolder = v;
    setState(() {});
  }

  Future<void> _browse() async {
    final picked = await widget.pickFolder?.call();
    if (picked == null || picked.trim().isEmpty || !mounted) return;
    _folder.text = picked.trim();
    _save();
  }

  static String _time(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final updater = widget.updater;
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final u = updater;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        if (!u.isSupported) {
          return const ListTile(
            leading: Icon(Icons.system_update_alt),
            title: Text('App Updates'),
            subtitle: Text('Updates are only available on Windows.'),
          );
        }
        final checked =
            u.lastChecked == null ? '' : ' (checked ${_time(u.lastChecked!)})';
        final String status = switch (u.status) {
          UpdateStatus.idle => 'Not checked yet.',
          UpdateStatus.checking => 'Checking…',
          UpdateStatus.upToDate => 'Up to date$checked.',
          UpdateStatus.available =>
            'Version ${u.available?.version} is available$checked.',
          UpdateStatus.folderUnavailable =>
            "Can't reach the release folder$checked.",
          UpdateStatus.error => 'Check failed: ${u.errorMessage}',
          UpdateStatus.installing => u.progress?.stage ?? 'Installing…',
        };
        final busy = u.status == UpdateStatus.checking ||
            u.status == UpdateStatus.installing;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              leading: const Icon(Icons.system_update_alt),
              title: Text(
                  'Version ${u.currentVersion?.toString() ?? 'unknown'}'),
              subtitle: Text(status),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Release folder',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    u.releaseFolderIsLocked
                        ? 'Set by the ${FolderUpdater.folderEnvironmentVariable} '
                            'environment variable, which wins over this setting.'
                        : 'Where this app looks for a newer release. Leave it '
                            'on the default unless you have been told '
                            'otherwise.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _folder,
                          focusNode: _focus,
                          enabled: !u.releaseFolderIsLocked,
                          style: theme.textTheme.bodySmall,
                          decoration: InputDecoration(
                            isDense: true,
                            border: const OutlineInputBorder(),
                            hintText: FolderUpdater.defaultReleaseFolder,
                            helperText: u.releaseFolderReachable
                                ? (u.releaseFolderIsCustom
                                    ? 'Found. Not the default folder.'
                                    : 'Found.')
                                : "Can't see this folder from this computer "
                                    'right now - check the path, or that you '
                                    'are on the network.',
                            helperMaxLines: 3,
                          ),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _save(),
                        ),
                      ),
                      if (widget.pickFolder != null) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: u.releaseFolderIsLocked
                              ? null
                              : () => unawaited(_browse()),
                          child: const Text('Browse…'),
                        ),
                      ],
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed:
                            u.releaseFolderIsLocked || !_edited ? null : _save,
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                  if (!u.releaseFolderIsLocked && u.releaseFolderIsCustom)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: u.resetReleaseFolder,
                        child: const Text('Use default folder'),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: u.status == UpdateStatus.checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh, size: 18),
                    label: const Text('Check Now'),
                    onPressed: busy ? null : () => unawaited(u.checkNow()),
                  ),
                  if (u.available != null) ...[
                    // One click: closes, installs and reopens.
                    FilledButton.icon(
                      key: const ValueKey('settings_close_and_update'),
                      icon: const Icon(Icons.system_update_alt, size: 18),
                      label: Text(
                          'Close and Update to ${u.available!.version}'),
                      onPressed: busy || !u.canInstall
                          ? null
                          : () => unawaited(u.install()),
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : u.requestInstall,
                      child: Text('Update to ${u.available!.version}'),
                    ),
                  ],
                ],
              ),
            ),
            if (u.canManageShortcuts)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Shortcuts', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _shortcutButton('Desktop', u.shortcuts?.desktop,
                            () => unawaited(_addShortcut(desktop: true))),
                        _shortcutButton('Start menu', u.shortcuts?.startMenu,
                            () => unawaited(_addShortcut(startMenu: true))),
                      ],
                    ),
                    if (u.shortcutError != null) ...[
                      const SizedBox(height: 4),
                      Text("Couldn't add the shortcut: ${u.shortcutError}",
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.error)),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Holds [updater] busy while the user is working - any key press or click -
/// and until [quietPeriod] has passed without one. A half-hourly check that
/// comes due meanwhile runs once they stop.
///
/// Hovering and scrolling do not count: reading is not interrupted by a card
/// in the corner, and a mouse resting on the window would otherwise hold
/// updates back forever.
class UserActivityWatcher {
  final FolderUpdater updater;
  final Duration quietPeriod;

  UserActivityWatcher(
    this.updater, {
    this.quietPeriod = const Duration(minutes: 2),
  });

  Timer? _quiet;
  bool _started = false;

  /// Starts listening. Call once the binding exists, e.g. after `runApp`.
  void start() {
    if (_started) return;
    _started = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  void dispose() {
    if (_started) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      HardwareKeyboard.instance.removeHandler(_onKey);
      _started = false;
    }
    _quiet?.cancel();
    _quiet = null;
    updater.setBusy(this, false);
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _activity();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) _activity();
    return false; // Only watching; the key still goes where it was going.
  }

  void _activity() {
    // Keys and clicks come at human speed, so restarting one timer on each is
    // nothing.
    _quiet?.cancel();
    _quiet = Timer(quietPeriod, () {
      _quiet = null;
      updater.setBusy(this, false);
    });
    updater.setBusy(this, true);
  }
}
