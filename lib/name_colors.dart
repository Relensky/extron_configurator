import 'package:flutter/material.dart';

import 'building_project.dart' show ProjectRfq;
import 'contrast.dart';

/// ============================================================================
///  A COLOR PER NAME
/// ============================================================================
///  Two sheets in this app are read by WHOSE NAME IS ON THE LINE rather than by
///  what the line says: the responsibility matrix, where the question is who
///  furnishes it and who installs it, and the equipment list, where an order is
///  placed one vendor at a time. Both are long, both are read across, and both
///  were black text on white — so telling the contractor's rows from the
///  owner's, or Extron's lines from Shure's, meant reading every cell.
///
///  A COLOR DOES THAT WORK, as long as it is the same color every time. That
///  is the whole contract here: one name, one color, on the screen, on the
///  picture that goes in the submittal, and again tomorrow. So the hue comes
///  out of the NAME rather than out of the order the rows happen to be in — a
///  palette handed out by position would recolor the whole sheet the moment
///  somebody sorted it or deleted a line.
///
///  DERIVED, NOT RANDOM. [_hashOf] is FNV-1a over the normalized name, which
///  is deterministic across runs and platforms — unlike [Object.hashCode],
///  which is free to differ between one launch and the next and would make the
///  matrix a different color every morning.
///
///  THE PARTIES EVERYBODY NAMES ARE ANCHORED. Owner, contractor, integrator and
///  vendor come up on nearly every job, and they are the four the reader learns
///  first, so they are pinned to fixed hues rather than left to the hash. The
///  answers that mean "nobody yet" — N/A, TBD, blank — are deliberately gray:
///  an unagreed line must not read as a decided one.
///
///  IT IS NEVER THE ONLY SIGNAL. Every place these are used keeps the name in
///  the cell beside the color, because this app's documents get printed in
///  mono and read by people who cannot tell the teal from the green.
/// ============================================================================

/// The wheel a name that is not anchored is picked off.
///
/// Twelve hues, evenly spread and mid-toned so each one survives being
/// darkened onto a white card or lightened onto a dark one by [legibleTone].
/// Adjacent entries are deliberately far apart on the wheel, so two vendors
/// that land next to each other in the list do not land next to each other in
/// color.
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

/// The color for a name that says nobody has decided yet.
const Color kNameTintUnsettled = Color(0xFF757575);

/// The parties that come up on nearly every job, pinned so the reader only
/// learns them once. The keys are normalized — see [normalizedName].
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
/// Chico' and 'cts  chico' are one party rather than two colors.
String normalizedName(String name) =>
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
/// thing that document exists to catch, and giving it a cheerful color of its
/// own would hide it among the agreed lines.
Color tintForName(String name) {
  final key = normalizedName(name);
  if (key.isEmpty) return kNameTintUnsettled;
  final anchored = kAnchoredNameTints[key];
  if (anchored != null) return anchored;
  return kNameTintWheel[_hashOf(key) % kNameTintWheel.length];
}

/// The color something reads in, honoring a color somebody ASSIGNED it.
///
/// The derived color is a starting point, not a verdict. A buyer's own
/// colors mean things this app cannot work out — the order that is already
/// placed, the vendor the contract covers, the one that is always late — so
/// wherever a color can be assigned, [assigned] wins and the hash is what a
/// thing reads in until somebody says otherwise. Null is not "no color": it
/// is "nobody has chosen", which is why a list is legible before anything has
/// been set up.
Color resolveTint({int? assigned, required String name}) =>
    assigned == null ? tintForName(name) : Color(assigned);

/// A fill behind text, from a color that has already been resolved.
Color tintFill(Color tint, {double alpha = 0.16}) =>
    tint.withValues(alpha: alpha);

/// A resolved color as TEXT on [background] — see [legibleTone].
Color tintText(Color tint, Color background) => legibleTone(tint, background);

/// True when [name] is one of the answers that means nothing has been settled.
bool nameIsUnsettled(String name) {
  final key = normalizedName(name);
  return key.isEmpty || kAnchoredNameTints[key] == kNameTintUnsettled;
}

/// [name]'s color as TEXT on [background], moved along its own lightness
/// until it can be read there. Keeps the hue, so the color still identifies
/// the party — see [legibleTone].
Color nameTextColor(String name, Color background) =>
    legibleTone(tintForName(name), background);

/// [name]'s color as a FILL behind text — a chip, a cell, a band down the
/// side of a row.
///
/// Low alpha by default: this is a wash that the reader's eye groups by, not a
/// block that fights the text on top of it.
Color nameFill(String name, {double alpha = 0.16}) =>
    tintForName(name).withValues(alpha: alpha);

/// [name]'s color as a spreadsheet cell would print it: a pale wash and an
/// ink dark enough to read on it, both as 'RRGGBB'.
///
/// ON WHITE, ALWAYS. A spreadsheet has no theme and no dark mode - it is a
/// white page, and the tone that reads on this app's dark surfaces would be a
/// pale gray nobody can read there. Same hue, printed for paper.
///
/// The wash is the same weight the screen uses ([nameFill]), composited onto
/// white here because an Excel fill has no alpha to composite with.
/// [assigned] is the color somebody CHOSE for this name, when they have -
/// see [resolveTint]. Passed through here rather than resolved by the caller
/// so the spreadsheet, the screen and the picture all reach the same answer
/// from the same two facts.
({String fill, String ink}) nameSheetTint(String name, {int? assigned}) =>
    sheetTintOf(resolveTint(assigned: assigned, name: name));

