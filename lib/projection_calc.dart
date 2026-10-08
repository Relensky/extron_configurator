import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'av_device_library.dart';

/// ============================================================================
///  PROJECTION MATH
/// ============================================================================
///  Throw distance, image size, brightness on the screen and how a screen's
///  brightness falls off to the side. Plain functions so the calculator, the
///  floor plan and the tests all get the same numbers.
///
///  Throw ratio is distance over image width: a 2.0 lens 10 ft away throws an
///  image 5 ft wide. Lengths here are in feet.
/// ============================================================================

/// One screen shape.
class ScreenAspect {
  final String label;
  final double w;
  final double h;
  const ScreenAspect(this.label, this.w, this.h);

  double get ratio => w / h;
}

const List<ScreenAspect> kScreenAspects = [
  ScreenAspect('16:10', 16, 10),
  ScreenAspect('16:9', 16, 9),
  ScreenAspect('4:3', 4, 3),
  ScreenAspect('1.85:1', 1.85, 1),
  ScreenAspect('2.35:1', 2.35, 1),
];

/// Width and height of an image, in feet.
class ImageSize {
  final double width;
  final double height;
  const ImageSize(this.width, this.height);

  double get diagonal => math.sqrt(width * width + height * height);
  double get areaSqFt => width * height;
}

ImageSize imageFromDiagonal(double diagonal, ScreenAspect a) {
  final d = math.sqrt(a.w * a.w + a.h * a.h);
  return ImageSize(diagonal * a.w / d, diagonal * a.h / d);
}

ImageSize imageFromWidth(double width, ScreenAspect a) =>
    ImageSize(width, width / a.ratio);

ImageSize imageFromHeight(double height, ScreenAspect a) =>
    ImageSize(height * a.ratio, height);

/// How far back the lens sits to fill [width] at [ratio].
double throwDistance(double width, double ratio) => width * ratio;

/// How wide the image is from [distance] at [ratio].
double imageWidthAt(double distance, double ratio) =>
    ratio <= 0 ? 0 : distance / ratio;

/// The throw ratio that fills [width] from [distance].
double throwRatioFor(double distance, double width) =>
    width <= 0 ? 0 : distance / width;

/// Brightness on the screen, straight on: lumens times gain over area.
double footLamberts(double lumens, double gain, double areaSqFt) =>
    areaSqFt <= 0 ? 0 : lumens * gain / areaSqFt;

const double kNitsPerFootLambert = 3.426;

double nitsFromFootLamberts(double fl) => fl * kNitsPerFootLambert;

/// Room light bounced back off the screen, in foot-lamberts. Foot-candles
/// on the screen times its gain; a rough figure, good for comparing rooms.
double ambientFootLamberts(double footCandles, double gain) =>
    footCandles * gain;

/// Contrast of the image against the room light on the screen, as N:1.
double contrastInRoom(double imageFl, double ambientFl) =>
    ambientFl <= 0 ? double.infinity : (imageFl + ambientFl) / ambientFl;

/// Lux to foot-candles.
double footCandlesFromLux(double lux) => lux / 10.764;

/// The lowest and highest the lens center can sit, in feet off the floor,
/// for an image whose bottom edge is [bottom] off the floor. Vertical lens
/// shift is in percent of the image height, measured from centered.
({double low, double high}) lensHeightRange({
  required double bottom,
  required double imageHeight,
  required double shiftUpPct,
  required double shiftDownPct,
}) {
  final center = bottom + imageHeight / 2;
  return (
    low: center - imageHeight * shiftDownPct / 100,
    high: center + imageHeight * shiftUpPct / 100,
  );
}

/// The same for sideways, in feet either side of the image center.
double lensSideReach(double imageWidth, double shiftPct) =>
    imageWidth * shiftPct / 100;

/// Feet as 18' 6", to the nearest inch.
String formatFeetInches(double feet) {
  if (!feet.isFinite || feet <= 0) return '-';
  var ft = feet.floor();
  var inches = ((feet - ft) * 12).round();
  if (inches == 12) {
    ft++;
    inches = 0;
  }
  return inches == 0 ? "$ft'" : "$ft' $inches\"";
}

/// The units a length is shown and typed in.
enum LengthUnit {
  feet('feet', 'ft', 1),
  inches('inches', 'in', 12),
  centimeters('centimeters', 'cm', 30.48),
  meters('meters', 'm', 0.3048);

  final String label;
  final String short;

  /// How many of this unit make a foot.
  final double perFoot;
  const LengthUnit(this.label, this.short, this.perFoot);
}

