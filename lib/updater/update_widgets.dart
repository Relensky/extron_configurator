// ============================================================================
// [FEATURE - APP UPDATES]: the two pieces of update UI.
//
//   * [UpdateNoticeHost] wraps the app (MaterialApp.builder) and shows a small
//     card in the corner when a newer release is in the folder. It never
//     blocks anything: "Later" hides it for that version, it waits while the
//     updater is marked userBusy, and nothing installs until the user presses
//     Update and then confirms.
//   * [UserActivityWatcher] marks the updater busy while someone is typing or
//     clicking, so neither the checks nor the card land in the middle of it.
//   * [UpdateSettingsSection] goes in a settings screen: the running version,
//     the folder being watched, the last check, and Check now / Update.
//
// The card sits above the Navigator, so it uses no dialogs, tooltips or
// routes - only what MaterialApp.builder's context already provides.
// ============================================================================

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'folder_updater.dart';

class UpdateNoticeHost extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final u = updater;
    if (u == null) return child;
    return Stack(
      children: [
        Positioned.fill(child: child),
        ListenableBuilder(
          listenable: u,
          builder: (context, _) {
            // Hidden still shows an install the user started from settings.
            final started = u.confirming ||
                u.installFailed ||
                u.status == UpdateStatus.installing;
            if (!u.showNotice || ((hidden || u.userBusy) && !started)) {
              return const SizedBox.shrink();
            }
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
      actions = [
        TextButton(onPressed: u.dismissNotice, child: const Text('Later')),
        FilledButton(onPressed: u.requestInstall, child: const Text('Update')),
      ];
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

/// Version, release folder, last check and the Check now / Update buttons.
class UpdateSettingsSection extends StatelessWidget {
  final FolderUpdater updater;
  const UpdateSettingsSection({super.key, required this.updater});

  static String _time(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        final u = updater;
        final theme = Theme.of(context);
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
            ListTile(
              dense: true,
              title: const Text('Release folder'),
              subtitle: SelectableText(u.releaseFolder,
                  style: theme.textTheme.bodySmall),
            ),
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
                  if (u.available != null)
                    FilledButton.icon(
                      icon: const Icon(Icons.system_update_alt, size: 18),
                      label: Text('Update to ${u.available!.version}'),
                      onPressed: busy ? null : u.requestInstall,
                    ),
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
