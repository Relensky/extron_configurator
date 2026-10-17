import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_ties.dart';

/// Tie in sequence: pick two sides and a connector on each, check the list,
/// and draw it as one Undo step. Returns how many runs were drawn.
Future<int> showTieInSequenceDialog(
  BuildContext context,
  AppStateProvider provider, {
  String? fromKey,
  String? toKey,
}) async {
  final sides = tieSides(provider);
  if (sides.length < 2) return 0;
  TieSide side(String? key, TieSide fallback) =>
      sides.where((s) => s.key == key).firstOrNull ?? fallback;
  final groups = sides.where((s) => !s.isSingle).toList();
  var from = side(fromKey, groups.isNotEmpty ? groups.first : sides.first);
  var to = side(
      toKey,
      groups.length > 1
          ? groups[1]
          : sides.firstWhere((s) => s.key != from.key));
  TieConnector? fromConn, toConn;
  var fromStart = 0, toStart = 0;
  var byNumber = true;
  var skip = <int>{};

  TieConnector? pickConn(TieSide s, bool sending, TieConnector? keep) {
    final list = tieConnectors(s, sending: sending);
    return list.where((c) => c.key == keep?.key).firstOrNull ??
        list.firstOrNull;
  }

  fromConn = pickConn(from, true, null);
  toConn = pickConn(to, false, null);
  // The receiving side starts on a connector of the same kind when it has one.
  final same = tieConnectors(to, sending: false)
      .where((c) => c.signal == fromConn?.signal)
      .firstOrNull;
  if (same != null) toConn = same;

  final drawn = await showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      final ties = fromConn == null || toConn == null
          ? const <PlannedTie>[]
          : planTies(provider,
              from: from,
              fromConnector: fromConn!,
              to: to,
              toConnector: toConn!,
              byNumber: byNumber,
              fromStart: fromStart,
              toStart: toStart);
      final picked = [
        for (final (i, t) in ties.indexed)
          if (!t.alreadyTied && !skip.contains(i)) t,
      ];

      Widget sidePicker(String label, bool sending) {
        final current = sending ? from : to;
        final conns = tieConnectors(current, sending: sending);
        final conn = sending ? fromConn : toConn;
        // The run's own connector names, for a start drop-down.
        final runPorts = !current.isSingle || conn == null
            ? const <AvPort>[]
            : tieRunPorts(current, conn, sending: sending);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              key: ValueKey('tie_${sending ? 'from' : 'to'}_side'),
              initialValue: current.key,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Boxes', isDense: true),
              items: [
                for (final s in sides)
                  DropdownMenuItem(
                    value: s.key,
                    child: Text(
                        s.isSingle ? s.label : '${s.label} - named in order',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (k) => setLocal(() {
                final s = sides.firstWhere((x) => x.key == k);
                skip = {};
                if (sending) {
                  from = s;
                  fromConn = pickConn(s, true, fromConn);
                  fromStart = 0;
                } else {
                  to = s;
                  toConn = pickConn(s, false, toConn);
                  toStart = 0;
                }
              }),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey(
                  'tie_${sending ? 'from' : 'to'}_conn_${current.key}'),
              initialValue: conn?.key,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: sending ? 'Output' : 'Input', isDense: true),
              items: [
                for (final c in conns)
                  DropdownMenuItem(
                    value: c.key,
                    child: Text(
                        '${c.label} - ${kSignalLabels[c.signal] ?? c.signal.name}',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (k) => setLocal(() {
                skip = {};
                final c = conns.firstWhere((x) => x.key == k);
                if (sending) {
                  fromConn = c;
                  fromStart = 0;
                } else {
                  toConn = c;
                  toStart = 0;
                }
              }),
            ),
            if (runPorts.length > 1) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                key: ValueKey(
                    'tie_${sending ? 'from' : 'to'}_start_${conn?.key}'),
                initialValue: sending ? fromStart : toStart,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Starting at', isDense: true),
                items: [
                  for (final (i, p) in runPorts.indexed)
                    DropdownMenuItem(value: i, child: Text(p.label)),
                ],
                onChanged: (v) => setLocal(() {
                  skip = {};
                  if (sending) {
                    fromStart = v ?? 0;
                  } else {
                    toStart = v ?? 0;
                  }
                }),
              ),
            ],
          ],
        );
      }

      final scheme = Theme.of(ctx).colorScheme;
      return AlertDialog(
        title: const Text('Tie in sequence'),
        content: SizedBox(
          width: 760,
          height: math.min(640, MediaQuery.sizeOf(ctx).height - 200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: sidePicker('From', true)),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 40, 12, 0),
                    child: Icon(Icons.arrow_forward),
                  ),
                  Expanded(child: sidePicker('To', false)),
                ],
              ),
              if (!from.isSingle && !to.isSingle)
                SwitchListTile(
                  key: const ValueKey('tie_by_number'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: byNumber,
                  onChanged: (v) => setLocal(() {
                    skip = {};
                    byNumber = v;
                  }),
                  title: const Text('Pair by the number in their names'),
                  subtitle: Text(byNumber
                      ? 'Station 3 goes to Decoder 3'
                      : 'In order: first to first, second to second'),
                ),
              if (fromConn != null &&
                  toConn != null &&
                  fromConn!.signal != toConn!.signal)
                Text(
                  'The two connectors carry different signals; an adapter '
                  'sits in each run.',
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              const Divider(),
              Expanded(
                child: ties.isEmpty
                    ? const Center(
                        child: Text('Nothing to pair with these choices.'))
                    : ListView(
                        children: [
                          for (final (i, t) in ties.indexed)
                            CheckboxListTile(
                              key: ValueKey('tie_row_$i'),
                              dense: true,
                              value: !t.alreadyTied && !skip.contains(i),
                              onChanged: t.alreadyTied
                                  ? null
                                  : (v) => setLocal(() => v == true
                                      ? skip.remove(i)
                                      : skip.add(i)),
                              title: Text(
                                  '${t.from.label} (${t.fromPort.label}) → '
                                  '${t.to.label} (${t.toPort.label})'),
                              subtitle: t.alreadyTied
                                  ? const Text('Already tied')
                                  : t.replaces.isEmpty
                                      ? null
                                      : Text(
                                          'Replaces ${t.replaces.join(', ')}',
                                          style: TextStyle(
                                              color: scheme.error,
                                              fontSize: 12),
                                        ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(0),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            key: const ValueKey('tie_go'),
            onPressed: picked.isEmpty
                ? null
                : () => Navigator.of(ctx).pop(provider.applyAvTies([
                      for (final t in picked)
                        (
                          fromNode: t.from.id,
                          fromPort: t.fromPort.id,
                          toNode: t.to.id,
                          toPort: t.toPort.id,
                          signal: t.fromPort.signal,
                        ),
                    ])),
            child: Text('Tie ${picked.length}'),
          ),
        ],
      );
    }),
  );
  return drawn ?? 0;
}

