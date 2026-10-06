import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'keyboard_shortcuts.dart';

/// The Keyboard shortcuts section of Application Configuration: every
/// shortcut, what it does, its keys, and a way to change them.
///
/// Rebuilds only when the shortcuts change, and draws each one on a single
/// line with its help in a tooltip: the section is kept built while it is
/// shut, and a page of wrapped paragraphs was what made opening it stutter.
class KeyboardShortcutsSettings extends StatelessWidget {
  const KeyboardShortcutsSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final keys = context.select((AppStateProvider p) => p.shortcuts);
    final theme = Theme.of(context);
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Click a shortcut to change its keys. Drawing shortcuts work '
                  'on whatever is selected; on the signal flow, turn on Edit '
                  'first.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                key: const ValueKey('shortcuts_reset_all'),
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset all'),
                onPressed: keys.overrides.isEmpty
                    ? null
                    : () => context.read<AppStateProvider>().setShortcuts(
                        const KeyboardShortcuts(),
                      ),
              ),
            ],
          ),
          for (final area in ShortcutArea.values) ...[
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 4),
              child: Text(
                kShortcutAreaLabels[area]!.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 0.8,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  for (final (i, action) in kShortcutActions
                      .where((a) => a.area == area)
                      .indexed) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        color: theme.colorScheme.outlineVariant,
                      ),
                    _ShortcutRow(action: action, keys: keys),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
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
    final bindings = keys.bindingsFor(action.id);
    return InkWell(
      key: ValueKey('shortcut_${action.id}'),
      onTap: () => _change(context, provider),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // The name takes the free space, so the keys line up on the
            // right of every row.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      action.label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (action.help.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: action.help,
                      child: Icon(
                        Icons.info_outline,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (bindings.isEmpty)
              Text(
                'none',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.disabledColor,
                ),
              )
            else
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (i, b) in bindings.indexed) ...[
                    if (i > 0)
                      Text('or', style: theme.textTheme.bodySmall),
                    _KeyCombo(b, highlight: changed),
                  ],
                ],
              ),
            SizedBox(
              width: 36,
              height: 28,
              child: changed
                  ? IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      tooltip: 'Back to '
                          '${action.defaults.map((k) => k.label).join(' or ')}',
                      icon: const Icon(Icons.undo, size: 16),
                      onPressed: () =>
                          provider.setShortcuts(keys.reset(action.id)),
                    )
                  : null,
            ),
          ],
        ),
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

/// One key combination drawn as keycaps: Ctrl + Shift + S.
class _KeyCombo extends StatelessWidget {
  final KeyBinding binding;
  final bool highlight;
  const _KeyCombo(this.binding, {this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = binding.label.split('+');
    // "Ctrl+=" splits into an empty last part; put the plus back.
    if (binding.label.endsWith('+')) parts[parts.length - 1] = '+';
    Widget cap(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: highlight
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outline, width: 1.5),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          fontFamily: 'monospace',
          color: highlight ? theme.colorScheme.onPrimaryContainer : null,
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, p) in parts.where((p) => p.isNotEmpty).indexed) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text('+', style: theme.textTheme.bodySmall),
            ),
          cap(p),
        ],
      ],
    );
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
