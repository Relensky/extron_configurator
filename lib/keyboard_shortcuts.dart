import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// ============================================================================
///  KEYBOARD SHORTCUTS
/// ============================================================================
///  Every shortcut the app answers, in one list, with the keys it starts
///  with. Anybody can change the keys in Application Configuration; what they
///  pick is kept in the app settings and read back here. The drawings ask
///  [KeyboardShortcuts.match] which action a key press is, rather than
///  testing keys themselves, so a changed key changes everywhere at once.
/// ============================================================================

/// One key, with the modifiers held down with it.
@immutable
class KeyBinding {
  final LogicalKeyboardKey key;
  final bool control;
  final bool shift;
  final bool alt;

  const KeyBinding(
    this.key, {
    this.control = false,
    this.shift = false,
    this.alt = false,
  });

  /// True when [event] is this key with exactly these modifiers. The Mac's
  /// Command key counts as Control.
  bool accepts(KeyEvent event) {
    if (event.logicalKey != key) return false;
    final keys = HardwareKeyboard.instance;
    return (keys.isControlPressed || keys.isMetaPressed) == control &&
        keys.isShiftPressed == shift &&
        keys.isAltPressed == alt;
  }

  SingleActivator get activator =>
      SingleActivator(key, control: control, shift: shift, alt: alt);

  /// "Ctrl+Shift+S".
  String get label => [
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    keyName(key),
  ].join('+');

  /// How it is written in the settings file.
  String get storage =>
      '${key.keyId}:${control ? 1 : 0}${shift ? 1 : 0}${alt ? 1 : 0}';

  static KeyBinding? fromStorage(String raw) {
    final parts = raw.split(':');
    if (parts.length != 2 || parts[1].length != 3) return null;
    final id = int.tryParse(parts[0]);
    if (id == null) return null;
    final key = LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id);
    return KeyBinding(
      key,
      control: parts[1][0] == '1',
      shift: parts[1][1] == '1',
      alt: parts[1][2] == '1',
    );
  }

  /// The key pressed in [event] with whatever modifiers are held, or null
  /// for a modifier on its own.
  static KeyBinding? fromEvent(KeyEvent event) {
    final key = event.logicalKey;
    if (_modifiers.contains(key)) return null;
    final keys = HardwareKeyboard.instance;
    return KeyBinding(
      key,
      control: keys.isControlPressed || keys.isMetaPressed,
      shift: keys.isShiftPressed,
      alt: keys.isAltPressed,
    );
  }

  static final Set<LogicalKeyboardKey> _modifiers = {
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  @override
  bool operator ==(Object other) =>
      other is KeyBinding &&
      other.key == key &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt;

  @override
  int get hashCode => Object.hash(key, control, shift, alt);
}

/// A key's name as people say it.
String keyName(LogicalKeyboardKey key) {
  const names = {
    'Arrow Left': 'Left',
    'Arrow Right': 'Right',
    'Arrow Up': 'Up',
    'Arrow Down': 'Down',
    'Escape': 'Esc',
  };
  final label = key.keyLabel.isNotEmpty
      ? key.keyLabel
      : (key.debugName ?? 'Key ${key.keyId}');
  final pretty = names[label] ?? label;
  return pretty.length == 1 ? pretty.toUpperCase() : pretty;
}

/// Where a shortcut works.
enum ShortcutArea { app, selection, cone }

const Map<ShortcutArea, String> kShortcutAreaLabels = {
  ShortcutArea.app: 'Anywhere',
  ShortcutArea.selection: 'Selected item on a drawing',
  ShortcutArea.cone: 'Selected device with a cone (floor plan)',
};

/// One thing a shortcut does.
class ShortcutAction {
  final String id;
  final String label;
  final ShortcutArea area;

  /// Where it works and what it does there, for the settings list.
  final String help;
  final List<KeyBinding> defaults;

  const ShortcutAction({
    required this.id,
    required this.label,
    required this.area,
    required this.defaults,
    this.help = '',
  });
}

/// Ids for the actions, so callers do not spell them.
abstract final class Shortcut {
  static const save = 'app.save';
  static const saveAll = 'app.saveAll';
  static const saveAs = 'app.saveAs';
  static const undo = 'app.undo';
  static const redo = 'app.redo';
  static const help = 'app.help';

  static const delete = 'sel.delete';
  static const deselect = 'sel.deselect';
  static const moveLeft = 'sel.moveLeft';
  static const moveRight = 'sel.moveRight';
  static const moveUp = 'sel.moveUp';
  static const moveDown = 'sel.moveDown';
  static const moveLeftFar = 'sel.moveLeftFar';
  static const moveRightFar = 'sel.moveRightFar';
  static const moveUpFar = 'sel.moveUpFar';
  static const moveDownFar = 'sel.moveDownFar';

