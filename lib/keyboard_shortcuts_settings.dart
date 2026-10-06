import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'keyboard_shortcuts.dart';

/// The Keyboard shortcuts section of Application Configuration: every
/// shortcut, what it does, its keys, and a way to change them.
class KeyboardShortcutsSettings extends StatelessWidget {
  const KeyboardShortcutsSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final keys = provider.shortcuts;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Click a shortcut\'s keys to change them. A drawing\'s shortcuts '
          'work once something on it is selected: click a device, callout or '
          'box, or pick a device up in a rack. On the signal flow, turn on '
          'Edit first.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        for (final area in ShortcutArea.values) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              kShortcutAreaLabels[area]!,
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final action in kShortcutActions.where((a) => a.area == area))
            _ShortcutRow(action: action, keys: keys),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('shortcuts_reset_all'),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Put every shortcut back'),
            onPressed: keys.overrides.isEmpty
                ? null
                : () => provider.setShortcuts(const KeyboardShortcuts()),
          ),
        ),
      ],
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final ShortcutAction action;
  final KeyboardShortcuts keys;
  const _ShortcutRow({required this.action, required this.keys});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final changed = keys.isChanged(action.id);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(action.label),
                if (action.help.isNotEmpty)
                  Text(
                    action.help,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            key: ValueKey('shortcut_${action.id}'),
            style: OutlinedButton.styleFrom(
              textStyle: const TextStyle(fontFamily: 'monospace'),
              foregroundColor: changed ? theme.colorScheme.primary : null,
            ),
            onPressed: () => _change(context, provider),
            child: Text(keys.labelFor(action.id)),
          ),
          SizedBox(
            width: 40,
            child: changed
                ? IconButton(
                    tooltip: 'Back to ${action.defaults.map((k) => k.label).join(' or ')}',
                    icon: const Icon(Icons.undo, size: 18),
                    onPressed: () =>
                        provider.setShortcuts(keys.reset(action.id)),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Future<void> _change(BuildContext context, AppStateProvider provider) async {
    final picked = await showDialog<List<KeyBinding>>(
      context: context,
      builder: (_) => _CaptureDialog(
        action: action,
        keys: provider.shortcuts,
      ),
    );
    if (picked == null) return;
    provider.setShortcuts(provider.shortcuts.withBindings(action.id, picked));
  }
}

/// Listens for the keys to use. Press a combination to add it; the list can
/// hold more than one, and Clear takes them all off.
class _CaptureDialog extends StatefulWidget {
  final ShortcutAction action;
  final KeyboardShortcuts keys;
  const _CaptureDialog({required this.action, required this.keys});

  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  late List<KeyBinding> _bindings = List.of(
    widget.keys.bindingsFor(widget.action.id),
  );
  final FocusNode _focus = FocusNode(debugLabel: 'shortcut capture');
  String _clash = '';

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final binding = KeyBinding.fromEvent(event);
    if (binding == null) return KeyEventResult.handled;
    final other = widget.keys.clashWith(widget.action.id, binding);
    setState(() {
      // A fresh press replaces what was there; the Add button keeps both.
      if (!_adding) _bindings = [];
      if (!_bindings.contains(binding)) _bindings.add(binding);
      _adding = false;
      _clash = other == null
          ? ''
          : '${binding.label} is also ${other.label}. Both will answer to it '
                'where they are both live.';
    });
    return KeyEventResult.handled;
  }

  bool _adding = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.action.label),
      content: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (_, event) => _onKey(event),
        child: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _adding
                    ? 'Press the extra keys to add.'
                    : 'Press the keys to use.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_bindings.isEmpty)
                    Text('No keys', style: theme.textTheme.bodySmall),
                  for (final b in _bindings)
                    InputChip(
                      label: Text(b.label),
                      onDeleted: () => setState(() => _bindings.remove(b)),
                    ),
                ],
              ),
              if (_clash.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _clash,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() => _adding = true);
            _focus.requestFocus();
          },
          child: const Text('Add another'),
        ),
        TextButton(
          onPressed: () => setState(() {
            _bindings = List.of(widget.action.defaults);
            _clash = '';
          }),
          child: const Text('Default'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_bindings),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
