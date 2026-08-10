import 'package:flutter/material.dart';

import 'av_flow_model.dart';

/// ============================================================================
///  CONNECTOR EDITOR ROW
/// ============================================================================
///  One editable port: name, signal type, direction, which edge of the box it
///  sits on, and the reorder/delete controls.
///
///  Shared by the two places a connector set gets edited — the AV Flow tab's
///  per-device dialog (this room's copy of the device) and the Device Editor
///  tab (the catalog entry every room starts from). They have to agree on
///  what a port is editable to, or a device would gain and lose connectors
///  depending on which screen you happened to open.
///
///  Connector order is the order the sockets are drawn down the side of the
///  box, so getting it to match the real panel is ordinary work — and doing
///  that a step at a time with two arrows is a lot of clicks for a sixteen-
///  input matrix. Grab the handle instead. The arrows stay for the single-step
///  nudge, which is still quicker than a drag.
/// ============================================================================

/// Row keys for a port list.
///
/// The port's own id, so a row's text field and focus travel with the port it
/// is editing when the list is reordered rather than staying at the index.
///
/// Repeats get a suffix, which matters more than it looks: a reorderable list
/// keys its children globally, so two rows claiming the same key is a crash
/// rather than a cosmetic mix-up — and these ids come out of a catalog file
/// people hand-edit.
List<Key> avPortRowKeys(List<AvPort> ports, {String prefix = ''}) {
  final seen = <String, int>{};
  return [
    for (final p in ports)
      ValueKey('$prefix${p.id}#${seen[p.id] = (seen[p.id] ?? 0) + 1}'),
  ];
}

class AvPortEditorRow extends StatelessWidget {
  final AvPort port;

  /// The room's signal palette, so the color dot matches the diagram.
  final Map<SignalType, Color>? palette;

  final ValueChanged<AvPort> onChanged;
  final VoidCallback onDelete;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  /// This row's index in the enclosing reorderable list, which is what a drag
  /// has to report. Null when the list is not reorderable — then no handle is
  /// drawn, because a grip that does nothing is worse than none.
  final int? dragIndex;

  const AvPortEditorRow({
    super.key,
    required this.port,
    required this.onChanged,
    required this.onDelete,
    this.palette,
    this.onMoveUp,
    this.onMoveDown,
    this.dragIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          if (dragIndex != null)
            ReorderableDragStartListener(
              index: dragIndex!,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Tooltip(
                  message: 'Drag to reorder',
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      Icons.drag_indicator,
                      size: 18,
                      color: Theme.of(context).disabledColor,
                    ),
                  ),
                ),
              ),
            ),
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: signalColor(port.signal, palette),
              shape: BoxShape.circle,
            ),
          ),
          // Flexible, not fixed: the fixed widths used to add up to more than
          // the dialog, which pushed the delete button off the right edge
          // where it could not be seen OR clicked.
          Expanded(
            child: AvPortLabelField(
              portId: port.id,
              initialLabel: port.label,
              onChanged: (v) => onChanged(port.copyWith(label: v)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<SignalType>(
              initialValue: port.signal,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final s in SignalType.values)
                  DropdownMenuItem(
                    value: s,
                    child: Text(
                      kSignalLabels[s] ?? s.name,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              onChanged: (v) =>
                  v == null ? null : onChanged(port.copyWith(signal: v)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 104,
            child: DropdownButtonFormField<PortDirection>(
              initialValue: port.direction,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: PortDirection.input,
                  child: Text('Input', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortDirection.output,
                  child: Text('Output', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortDirection.bidirectional,
                  child: Text('Both', style: TextStyle(fontSize: 12)),
                ),
              ],
              onChanged: (v) => v == null
                  ? null
                  : onChanged(
                      port.copyWith(
                        direction: v,
                        // Keep the box readable: an output that stays on the
                        // left reads as an input at a glance.
                        side: v == PortDirection.output
                            ? PortSide.right
                            : (port.side == PortSide.right
                                  ? PortSide.left
                                  : port.side),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: DropdownButtonFormField<PortSide>(
              initialValue: port.side,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: PortSide.left,
                  child: Text('Left', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortSide.right,
                  child: Text('Right', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortSide.top,
                  child: Text('Top', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortSide.bottom,
                  child: Text('Bottom', style: TextStyle(fontSize: 12)),
                ),
              ],
              onChanged: (v) =>
                  v == null ? null : onChanged(port.copyWith(side: v)),
            ),
          ),
          avRowIcon(Icons.arrow_upward, 'Move up', onMoveUp),
          avRowIcon(Icons.arrow_downward, 'Move down', onMoveDown),
          avRowIcon(
            Icons.delete_outline,
            'Delete connector',
            onDelete,
            danger: true,
          ),
        ],
      ),
    );
  }
}

/// Tight icon button for the editor rows — the stock 48px ones plus the
/// fields no longer fit across the dialog.
Widget avRowIcon(
  IconData icon,
  String tooltip,
  VoidCallback? onPressed, {
  bool danger = false,
}) {
  return IconButton(
    icon: Icon(icon, size: 18),
    color: danger ? Colors.red.shade400 : null,
    onPressed: onPressed,
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 34, height: 34),
  );
}

/// The connector editor's name field. It owns its controller so typing doesn't
/// rebuild the text out from under the cursor — the row above it rebuilds on
/// every keystroke to keep the live port list in sync.
class AvPortLabelField extends StatefulWidget {
  final String portId;
  final String initialLabel;
  final ValueChanged<String> onChanged;

  const AvPortLabelField({
    super.key,
    required this.portId,
    required this.initialLabel,
    required this.onChanged,
  });

  @override
  State<AvPortLabelField> createState() => _AvPortLabelFieldState();
}

class _AvPortLabelFieldState extends State<AvPortLabelField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialLabel,
  );

  @override
  void didUpdateWidget(covariant AvPortLabelField old) {
    super.didUpdateWidget(old);
    // Only when this row now represents a DIFFERENT port (Reset from library
    // replaces the whole list) — never on the user's own keystrokes.
    if (old.portId != widget.portId) {
      _controller.text = widget.initialLabel;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    decoration: const InputDecoration(
      isDense: true,
      border: OutlineInputBorder(),
    ),
    onChanged: widget.onChanged,
  );
}

/// A fresh connector with a unique id, for the "Add connector" buttons.
AvPort newAvPort({
  required int index,
  PortDirection direction = PortDirection.input,
  SignalType signal = SignalType.hdmi,
}) => AvPort(
  id: 'port_${DateTime.now().microsecondsSinceEpoch}',
  label: direction == PortDirection.output ? 'OUT ${index + 1}' : 'IN ${index + 1}',
  signal: signal,
  direction: direction,
  side: direction == PortDirection.output ? PortSide.right : PortSide.left,
);
