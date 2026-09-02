import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'av_flow_model.dart' show kCableSwatches;
import 'av_flow_view.dart' show buildAvFlowModel;
import 'cabling_schematic.dart';
import 'color_wheel_picker.dart';

/// ============================================================================
///  WHAT COLOR EACH CABLE IS
/// ============================================================================
///  The Schematic tab has had a "Colors" button on its toolbar for as long as
///  it has had lines: one dialog, every kind of link, set them and be done.
///  The two sheets the trades are actually handed — the Cabling drawing and
///  the Floor Plan — had no such thing. A color could only be changed by
///  selecting one run and using the swatches in the selection bar, which is
///  the wrong shape for the job: "make all the network runs blue" is a
///  decision about a cable TYPE, not about the run somebody happens to have
///  clicked, and doing it run by run is how a sheet ends up with three shades
///  of network on it.
///
///  So both pages get the same button, and it writes what the drawing reads:
///  a color per cable type ([AppStateProvider.setCablingTypeColor]), which
///  every run of that type on every sheet then follows.
///
///  Laid out like the signal flow's "Signal colors" dialog, down to the swatch
///  spacing, the reset icons and the "Reset all": the same job on a different
///  sheet should not be a different-looking dialog.
/// ============================================================================

/// The cable types on [drawing], each with the color its runs are drawn in
/// and the keys a color has to be written under.
///
/// Plural keys because one cable type can be pulled under more than one
/// category — AV Cat 6a and network Cat 6a are different pulls the key colors
/// apart — while a person setting colors is thinking about "Cat 6a".
List<({String type, Color color, Set<String> keys})> cablingTypesIn(
  CablingSchematic drawing,
) {
  final colors = <String, Color>{};
  final keys = <String, Set<String>>{};
  for (final b in drawing.bundles) {
    final type = b.cableType.trim().isEmpty ? 'Cable' : b.cableType.trim();
    colors.putIfAbsent(type, () => Color(b.color));
    keys.putIfAbsent(type, () => <String>{}).add(cablingColorKey(b));
  }
  final names = colors.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final t in names) (type: t, color: colors[t]!, keys: keys[t]!),
  ];
}

/// Sets the color of every cable type in the room.
///
/// Shared by the Cabling and Floor Plan tabs so the button does the same thing
/// on both, and so a color set on one sheet is the color on the other — they
/// are two drawings of one room's cable, and a network run that is blue on the
/// plan and green on the cabling sheet is two drawings nobody can read
/// together.
///
/// The drawing is re-derived on every rebuild rather than handed in once when
/// the dialog opens. A snapshot went stale the moment a swatch was picked: the
/// tick stayed on the old color until the dialog was closed and opened again,
/// even though the sheet underneath had already changed. Rebuilding is what
/// the signal-flow palette does, and it is why that one moves as it is
/// clicked.
Future<void> showCableColorsDialog(
  BuildContext context,
  AppStateProvider provider,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final theme = Theme.of(ctx);
        final types = cablingTypesIn(
          provider.cablingSchematic(buildAvFlowModel(provider)),
        );

        return AlertDialog(
          title: const Text('Cable colors'),
          content: SizedBox(
            width: 520,
            height: types.isEmpty
                ? null
                : math.min(560, MediaQuery.of(ctx).size.height - 220),
            child: types.isEmpty
                ? Text(
                    'No cable runs on this drawing yet. Name the places in the '
                    'room, say which place each device is in, and the runs '
                    'between them are counted off the signal flow.',
                    style: theme.textTheme.bodySmall,
                  )
                : ListView(
                    children: [
                      Text(
                        'One color per cable type, used by every run of it on '
                        'the cabling sheet and the floor plan. A run with a '
                        'color of its own keeps it.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      for (final t in types)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 168,
                                child: Text(
                                  t.type,
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Expanded(
                                child: Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: [
                                    for (final c in kCableSwatches)
                                      ColorSwatchButton(
                                        key: ValueKey(
                                          'cable_type_color_${t.type}_'
                                          '${(c.toARGB32() & 0xFFFFFF).toRadixString(16)}',
                                        ),
                                        color: c,
                                        width: 24,
                                        height: 20,
                                        selected:
                                            t.color.toARGB32() == c.toARGB32(),
                                        onTap: () => setLocal(
                                          () => provider.setCablingTypeColor(
                                            t.keys,
                                            c.toARGB32(),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.colorize, size: 16),
                                tooltip: 'Pick a custom color',
                                visualDensity: VisualDensity.compact,
                                onPressed: () async {
                                  final picked = await showColorWheelDialog(
                                    ctx,
                                    initial: t.color,
                                    title: 'Color for ${t.type}',
                                  );
                                  if (picked == null) return;
                                  setLocal(
                                    () => provider.setCablingTypeColor(
                                      t.keys,
                                      picked.toARGB32(),
                                    ),
                                  );
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.restart_alt, size: 16),
                                tooltip: 'Back to the color the key gives '
                                    'this cable',
                                visualDensity: VisualDensity.compact,
                                onPressed: provider.hasCablingTypeColor(t.keys)
                                    ? () => setLocal(
                                          () => provider.setCablingTypeColor(
                                            t.keys,
                                            null,
                                          ),
                                        )
                                    : null,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  setLocal(() => provider.resetCablingTypeColors()),
              child: const Text('Reset all'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ),
  );
}
