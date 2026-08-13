import 'package:flutter/material.dart';

import 'app_state.dart';
import 'av_flow_model.dart' show kCableSwatches;
import 'cabling_schematic.dart';
import 'color_wheel_picker.dart';

/// ============================================================================
///  WHAT COLOUR EACH CABLE IS
/// ============================================================================
///  The Schematic tab has had a "Colors" button on its toolbar for as long as
///  it has had lines: one dialog, every kind of link, set them and be done.
///  The two sheets the trades are actually handed — the Cabling drawing and
///  the Floor Plan — had no such thing. A colour could only be changed by
///  selecting one run and using the swatches in the selection bar, which is
///  the wrong shape for the job: "make all the network runs blue" is a
///  decision about a cable TYPE, not about the run somebody happens to have
///  clicked, and doing it run by run is how a sheet ends up with three shades
///  of network on it.
///
///  So both pages get the same button, and it writes what the drawing reads:
///  a colour per cable type ([AppStateProvider.setCablingTypeColor]), which
///  every run of that type on every sheet then follows.
/// ============================================================================

/// The cable types on [drawing], each with the colour its runs are drawn in
/// and the keys a colour has to be written under.
///
/// Plural keys because one cable type can be pulled under more than one
/// category — AV Cat 6a and network Cat 6a are different pulls the key colours
/// apart — while a person setting colours is thinking about "Cat 6a".
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

/// Sets the colour of every cable type on [drawing].
///
/// Shared by the Cabling and Floor Plan tabs so the button does the same thing
/// on both, and so a colour set on one sheet is the colour on the other — they
/// are two drawings of one room's cable, and a network run that is blue on the
/// plan and green on the cabling sheet is two drawings nobody can read
/// together.
Future<void> showCableColorsDialog(
  BuildContext context,
  AppStateProvider provider,
  CablingSchematic drawing,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final theme = Theme.of(ctx);
        // Re-read every rebuild: setting a colour changes what the drawing
        // says the runs are drawn in, and the swatches have to follow.
        final types = cablingTypesIn(drawing);

        return AlertDialog(
          title: const Text('Cable colours'),
          content: SizedBox(
            width: 620,
            child: types.isEmpty
                ? Text(
                    'No cable runs on this drawing yet. Name the places in the '
                    'room, say which place each device is in, and the runs '
                    'between them are counted off the signal flow.',
                    style: theme.textTheme.bodySmall,
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'One colour per cable type, used by every run of it '
                          'on the cabling sheet and the floor plan. A run with '
                          'a colour of its own keeps it.',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        for (final t in types)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 150,
                                  child: Text(
                                    t.type,
                                    style: const TextStyle(fontSize: 12),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Expanded(
                                  child: Wrap(
                                    spacing: 2,
                                    runSpacing: 2,
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
                                          selected: t.color.toARGB32() ==
                                              c.toARGB32(),
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
                                  tooltip: 'Any other colour',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () async {
                                    final picked = await showColorWheelDialog(
                                      ctx,
                                      initial: t.color,
                                      title: 'Colour for ${t.type}',
                                    );
                                    if (picked == null) return;
                                    setLocal(() => provider.setCablingTypeColor(
                                          t.keys,
                                          picked.toARGB32(),
                                        ));
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.format_color_reset,
                                    size: 16,
                                  ),
                                  tooltip: 'Back to the colour the key gives '
                                      'this cable',
                                  visualDensity: VisualDensity.compact,
                                  onPressed:
                                      provider.hasCablingTypeColor(t.keys)
                                          ? () => setLocal(
                                                () => provider
                                                    .setCablingTypeColor(
                                                        t.keys, null),
                                              )
                                          : null,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
          actions: [
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
