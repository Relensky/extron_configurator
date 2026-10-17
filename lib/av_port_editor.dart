import 'package:material_ui/material_ui.dart';

import 'av_flow_model.dart';
import 'print_mode.dart';

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
/// What one [avRowIcon] takes across a table row.
///
/// The button is CONSTRAINED to 34 and lays out at this — measured, because
/// the caption row above it reserves the same figure by hand and the two have
/// to agree. See `test/cost_header_alignment_test.dart`.
const double kRowIconWidth = 40.0;

Widget avRowIcon(
  IconData icon,
  String tooltip,
  VoidCallback? onPressed, {
  bool danger = false,
}) {
  return Builder(
    builder: (context) {
      // Being photographed. The column still has to be there or every row
      // above and below shifts left and the table stops lining up — it just
      // has to be empty.
      //
      // [kRowIconWidth], not the 34 the button is CONSTRAINED to: an
      // IconButton lays out wider than its constraints, and a placeholder at
      // 34 made every captured table 6 pixels per icon narrower on the right
      // than the caption row above it — which is the whole misalignment,
      // spread across the flexible columns in the middle.
      if (PrintMode.of(context)) {
        return const SizedBox(width: kRowIconWidth, height: 34);
      }
      return IconButton(
        icon: Icon(icon, size: 18),
        color: danger ? Colors.red.shade400 : null,
        onPressed: onPressed,
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      );
    },
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

/// The name a run of [signal] connectors is given before anybody types one.
String bulkPortDefaultName(SignalType signal) =>
    signal == SignalType.network ? 'LAN' : (kSignalCodes[signal] ?? 'PORT');

/// [count] connectors named `[name] [start]` upward, all of one signal,
/// direction and side. Ids are unique against [existingIds] and each other.
List<AvPort> bulkAvPorts({
  required int count,
  required String name,
  required SignalType signal,
  required PortDirection direction,
  required PortSide side,
  int start = 1,
  Iterable<String> existingIds = const [],
}) {
  final label = name.trim().isEmpty ? bulkPortDefaultName(signal) : name.trim();
  final slug = label.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
  final prefix = switch (direction) {
    PortDirection.input => 'in',
    PortDirection.output => 'out',
    PortDirection.bidirectional => 'io',
  };
  final taken = existingIds.toSet();
  final out = <AvPort>[];
  for (var i = 0; i < count; i++) {
    final n = start + i;
    var id = '${prefix}_${slug}_$n';
    for (var k = 2; taken.contains(id); k++) {
      id = '${prefix}_${slug}_${n}_$k';
    }
    taken.add(id);
    out.add(AvPort(
      id: id,
      label: '$label $n',
      signal: signal,
      direction: direction,
      side: side,
    ));
  }
  return out;
}

/// Asks how many connectors to add and what they are, for a 48-port switch
/// or a 16-input matrix. Null when cancelled.
Future<List<AvPort>?> showBulkPortDialog(
  BuildContext context, {
  required List<AvPort> existing,
}) => showDialog<List<AvPort>>(
  context: context,
  builder: (_) => _BulkPortDialog(existing: existing),
);

class _BulkPortDialog extends StatefulWidget {
  final List<AvPort> existing;
  const _BulkPortDialog({required this.existing});

  @override
  State<_BulkPortDialog> createState() => _BulkPortDialogState();
}

class _BulkPortDialogState extends State<_BulkPortDialog> {
  final _count = TextEditingController(text: '8');
  final _name = TextEditingController(
    text: bulkPortDefaultName(SignalType.network),
  );
  final _start = TextEditingController(text: '1');
  SignalType _signal = SignalType.network;
  PortDirection _direction = PortDirection.bidirectional;
  PortSide _side = PortSide.left;
  // The name follows the type until somebody types their own.
  bool _nameTyped = false;

  /// Highest count accepted, so a typo of 4800 cannot hang the editor.
  static const int kMax = 512;

  @override
  void dispose() {
    _count.dispose();
    _name.dispose();
    _start.dispose();
    super.dispose();
  }

  int? get _countValue {
    final n = int.tryParse(_count.text.trim());
    return n == null || n < 1 || n > kMax ? null : n;
  }

  int get _startValue => int.tryParse(_start.text.trim()) ?? 1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = _countValue;
    final ports = count == null
        ? const <AvPort>[]
        : bulkAvPorts(
            count: count,
            name: _name.text,
            signal: _signal,
            direction: _direction,
            side: _side,
            start: _startValue,
            existingIds: widget.existing.map((p) => p.id),
          );
    InputDecoration deco(String label) => InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
    );
    return AlertDialog(
      title: const Text('Add several connectors'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    key: const ValueKey('bulk_port_count'),
                    controller: _count,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: deco('How many').copyWith(
                      errorText: count == null ? '1 to $kMax' : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('bulk_port_name'),
                    controller: _name,
                    decoration: deco('Name'),
                    onChanged: (_) => setState(() => _nameTyped = true),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 90,
                  child: TextField(
                    key: const ValueKey('bulk_port_start'),
                    controller: _start,
                    keyboardType: TextInputType.number,
                    decoration: deco('Start at'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SignalType>(
              key: const ValueKey('bulk_port_signal'),
              initialValue: _signal,
              isExpanded: true,
              decoration: deco('Type'),
              items: [
                for (final s in SignalType.values)
                  DropdownMenuItem(
                    value: s,
                    child: Text(kSignalLabels[s] ?? s.name),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _signal = v;
                  if (!_nameTyped) _name.text = bulkPortDefaultName(v);
                });
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<PortDirection>(
                    key: const ValueKey('bulk_port_direction'),
                    initialValue: _direction,
                    isExpanded: true,
                    decoration: deco('Direction'),
                    items: const [
                      DropdownMenuItem(
                        value: PortDirection.input,
                        child: Text('Input'),
                      ),
                      DropdownMenuItem(
                        value: PortDirection.output,
                        child: Text('Output'),
                      ),
                      DropdownMenuItem(
                        value: PortDirection.bidirectional,
                        child: Text('Both (in and out)'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        _direction = v;
                        // Same rule as the row editor: outputs sit right.
                        if (v == PortDirection.output) {
                          _side = PortSide.right;
                        } else if (_side == PortSide.right) {
                          _side = PortSide.left;
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<PortSide>(
                    // Keyed on the value so a direction change redraws it.
                    key: ValueKey('bulk_port_side_${_side.name}'),
                    initialValue: _side,
                    isExpanded: true,
                    decoration: deco('Location'),
                    items: const [
                      DropdownMenuItem(value: PortSide.left, child: Text('Left')),
                      DropdownMenuItem(
                        value: PortSide.right,
                        child: Text('Right'),
                      ),
                      DropdownMenuItem(value: PortSide.top, child: Text('Top')),
                      DropdownMenuItem(
                        value: PortSide.bottom,
                        child: Text('Bottom'),
                      ),
                    ],
                    onChanged: (v) =>
                        v == null ? null : setState(() => _side = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              ports.isEmpty
                  ? 'Nothing to add yet.'
                  : ports.length == 1
                  ? 'Adds ${ports.first.label}.'
                  : 'Adds ${ports.length}: ${ports.first.label} to '
                        '${ports.last.label}.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('bulk_port_add'),
          onPressed: ports.isEmpty ? null : () => Navigator.pop(context, ports),
          child: Text(ports.isEmpty ? 'Add' : 'Add ${ports.length}'),
        ),
      ],
    );
  }
}