/// A power strip's outlets, each with a drop-down of every box with a power
/// inlet, and Fill in order for a set named in sequence. Saved as one Undo
/// step. Returns how many leads changed.
Future<int> showPowerOutletsDialog(
  BuildContext context,
  AppStateProvider provider, {
  String? stripId,
}) async {
  final strips = powerStrips(provider);
  if (strips.isEmpty) return 0;
  var strip = strips.where((s) => s.id == stripId).firstOrNull ?? strips.first;
  final powered = poweredBoxes(provider);
  final sets = tieSides(provider).where((s) => !s.isSingle).toList();

  Map<String, String?> current(AvNode s) => {
        for (final o in stripOutlets(s)) o.id: outletTarget(provider, s, o),
      };
  var feeds = current(strip);
  var original = Map<String, String?>.from(feeds);
  String? fillSet = sets.firstOrNull?.key;
  var fillFrom = 0;

  final changed = await showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      final outlets = stripOutlets(strip);
      final boxes = [
        for (final b in powered)
          if (b.node.id != strip.id) b.node,
      ];
      void assign(String outlet, String? box) {
        if (box != null) {
          // One inlet per box: it comes off any other outlet here.
          for (final k in feeds.keys.toList()) {
            if (k != outlet && feeds[k] == box) feeds[k] = null;
          }
        }
        feeds[outlet] = box;
      }

      final edits = {
        for (final e in feeds.entries)
          if (original[e.key] != e.value) e.key: e.value,
      };
      return AlertDialog(
        title: const Text('Power outlets'),
        content: SizedBox(
          width: 640,
          height: math.min(640, MediaQuery.sizeOf(ctx).height - 200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('power_strip'),
                initialValue: strip.id,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Power strip', isDense: true),
                items: [
                  for (final s in strips)
                    DropdownMenuItem(
                      value: s.id,
                      child: Text(
                          '${s.label} (${stripOutlets(s).length} outlets)',
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (id) => setLocal(() {
                  strip = strips.firstWhere((s) => s.id == id);
                  feeds = current(strip);
                  original = Map.of(feeds);
                  fillFrom = 0;
                }),
              ),
              if (sets.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey('power_fill_set'),
                        initialValue: fillSet,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Fill in order with', isDense: true),
                        items: [
                          for (final s in sets)
                            DropdownMenuItem(
                                value: s.key,
                                child: Text(s.label,
                                    overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: (k) => setLocal(() => fillSet = k),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<int>(
                        key: ValueKey('power_fill_from_${strip.id}'),
                        initialValue: fillFrom,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Starting at', isDense: true),
                        items: [
                          for (final (i, o) in outlets.indexed)
                            DropdownMenuItem(value: i, child: Text(o.label)),
                        ],
                        onChanged: (v) => setLocal(() => fillFrom = v ?? 0),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      key: const ValueKey('power_fill_go'),
                      onPressed: fillSet == null
                          ? null
                          : () => setLocal(() {
                                final set =
                                    sets.firstWhere((s) => s.key == fillSet);
                                final members = [
                                  for (final n in set.boxes)
                                    if (boxes.any((b) => b.id == n.id)) n,
                                ];
                                for (var i = 0;
                                    i < members.length &&
                                        fillFrom + i < outlets.length;
                                    i++) {
                                  assign(outlets[fillFrom + i].id,
                                      members[i].id);
                                }
                              }),
                      child: const Text('Fill'),
                    ),
                  ],
                ),
              ],
              const Divider(),
              Expanded(
                child: ListView(
                  children: [
                    for (final o in outlets)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 150,
                              child: Text(o.label,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                key: ValueKey(
                                    'power_outlet_${o.id}_${feeds[o.id]}'),
                                initialValue: feeds[o.id],
                                isExpanded: true,
                                decoration: InputDecoration(
                                  isDense: true,
                                  helperText: original[o.id] != feeds[o.id]
                                      ? 'Changed'
                                      : null,
                                ),
                                items: [
                                  const DropdownMenuItem<String>(
                                      value: null, child: Text('Nothing')),
                                  for (final b in boxes)
                                    DropdownMenuItem(
                                      value: b.id,
                                      child: Text(b.label,
                                          overflow: TextOverflow.ellipsis),
                                    ),
                                ],
                                onChanged: (v) =>
                                    setLocal(() => assign(o.id, v)),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(0),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            key: const ValueKey('power_save'),
            onPressed: edits.isEmpty
                ? null
                : () => Navigator.of(ctx)
                    .pop(provider.setAvStripOutlets(strip.id, edits)),
            child: Text(edits.isEmpty
                ? 'Save'
                : 'Save ${edits.length} change${edits.length == 1 ? '' : 's'}'),
          ),
        ],
      );
    }),
  );
  return changed ?? 0;
}