  static const turnLeft = 'cone.turnLeft';
  static const turnRight = 'cone.turnRight';
  static const wider = 'cone.wider';
  static const narrower = 'cone.narrower';
  static const longer = 'cone.longer';
  static const shorter = 'cone.shorter';
  static const toggleCone = 'cone.toggle';

  static const moves = [
    moveLeft, moveRight, moveUp, moveDown,
    moveLeftFar, moveRightFar, moveUpFar, moveDownFar,
  ];
  static const cone = [
    turnLeft, turnRight, wider, narrower, longer, shorter, toggleCone,
  ];
}

typedef _K = LogicalKeyboardKey;

/// Every shortcut, in the order the settings page lists them.
const List<ShortcutAction> kShortcutActions = [
  ShortcutAction(
    id: Shortcut.save,
    label: 'Save',
    area: ShortcutArea.app,
    help: 'Saves the document the page you are on belongs to.',
    defaults: [KeyBinding(_K.keyS, control: true)],
  ),
  ShortcutAction(
    id: Shortcut.saveAll,
    label: 'Save all',
    area: ShortcutArea.app,
    help: 'Saves every open document that has changes.',
    defaults: [KeyBinding(_K.keyS, control: true, shift: true)],
  ),
  ShortcutAction(
    id: Shortcut.saveAs,
    label: 'Save as',
    area: ShortcutArea.app,
    defaults: [KeyBinding(_K.keyS, control: true, alt: true)],
  ),
  ShortcutAction(
    id: Shortcut.undo,
    label: 'Undo',
    area: ShortcutArea.app,
    help: 'Takes back the last change on this page\'s document.',
    defaults: [KeyBinding(_K.keyZ, control: true)],
  ),
  ShortcutAction(
    id: Shortcut.redo,
    label: 'Redo',
    area: ShortcutArea.app,
    defaults: [
      KeyBinding(_K.keyY, control: true),
      KeyBinding(_K.keyZ, control: true, shift: true),
    ],
  ),
  ShortcutAction(
    id: Shortcut.help,
    label: 'Help',
    area: ShortcutArea.app,
    defaults: [KeyBinding(_K.f1)],
  ),
  ShortcutAction(
    id: Shortcut.delete,
    label: 'Delete',
    area: ShortcutArea.selection,
    help: 'Floor plan: takes the device or mark-up off the sheet. Signal '
        'flow: removes the device and its cables. Rack: takes it out of the '
        'rack. Cabling: deletes or hides the box or run.',
    defaults: [KeyBinding(_K.delete), KeyBinding(_K.backspace)],
  ),
  ShortcutAction(
    id: Shortcut.deselect,
    label: 'Deselect',
    area: ShortcutArea.selection,
    defaults: [KeyBinding(_K.escape)],
  ),
  ShortcutAction(
    id: Shortcut.moveLeft,
    label: 'Move left',
    area: ShortcutArea.selection,
    help: 'A small step. On the cabling drawing, with a run selected, steps '
        'to the run before it.',
    defaults: [KeyBinding(_K.arrowLeft)],
  ),
  ShortcutAction(
    id: Shortcut.moveRight,
    label: 'Move right',
    area: ShortcutArea.selection,
    help: 'A small step. On the cabling drawing, with a run selected, steps '
        'to the next run.',
    defaults: [KeyBinding(_K.arrowRight)],
  ),
  ShortcutAction(
    id: Shortcut.moveUp,
    label: 'Move up',
    area: ShortcutArea.selection,
    help: 'A small step; one U in a rack.',
    defaults: [KeyBinding(_K.arrowUp)],
  ),
  ShortcutAction(
    id: Shortcut.moveDown,
    label: 'Move down',
    area: ShortcutArea.selection,
    help: 'A small step; one U in a rack.',
    defaults: [KeyBinding(_K.arrowDown)],
  ),
  ShortcutAction(
    id: Shortcut.moveLeftFar,
    label: 'Move left, far',
    area: ShortcutArea.selection,
    defaults: [KeyBinding(_K.arrowLeft, shift: true)],
  ),
  ShortcutAction(
    id: Shortcut.moveRightFar,
    label: 'Move right, far',
    area: ShortcutArea.selection,
    defaults: [KeyBinding(_K.arrowRight, shift: true)],
  ),
  ShortcutAction(
    id: Shortcut.moveUpFar,
    label: 'Move up, far',
    area: ShortcutArea.selection,
    help: 'Five U in a rack.',
    defaults: [KeyBinding(_K.arrowUp, shift: true)],
  ),
  ShortcutAction(
    id: Shortcut.moveDownFar,
    label: 'Move down, far',
    area: ShortcutArea.selection,
    help: 'Five U in a rack.',
    defaults: [KeyBinding(_K.arrowDown, shift: true)],
  ),
  ShortcutAction(
    id: Shortcut.turnLeft,
    label: 'Turn left 15°',
    area: ShortcutArea.cone,
    defaults: [KeyBinding(_K.bracketLeft)],
  ),
  ShortcutAction(
    id: Shortcut.turnRight,
    label: 'Turn right 15°',
    area: ShortcutArea.cone,
    defaults: [KeyBinding(_K.bracketRight)],
  ),
  ShortcutAction(
    id: Shortcut.wider,
    label: 'Widen the cone 5°',
    area: ShortcutArea.cone,
    defaults: [KeyBinding(_K.period)],
  ),
  ShortcutAction(
    id: Shortcut.narrower,
    label: 'Narrow the cone 5°',
    area: ShortcutArea.cone,
    defaults: [KeyBinding(_K.comma)],
  ),
  ShortcutAction(
    id: Shortcut.longer,
    label: 'Longer reach',
    area: ShortcutArea.cone,
    help: 'One foot on a scaled sheet.',
    defaults: [KeyBinding(_K.equal)],
  ),
  ShortcutAction(
    id: Shortcut.shorter,
    label: 'Shorter reach',
    area: ShortcutArea.cone,
    help: 'One foot on a scaled sheet.',
    defaults: [KeyBinding(_K.minus)],
  ),
  ShortcutAction(
    id: Shortcut.toggleCone,
    label: 'Show or hide the cone',
    area: ShortcutArea.cone,
    defaults: [KeyBinding(_K.keyV)],
  ),
];