/// A color that has ALREADY been resolved, printed for paper: a pale wash and
/// an ink dark enough to read on it, both as 'RRGGBB'.
({String fill, String ink}) sheetTintOf(Color tint) {
  final fill = Color.lerp(Colors.white, tint, 0.16) ?? Colors.white;
  return (
    fill: _hex(fill),
    ink: _hex(legibleTone(tint, fill)),
  );
}

/// 'RRGGBB', which is what an Office Open XML color wants after its FF.
String _hex(Color color) =>
    (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// The chip a party or a vendor is named in: its color, its name, and nothing
/// else.
///
/// One widget so the matrix, its picture and the equipment list cannot drift
/// into three shapes of the same idea.
class NameTintChip extends StatelessWidget {
  final String name;

  /// The color to use instead of the one [name] derives, for a thing whose
  /// color somebody has assigned — see [resolveTint].
  final Color? color;

  /// What to show when the name is blank. The matrix says NOBODY YET out loud
  /// rather than leaving an empty cell that reads as agreed.
  final String emptyLabel;

  /// Set on a light document that is going to be printed, where the theme's
  /// card color is not what the chip is actually sitting on.
  final Color? background;

  final double fontSize;

  const NameTintChip({
    super.key,
    required this.name,
    this.color,
    this.emptyLabel = '-',
    this.background,
    this.fontSize = 11,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ground = background ?? theme.cardColor;
    final shown = name.trim().isEmpty ? emptyLabel : name.trim();
    final unsettled = color == null && nameIsUnsettled(name);
    final tint = color ?? tintForName(name);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tintFill(tint, alpha: unsettled ? 0.10 : 0.16),
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
              : tintText(tint, ground),
        ),
      ),
    );
  }
}

/// A color on its own, where there is no room for a chip: in front of a name
/// on a menu, on a filter, at the head of a row.
///
/// Never alone. Every one of these sits beside the name it stands for — the
/// dot is what makes a list scannable, the name is what makes it readable.
class NameTintDot extends StatelessWidget {
  final Color color;
  final double size;

  const NameTintDot({super.key, required this.color, this.size = 12});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(
        color: Theme.of(context).dividerColor,
        width: 0.5,
      ),
    ),
  );
}

/// The key to whatever colors are actually on the sheet.
///
/// Built from the names in use rather than from the palette, because a legend
/// listing twelve hues nine of which are not on this job is a legend nobody
/// reads.
class NameTintKey extends StatelessWidget {
  final Iterable<String> names;
  final String? title;

  /// The color a name has been GIVEN, where somebody has given it one. Null
  /// (or a null answer) leaves the name on the color it derives - see
  /// [resolveTint].
  final Color? Function(String name)? colorOf;

  /// What clicking a name does. Null leaves the key a legend: a chip that
  /// looks pressable and is not is worse than one that plainly is not.
  final void Function(String name)? onTap;

  /// Prefixed to each chip's key, so a test - and the reader running one
  /// finger down the strip - can point at one name rather than at the strip.
  final String keyPrefix;

  const NameTintKey({
    super.key,
    required this.names,
    this.title,
    this.colorOf,
    this.onTap,
    this.keyPrefix = 'name_tint',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seen = <String>{};
    final shown = <String>[];
    for (final name in names) {
      final key = normalizedName(name);
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
        for (final name in shown)
          if (onTap == null)
            NameTintChip(name: name, color: colorOf?.call(name))
          else
            // The whole chip is the target, not an icon beside it: the chip IS
            // the color, and the thing somebody wants to press to change a
            // color is the color they can see.
            Tooltip(
              message: 'Choose the color $name reads in, here and on '
                  'everything issued from here',
              child: InkWell(
                key: ValueKey('${keyPrefix}_${normalizedName(name)}'),
                borderRadius: BorderRadius.circular(4),
                onTap: () => onTap!(name),
                child: NameTintChip(name: name, color: colorOf?.call(name)),
              ),
            ),
      ],
    );
  }
}

/// THE COLOR A PACKAGE'S PARTS ARE MARKED IN.
///
/// A package is an ORDER-TO-BE: everything in it goes out as one request and
/// comes back as one purchase order. "Which of these two hundred parts are
/// bought together" is the question the master list is opened for, and until
/// now the answer was a name in a narrow column that had to be read a row at a
/// time. A color answers it down the whole page at once.
///
/// ON THE PACKAGE AND NOT THE WINNER, so the page does not repaint itself the
/// day an award lands. See [ProjectRfq.color].
///
/// Assigned first, derived from the title otherwise, so the list is legible on
/// a job where nobody has set a color. An untagged part is in no package and
/// takes the unsettled gray — it is not an order yet, and giving it a color of
/// its own would make it look like one.
Color projectRfqColor(ProjectRfq? rfq) => rfq == null
    ? kNameTintUnsettled
    : resolveTint(assigned: rfq.color, name: rfq.name);
