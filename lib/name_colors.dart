import 'package:flutter/material.dart';

import 'contrast.dart';

/// ============================================================================
///  A COLOUR PER NAME
/// ============================================================================
///  Two sheets in this app are read by WHOSE NAME IS ON THE LINE rather than by
///  what the line says: the responsibility matrix, where the question is who
///  furnishes it and who installs it, and the equipment list, where an order is
///  placed one vendor at a time. Both are long, both are read across, and both
///  were black text on white — so telling the contractor's rows from the
///  owner's, or Extron's lines from Shure's, meant reading every cell.
///
///  A COLOUR DOES THAT WORK, as long as it is the same colour every time. That
///  is the whole contract here: one name, one colour, on the screen, on the
///  picture that goes in the submittal, and again tomorrow. So the hue comes
///  out of the NAME rather than out of the order the rows happen to be in — a
///  palette handed out by position would recolour the whole sheet the moment
///  somebody sorted it or deleted a line.
///
///  DERIVED, NOT RANDOM. [_hashOf] is FNV-1a over the normalised name, which
///  is deterministic across runs and platforms — unlike [Object.hashCode],
///  which is free to differ between one launch and the next and would make the
///  matrix a different colour every morning.
///
///  THE PARTIES EVERYBODY NAMES ARE ANCHORED. Owner, contractor, integrator and
///  vendor come up on nearly every job, and they are the four the reader learns
///  first, so they are pinned to fixed hues rather than left to the hash. The
///  answers that mean "nobody yet" — N/A, TBD, blank — are deliberately grey:
///  an unagreed line must not read as a decided one.
///
///  IT IS NEVER THE ONLY SIGNAL. Every place these are used keeps the name in
///  the cell beside the colour, because this app's documents get printed in
///  mono and read by people who cannot tell the teal from the green.
/// ============================================================================

/// The wheel a name that is not anchored is picked off.
///
/// Twelve hues, evenly spread and mid-toned so each one survives being
/// darkened onto a white card or lightened onto a dark one by [legibleTone].
/// Adjacent entries are deliberately far apart on the wheel, so two vendors
/// that land next to each other in the list do not land next to each other in
/// colour.
const List<Color> kNameTintWheel = [
  Color(0xFF1E88E5), // blue
  Color(0xFFEF6C00), // orange
  Color(0xFF00897B), // teal
  Color(0xFF8E24AA), // purple
  Color(0xFF43A047), // green
  Color(0xFFD81B60), // pink
  Color(0xFF3949AB), // indigo
  Color(0xFFF9A825), // gold
  Color(0xFF00ACC1), // cyan
  Color(0xFF6D4C41), // brown
  Color(0xFF7CB342), // lime
  Color(0xFF5E35B1), // deep purple
];

/// The colour for a name that says nobody has decided yet.
const Color kNameTintUnsettled = Color(0xFF757575);

/// The parties that come up on nearly every job, pinned so the reader only
/// learns them once. The keys are normalised — see [normalisedName].
const Map<String, Color> kAnchoredNameTints = {
  'owner': Color(0xFF1E88E5),
  'contractor': Color(0xFFEF6C00),
  'integrator': Color(0xFF00897B),
  'vendor': Color(0xFF8E24AA),
  'n/a': kNameTintUnsettled,
  'na': kNameTintUnsettled,
  'tbd': kNameTintUnsettled,
  'none': kNameTintUnsettled,
};

/// A name reduced to what it MEANS: case and spacing thrown away, so 'CTS
/// Chico' and 'cts  chico' are one party rather than two colours.
String normalisedName(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// FNV-1a, 32 bit. Stable across runs, platforms and Dart versions, which
/// [Object.hashCode] is not.
int _hashOf(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// The hue [name] always reads in.
///
/// An empty name is [kNameTintUnsettled]: a blank party on the matrix is the
/// thing that document exists to catch, and giving it a cheerful colour of its
/// own would hide it among the agreed lines.
Color tintForName(String name) {
  final key = normalisedName(name);
  if (key.isEmpty) return kNameTintUnsettled;
  final anchored = kAnchoredNameTints[key];
  if (anchored != null) return anchored;
  return kNameTintWheel[_hashOf(key) % kNameTintWheel.length];
}

/// True when [name] is one of the answers that means nothing has been settled.
bool nameIsUnsettled(String name) {
  final key = normalisedName(name);
  return key.isEmpty || kAnchoredNameTints[key] == kNameTintUnsettled;
}

/// [name]'s colour as TEXT on [background], moved along its own lightness
/// until it can be read there. Keeps the hue, so the colour still identifies
/// the party — see [legibleTone].
Color nameTextColor(String name, Color background) =>
    legibleTone(tintForName(name), background);

/// [name]'s colour as a FILL behind text — a chip, a cell, a band down the
/// side of a row.
///
/// Low alpha by default: this is a wash that the reader's eye groups by, not a
/// block that fights the text on top of it.
Color nameFill(String name, {double alpha = 0.16}) =>
    tintForName(name).withValues(alpha: alpha);

/// The chip a party or a vendor is named in: its colour, its name, and nothing
/// else.
///
/// One widget so the matrix, its picture and the equipment list cannot drift
/// into three shapes of the same idea.
class NameTintChip extends StatelessWidget {
  final String name;

  /// What to show when the name is blank. The matrix says NOBODY YET out loud
  /// rather than leaving an empty cell that reads as agreed.
  final String emptyLabel;

  /// Set on a light document that is going to be printed, where the theme's
  /// card colour is not what the chip is actually sitting on.
  final Color? background;

  final double fontSize;

  const NameTintChip({
    super.key,
    required this.name,
    this.emptyLabel = '-',
    this.background,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ground = background ?? theme.cardColor;
    final shown = name.trim().isEmpty ? emptyLabel : name.trim();
    final unsettled = nameIsUnsettled(name);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: nameFill(name, alpha: unsettled ? 0.10 : 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        shown,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: unsettled
              ? theme.colorScheme.onSurfaceVariant
              : nameTextColor(name, ground),
        ),
      ),
    );
  }
}

/// The key to whatever colours are actually on the sheet.
///
/// Built from the names in use rather than from the palette, because a legend
/// listing twelve hues nine of which are not on this job is a legend nobody
/// reads.
class NameTintKey extends StatelessWidget {
  final Iterable<String> names;
  final String? title;

  const NameTintKey({super.key, required this.names, this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seen = <String>{};
    final shown = <String>[];
    for (final name in names) {
      final key = normalisedName(name);
      if (key.isEmpty || !seen.add(key)) continue;
      shown.add(name.trim());
    }
    if (shown.isEmpty) return const SizedBox.shrink();
    shown.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (title != null)
          Text(
            title!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        for (final name in shown) NameTintChip(name: name),
      ],
    );
  }
}