ShortcutAction? shortcutAction(String id) =>
    kShortcutActions.where((a) => a.id == id).firstOrNull;

/// The keys in use: the defaults, with whatever somebody changed on top.
/// Immutable; a change makes a new one, so a widget can tell it changed.
@immutable
class KeyboardShortcuts {
  /// Action id -> the keys somebody picked. An empty list turns it off.
  final Map<String, List<KeyBinding>> overrides;

  const KeyboardShortcuts([this.overrides = const {}]);

  List<KeyBinding> bindingsFor(String id) =>
      overrides[id] ?? shortcutAction(id)?.defaults ?? const [];

  bool isChanged(String id) => overrides.containsKey(id);

  /// "Ctrl+Y or Ctrl+Shift+Z", or "none".
  String labelFor(String id) {
    final keys = bindingsFor(id);
    return keys.isEmpty ? 'none' : keys.map((k) => k.label).join(' or ');
  }

  /// The first of [ids] that [event] is a press of, or null.
  String? match(KeyEvent event, Iterable<String> ids) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    for (final id in ids) {
      if (bindingsFor(id).any((k) => k.accepts(event))) return id;
    }
    return null;
  }

  /// Another action already on [binding], where the two could both be live.
  /// App shortcuts work everywhere, so they clash with anything; selection
  /// and cone shortcuts are both live on a selected floor plan device.
  ShortcutAction? clashWith(String id, KeyBinding binding) {
    for (final a in kShortcutActions) {
      if (a.id == id) continue;
      if (bindingsFor(a.id).contains(binding)) return a;
    }
    return null;
  }

  KeyboardShortcuts withBindings(String id, List<KeyBinding> keys) {
    final next = Map<String, List<KeyBinding>>.of(overrides);
    final defaults = shortcutAction(id)?.defaults ?? const [];
    if (listEquals(keys, defaults)) {
      next.remove(id);
    } else {
      next[id] = List.unmodifiable(keys);
    }
    return KeyboardShortcuts(Map.unmodifiable(next));
  }

  KeyboardShortcuts reset(String id) => withBindings(
    id,
    shortcutAction(id)?.defaults ?? const [],
  );

  Map<String, dynamic> toJson() => {
    for (final e in overrides.entries)
      e.key: [for (final k in e.value) k.storage],
  };

  factory KeyboardShortcuts.fromJson(Object? json) {
    if (json is! Map) return const KeyboardShortcuts();
    final out = <String, List<KeyBinding>>{};
    json.forEach((id, raw) {
      if (shortcutAction(id.toString()) == null || raw is! List) return;
      out[id.toString()] = List.unmodifiable([
        for (final r in raw) ?KeyBinding.fromStorage(r.toString()),
      ]);
    });
    return KeyboardShortcuts(Map.unmodifiable(out));
  }
}