/// [feet] in [unit]: 12' 6", 150", 381 cm or 3.81 m. '-' when not positive.
String formatLength(double feet, LengthUnit unit) {
  if (!feet.isFinite || feet <= 0) return '-';
  final v = feet * unit.perFoot;
  return switch (unit) {
    LengthUnit.feet => formatFeetInches(feet),
    LengthUnit.inches => '${v.round()}"',
    LengthUnit.centimeters => '${v.round()} cm',
    LengthUnit.meters => '${v.toStringAsFixed(2)} m',
  };
}

/// Brightness on a screen, as foot-lamberts or nits.
enum BrightnessUnit {
  footLamberts('foot-lamberts', 'fL'),
  nits('nits', 'nits');

  final String label;
  final String short;
  const BrightnessUnit(this.label, this.short);

  /// [fl] foot-lamberts in this unit.
  double of(double fl) => this == nits ? nitsFromFootLamberts(fl) : fl;
}

/// A measured length: 12' 6", or 8" under a foot.
String measureLabel(double feet) {
  if (!feet.isFinite || feet <= 0) return '0"';
  if (feet < 1) return '${(feet * 12).round()}"';
  final f = formatFeetInches(feet);
  return f.contains('"') ? f : '$f 0"';
}

/// Inches for a text field: 6, or 6.5, without trailing zeros.
String trimFeetInches(double inches) {
  final s = inches.toStringAsFixed(2);
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

// --------------------------------------------------------------------------
//  Screen gain and viewing angle
// --------------------------------------------------------------------------

/// A typical half-gain angle for a screen of [gain], in degrees: the angle
/// off center where it looks half as bright. Matte 1.0 is about 60.
double typicalHalfGainAngle(double gain) {
  const points = [(1.0, 60.0), (1.3, 40.0), (1.8, 30.0), (2.5, 20.0)];
  if (gain <= points.first.$1) return points.first.$2;
  for (var i = 1; i < points.length; i++) {
    final (g1, a1) = points[i];
    if (gain <= g1) {
      final (g0, a0) = points[i - 1];
      return a0 + (a1 - a0) * (gain - g0) / (g1 - g0);
    }
  }
  return points.last.$2;
}

/// How bright the screen looks [angle] degrees off center, as a fraction of
/// straight on. Half at [halfGain] degrees, falling off as cos^n.
double relativeBrightness(double angle, double halfGain) {
  final a = angle.abs();
  if (a >= 90) return 0;
  final hg = halfGain.clamp(1.0, 89.0) * math.pi / 180;
  final n = math.log(0.5) / math.log(math.cos(hg));
  return math.pow(math.cos(a * math.pi / 180), n).toDouble();
}

/// The angle off center where brightness falls to [fraction] of straight on,
/// the inverse of [relativeBrightness]. 0 when [fraction] is 1 or more.
double angleForBrightness(double fraction, double halfGain) {
  if (fraction >= 1) return 0;
  if (fraction <= 0) return 90;
  final hg = halfGain.clamp(1.0, 89.0) * math.pi / 180;
  final n = math.log(0.5) / math.log(math.cos(hg));
  return math.acos(math.pow(fraction, 1 / n).toDouble()) * 180 / math.pi;
}

// --------------------------------------------------------------------------
//  Where an image works in room light
// --------------------------------------------------------------------------
//  An image works where it stands out from the room light that lands on it
//  by the contrast the content needs. The targets are the AVIXA viewing
//  categories.

/// Contrast needed, as N:1, and what it is for.
const List<(double, String)> kContrastTargets = [
  (7, 'Passive viewing'),
  (15, 'Basic decision making'),
  (50, 'Analytical decision making'),
  (80, 'Full-motion video'),
];

/// How much of the room light a display face throws back. Matte panels sit
/// around 2 to 4 percent.
const double kDisplayReflectance = 0.03;

/// Room light bounced off a surface toward the viewer, in nits: [fc]
/// foot-candles on it, reflecting [reflectance] (a screen's gain for a
/// screen).
double ambientNits(double fc, double reflectance) =>
    fc * 10.764 * reflectance / math.pi;

/// The brightness an image needs to hold [contrast]:1 against
/// [ambient] nits of room light.
double neededNits(double contrast, double ambient) =>
    (contrast - 1) * ambient;

/// Either side of center, the angle out to which an image of [peak] nits
/// still holds [needed] nits. 0 when it is too dim even straight on.
double workingAngle(double peak, double needed, double halfGain) {
  if (peak <= 0 || peak <= needed) return 0;
  if (needed <= 0) return 89;
  return angleForBrightness(needed / peak, halfGain);
}

/// Image height from its width, for a 16:9 picture or [aspect].
double imageHeightFromWidth(double width, [double aspect = 16 / 9]) =>
    width / aspect;

/// Farthest viewer for an image [height] high: 6 image heights, a common
/// rule of thumb for reading detail.
double farthestViewer(double height) => height * 6;

final _nitsText = RegExp(r'([\d][\d,]*)\s*(?:nits|cd\s*/\s*m)', caseSensitive: false);

/// Nits as written in [text], or 0.
double parseNits(String text) {
  final m = _nitsText.firstMatch(text);
  return m == null ? 0 : double.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0;
}

/// True when [t] is a camera, so its field of view matters.
bool templateIsCamera(AvDeviceTemplate t) {
  final s = ' ${t.category} ${t.model} '.toLowerCase();
  return s.contains('camera') || s.contains('ptz') || s.contains(' cam ');
}

/// The cone a device of [shape] starts with on the floor plan, in degrees,
/// off its catalog entry: a display's viewing angle, a camera's field of
/// view, a projector's beam at the middle of its zoom. Null when the entry
/// does not say.
double? catalogConeAngle(String shape, AvDeviceTemplate? t) {
  if (t == null) return null;
  switch (shape) {
    case 'display':
      return t.viewingAngle > 0 ? t.viewingAngle : null;
    case 'camera':
      return t.fieldOfView > 0 ? t.fieldOfView : null;
    case 'projector':
      final s = projectorSpecsOf(t);
      if (s == null || !s.hasThrow) return null;
      final ratio = (s.throwMin + s.throwMax) / 2;
      return 2 * math.atan(1 / (2 * ratio)) * 180 / math.pi;
  }
  return null;
}

/// A display's brightness: its own field, then its notes.
double displayNitsOf(AvDeviceTemplate t) =>
    t.nits > 0 ? t.nits : parseNits('${t.model} ${t.notes}');

/// A display's diagonal in inches, read off its notes ('55"', '65-inch') or
/// the size its model number starts with (TH-55SQ2, FW-65BZ40L, INF7500).
/// 0 when neither says.
double displayDiagonalOf(AvDeviceTemplate t) {
  final inNotes = RegExp(r'(\d{2,3})\s*(?:"|-?\s*inch|in\b)', caseSensitive: false)
      .firstMatch(t.notes);
  final fromNotes = double.tryParse(inNotes?.group(1) ?? '') ?? 0;
  if (fromNotes >= 20 && fromNotes <= 120) return fromNotes;
  final inModel = RegExp(r'^[A-Za-z]+-?[A-Za-z]?(\d{2})').firstMatch(t.model.trim());
  final fromModel = double.tryParse(inModel?.group(1) ?? '') ?? 0;
  return fromModel >= 32 && fromModel <= 99 ? fromModel : 0;
}

/// Width of a 16:9 picture [diagonal] inches across, in feet.
double widthFromDiagonalInches(double diagonal) =>
    imageFromDiagonal(diagonal / 12, const ScreenAspect('16:9', 16, 9)).width;

// --------------------------------------------------------------------------
//  Angles on the floor plan
// --------------------------------------------------------------------------
//  Rotation is degrees clockwise from the top of the sheet, as on PlanDevice.

/// The rotation that faces from [from] toward [to].
double rotationToward(Offset from, Offset to) {
  final d = to - from;
  final deg = math.atan2(d.dx, -d.dy) * 180 / math.pi;
  return deg < 0 ? deg + 360 : deg;
}

/// The angle between two rotations, 0 to 180.
double angleBetweenRotations(double a, double b) {
  final d = ((a - b) % 360 + 360) % 360;
  return d > 180 ? 360 - d : d;
}

/// How far off the screen's center line [viewer] sits, 0 to 180 degrees.
/// 0 is straight in front of a screen facing [screenRotation].
double offAxisAngle(Offset screen, double screenRotation, Offset viewer) =>
    angleBetweenRotations(screenRotation, rotationToward(screen, viewer));

/// The rotation a projector at [projector] takes to hit a screen at
/// [screen] square on: facing the opposite way to the screen.
double squareToScreen(double screenRotation) => (screenRotation + 180) % 360;

/// Where a projector sits on the screen's center line, [distance] out.
Offset pointOnCenterLine(Offset screen, double screenRotation, double distance) {
  final r = screenRotation * math.pi / 180;
  return screen + Offset(math.sin(r), -math.cos(r)) * distance;
}

// --------------------------------------------------------------------------
//  Specs off the catalog
// --------------------------------------------------------------------------

/// Throw ratio and brightness for one projector or lens.
class ProjectorSpecs {
  /// What they came from, for the picker.
  final String source;
  final double throwMin;
  final double throwMax;
  final double lumens;

  const ProjectorSpecs({
    required this.source,
    this.throwMin = 0,
    this.throwMax = 0,
    this.lumens = 0,
  });

  bool get hasThrow => throwMin > 0;
  bool get hasLumens => lumens > 0;

  /// "1.44 - 2.32:1", or "0.35:1" for a fixed lens.
  String get throwLabel => !hasThrow
      ? ''
      : throwMax > throwMin
      ? '${_n(throwMin)} - ${_n(throwMax)}:1'
      : '${_n(throwMin)}:1';
}

String _n(double v) => v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');

/// True when [t] is a projector or a lens, so its throw and lumens matter.
bool templateTakesProjection(AvDeviceTemplate t) {
  final s = '${t.category} ${t.model}'.toLowerCase();
  return s.contains('projector') || RegExp(r'\blens\b').hasMatch(s);
}

// Spec sheets write a range with "to", a hyphen, a tilde or an en dash.
final _throwRange = RegExp(
  r'throw\s*ratio[^:\d]*:?\s*([\d.]+)\s*(?:to|-|~|'
  '${String.fromCharCode(0x2013)}'
  r')\s*([\d.]+)',
  caseSensitive: false,
);
final _throwFixed = RegExp(
  r'throw\s*ratio[^:\d]*:?\s*([\d.]+)\s*(?::\s*1)?',
  caseSensitive: false,
);
final _lumens = RegExp(
  r'([\d][\d,]*)\s*(?:ansi\s*)?(?:lumens|lm)\b',
  caseSensitive: false,
);

/// Throw ratio as written in [text], or null. "Throw ratio (WUXGA / WXGA):
/// 1.44 to 2.32 / 1.05 to 1.69" reads the first pair.
(double, double)? parseThrowRatio(String text) {
  final r = _throwRange.firstMatch(text);
  if (r != null) {
    final a = double.tryParse(r.group(1)!);
    final b = double.tryParse(r.group(2)!);
    if (a != null && b != null && a > 0 && b > 0) {
      return (math.min(a, b), math.max(a, b));
    }
  }
  final f = _throwFixed.firstMatch(text);
  final a = f == null ? null : double.tryParse(f.group(1)!);
  if (a != null && a > 0) return (a, a);
  return null;
}

/// Lumens as written in [text], or 0.
double parseLumens(String text) {
  final m = _lumens.firstMatch(text);
  if (m == null) return 0;
  return double.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0;
}

/// The specs of [t]: its own throw and lumens fields first, then whatever
/// the notes and model name say. Null when it has neither.
ProjectorSpecs? projectorSpecsOf(AvDeviceTemplate t) {
  final text = '${t.model} ${t.notes}';
  var min = t.throwRatioMin;
  var max = t.throwRatioMax;
  if (min <= 0) {
    final parsed = parseThrowRatio(text);
    if (parsed != null) (min, max) = parsed;
  }
  if (max < min) max = min;
  final lumens = t.lumens > 0 ? t.lumens : parseLumens(text);
  if (min <= 0 && lumens <= 0) return null;
  return ProjectorSpecs(
    source: t.model,
    throwMin: min,
    throwMax: max,
    lumens: lumens,
  );
}

/// The specs a projector line can use: its own, and any lens bought with it.
/// A lens supplies the throw and the projector the lumens.
List<ProjectorSpecs> projectorSpecChoices(
  Iterable<AvDeviceTemplate> own,
  Iterable<AvDeviceTemplate> lenses,
) {
  final out = <ProjectorSpecs>[];
  var lumens = 0.0;
  for (final t in own) {
    final s = projectorSpecsOf(t);
    if (s == null) continue;
    if (s.hasLumens && lumens <= 0) lumens = s.lumens;
    out.add(s);
  }
  for (final t in lenses) {
    final s = projectorSpecsOf(t);
    if (s == null || !s.hasThrow) continue;
    out.add(
      ProjectorSpecs(
        source: t.model,
        throwMin: s.throwMin,
        throwMax: s.throwMax,
        lumens: s.hasLumens ? s.lumens : lumens,
      ),
    );
  }
  return out;
}
