import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'sideways_scroll.dart';

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
enum ShortcutArea { app, text, page, selection, cone }

const Map<ShortcutArea, String> kShortcutAreaLabels = {
  ShortcutArea.app: 'Anywhere',
  ShortcutArea.text: 'In a text box',
  ShortcutArea.page: 'Nothing selected',
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
  static const find = 'app.find';

  static const nextBox = 'text.nextBox';
  static const previousBox = 'text.previousBox';
  static const lineUp = 'text.lineUp';
  static const lineDown = 'text.lineDown';
  static const textTop = 'text.top';
  static const textBottom = 'text.bottom';

  static const scrollLeft = 'page.scrollLeft';
  static const scrollRight = 'page.scrollRight';

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
    id: Shortcut.find,
    label: 'Find on page',
    area: ShortcutArea.app,
    help: 'Searches the text on screen and jumps to each match. Enter or F3 '
        'goes to the next, Shift+Enter or Shift+F3 the one before, Esc '
        'closes it.',
    defaults: [KeyBinding(_K.keyF, control: true)],
  ),
  ShortcutAction(
    id: Shortcut.nextBox,
    label: 'Next box',
    area: ShortcutArea.text,
    help: 'Moves to the next box, button or list on the page.',
    defaults: [KeyBinding(_K.tab)],
  ),
  ShortcutAction(
    id: Shortcut.previousBox,
    label: 'Previous box',
    area: ShortcutArea.text,
    defaults: [KeyBinding(_K.tab, shift: true)],
  ),
  ShortcutAction(
    id: Shortcut.lineUp,
    label: 'Up a line',
    area: ShortcutArea.text,
    help: 'In a box of more than one line. In a one-line box, goes to the '
        'start.',
    defaults: [KeyBinding(_K.arrowUp)],
  ),
  ShortcutAction(
    id: Shortcut.lineDown,
    label: 'Down a line',
    area: ShortcutArea.text,
    help: 'In a box of more than one line. In a one-line box, goes to the '
        'end.',
    defaults: [KeyBinding(_K.arrowDown)],
  ),
  ShortcutAction(
    id: Shortcut.textTop,
    label: 'Top of the box',
    area: ShortcutArea.text,
    help: 'Jumps to the start of the text. Shift+Home still selects to the '
        'start of the line.',
    defaults: [KeyBinding(_K.home)],
  ),
  ShortcutAction(
    id: Shortcut.textBottom,
    label: 'Bottom of the box',
    area: ShortcutArea.text,
    help: 'Jumps to the end of the text. Shift+End still selects to the end '
        'of the line.',
    defaults: [KeyBinding(_K.end)],
  ),
  ShortcutAction(
    id: Shortcut.scrollLeft,
    label: 'Scroll left',
    area: ShortcutArea.page,
    help: 'A table or page wider than the window: the one under the pointer. '
        'Shift and the mouse wheel do the same.',
    defaults: [KeyBinding(_K.arrowLeft)],
  ),
  ShortcutAction(
    id: Shortcut.scrollRight,
    label: 'Scroll right',
    area: ShortcutArea.page,
    defaults: [KeyBinding(_K.arrowRight)],
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
  /// and cone shortcuts are both live on a selected floor plan device. A text
  /// box has the keys while it is being typed in, so its shortcuts never meet
  /// the drawings'.
  ShortcutAction? clashWith(String id, KeyBinding binding) {
    final area = shortcutAction(id)?.area;
    // Typing, nothing selected and something selected never overlap; a
    // selected floor plan device has both its move and its cone keys.
    int group(ShortcutArea a) => switch (a) {
      ShortcutArea.text => 1,
      ShortcutArea.page => 2,
      ShortcutArea.selection || ShortcutArea.cone => 3,
      ShortcutArea.app => 0,
    };
    bool bothLive(ShortcutArea a, ShortcutArea b) =>
        group(a) == 0 || group(b) == 0 || group(a) == group(b);
    for (final a in kShortcutActions) {
      if (a.id == id) continue;
      if (area != null && !bothLive(area, a.area)) continue;
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

/// The text-box shortcuts and what each does.
const List<(String, Intent)> _textIntents = [
  (Shortcut.nextBox, NextFocusIntent()),
  (Shortcut.previousBox, PreviousFocusIntent()),
  (Shortcut.lineUp, TextLineIntent(forward: false)),
  (Shortcut.lineDown, TextLineIntent(forward: true)),
  (
    Shortcut.textTop,
    ExtendSelectionToDocumentBoundaryIntent(
      forward: false,
      collapseSelection: true,
    ),
  ),
  (
    Shortcut.textBottom,
    ExtendSelectionToDocumentBoundaryIntent(
      forward: true,
      collapseSelection: true,
    ),
  ),
];

/// The "In a text box" keys as a [Shortcuts] map. Placed below WidgetsApp's
/// own text keys so these win; with no text box focused nothing answers them
/// and the key carries on up.
Map<ShortcutActivator, Intent> textBoxShortcuts(KeyboardShortcuts keys) => {
  for (final (id, intent) in _textIntents)
    for (final k in keys.bindingsFor(id)) k.activator: intent,
  for (final k in keys.bindingsFor(Shortcut.scrollLeft))
    k.activator: const ScrollSidewaysIntent(right: false),
  for (final k in keys.bindingsFor(Shortcut.scrollRight))
    k.activator: const ScrollSidewaysIntent(right: true),
};

/// The actions behind [textBoxShortcuts] that Flutter does not supply.
final Map<Type, Action<Intent>> textBoxActions = {
  TextLineIntent: TextLineAction(),
  ScrollSidewaysIntent: ScrollSidewaysAction(),
};

/// Up or down a line in the focused text box.
class TextLineIntent extends Intent {
  final bool forward;
  const TextLineIntent({required this.forward});
}

/// Moves the caret a line in the focused text box.
///
/// Flutter's own line action breaks inside a SelectionArea (the Cost page
/// has one): the area overrides it and the override throws, so Up and Down
/// did nothing in Scope of Work. This moves the caret itself instead.
class TextLineAction extends Action<TextLineIntent> {
  static EditableTextState? _focused() {
    final context = primaryFocus?.context;
    if (context == null) return null;
    if (context is StatefulElement && context.state is EditableTextState) {
      return context.state as EditableTextState;
    }
    return context.findAncestorStateOfType<EditableTextState>();
  }

  @override
  bool isEnabled(TextLineIntent intent) {
    final state = _focused();
    return state != null && state.textEditingValue.selection.isValid;
  }

  @override
  Object? invoke(TextLineIntent intent) {
    final state = _focused();
    if (state == null) return null;
    final value = state.textEditingValue;
    final selection = value.selection;
    if (!selection.isValid) return null;
    final from = TextPosition(
      offset: intent.forward ? selection.end : selection.start,
      affinity: selection.affinity,
    );
    final render = state.renderEditable;
    var to = intent.forward
        ? render.getTextPositionBelow(from)
        : render.getTextPositionAbove(from);
    // No line there: to the start or end, as Flutter does.
    if (to.offset == from.offset) {
      to = TextPosition(offset: intent.forward ? value.text.length : 0);
    }
    state.userUpdateTextEditingValue(
      value.copyWith(
        selection: TextSelection.fromPosition(to),
      ),
      SelectionChangedCause.keyboard,
    );
    state.bringIntoView(to);
    return null;
  }
}
