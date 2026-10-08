import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'movable_dialog.dart';
import 'projection_calc.dart';
import 'projection_diagram.dart';

/// ============================================================================
///  PROJECTION CALCULATOR
/// ============================================================================
///  Throw distance from the screen size, or the image size from the distance,
///  with the brightness on the screen, the room light against it, where the
///  lens can sit, and how the brightness falls off to the sides.
///
///  The throw ratio and lumens come from the catalog when the projector (or
///  a lens bought with it) has them, and can be typed in either way.
/// ============================================================================

/// What the calculator settled on, for putting on a drawing.
class ProjectionResult {
  /// Lens to screen, in feet.
  final double distanceFt;

  /// Image width, in feet.
  final double imageWidthFt;

  /// The screen's half-bright angle either side of center, in degrees.
  final double halfGain;

  /// The screen's gain.
  final double gain;

  const ProjectionResult({
    required this.distanceFt,
    required this.imageWidthFt,
    required this.halfGain,
    this.gain = 1.0,
  });

  /// Full width of the beam seen from above, in degrees.
  double get beamAngle =>
      distanceFt <= 0 ? 0 : 2 * math.atan(imageWidthFt / 2 / distanceFt) * 180 / math.pi;
}

/// Opens the calculator. [specs] are offered in the projector picker, first
/// one selected. [applyLabel] names the button that returns a result; with
/// none, the dialog only has Close.
Future<ProjectionResult?> showProjectionCalculator(
  BuildContext context, {
  String title = 'Projection calculator',
  List<ProjectorSpecs> specs = const [],
  double? distanceFt,
  String? distanceNote,
  String? applyLabel,
  ValueChanged<double>? onSaveDistance,
}) => showMovableDialog<ProjectionResult>(
  context: context,
  builder: (_) => ProjectionCalculatorDialog(
    title: title,
    specs: specs,
    distanceFt: distanceFt,
    distanceNote: distanceNote,
    applyLabel: applyLabel,
    onSaveDistance: onSaveDistance,
  ),
);

enum _SizeBy { diagonal, width, height }

// The calculator's units, remembered for the next one opened while the app
// runs.
LengthUnit _lastDistanceUnit = LengthUnit.feet;
LengthUnit _lastSizeUnit = LengthUnit.inches;
BrightnessUnit _lastBrightnessUnit = BrightnessUnit.footLamberts;

/// Puts the calculator's units back to feet, inches and foot-lamberts.
@visibleForTesting
void resetProjectionUnits() {
  _lastDistanceUnit = LengthUnit.feet;
  _lastSizeUnit = LengthUnit.inches;
  _lastBrightnessUnit = BrightnessUnit.footLamberts;
}

class ProjectionCalculatorDialog extends StatefulWidget {
  final String title;
  final List<ProjectorSpecs> specs;
  /// A known throw distance. When given, the calculator starts from it.
  final double? distanceFt;

  /// Where [distanceFt] came from, shown under the field.
  final String? distanceNote;
  final String? applyLabel;

  /// Saves the throw distance shown as the room's.
  final ValueChanged<double>? onSaveDistance;

  const ProjectionCalculatorDialog({
    super.key,
    this.title = 'Projection calculator',
    this.specs = const [],
    this.distanceFt,
    this.distanceNote,
    this.applyLabel,
    this.onSaveDistance,
  });

  @override
  State<ProjectionCalculatorDialog> createState() =>
      _ProjectionCalculatorDialogState();
}

class _ProjectionCalculatorDialogState
    extends State<ProjectionCalculatorDialog> {
  // -1 is typed in by hand.
  int _spec = -1;
  final _throwMin = TextEditingController();
  final _throwMax = TextEditingController();
  final _lumens = TextEditingController();

  /// True when the distance is known and the image size is the answer.
  bool _fromDistance = false;
  ScreenAspect _aspect = kScreenAspects.first;
  _SizeBy _sizeBy = _SizeBy.diagonal;
  final _size = TextEditingController(text: '120');

  /// The units lengths and brightness are shown and typed in.
  LengthUnit _distanceUnit = _lastDistanceUnit;
  LengthUnit _sizeUnit = _lastSizeUnit;
  BrightnessUnit _brightnessUnit = _lastBrightnessUnit;
  final _distance = TextEditingController();

  /// Where the zoom sits, 0 at the shortest throw and 1 at the longest.
  double _zoom = 0.5;

  final _gain = TextEditingController(text: '1.0');
  final _halfGain = TextEditingController();
  final _ambient = TextEditingController(text: '5');
  final _shiftUp = TextEditingController(text: '0');
  final _shiftDown = TextEditingController(text: '0');
  final _shiftSide = TextEditingController(text: '0');
  final _bottom = TextEditingController();
  final _ceiling = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.specs.isNotEmpty) _useSpec(0);
    final d = widget.distanceFt;
    if (d != null && d > 0) {
      _distance.text = _fmt(d * _distanceUnit.perFoot, 2);
      _fromDistance = true;
    }
    _size.text = _fmt(10 * _sizeUnit.perFoot, 1);
    _bottom.text = _fmt(4 * _distanceUnit.perFoot, 2);
    _ceiling.text = _fmt(10 * _distanceUnit.perFoot, 2);
  }

  /// A box typed in [unit], in feet.
  double _feet(TextEditingController c, LengthUnit unit, [double fallback = 0]) {
    final v = _num(c);
    return v == 0 && fallback != 0 ? fallback : v / unit.perFoot;
  }

  double get _bottomFt => _feet(_bottom, _distanceUnit);
  double get _ceilingFt => _feet(_ceiling, _distanceUnit, 10);

  /// A throw-side length, in the distance unit.
  String _len(double feet) => _distanceUnit == LengthUnit.feet
      ? _ftIn(feet)
      : formatLength(feet, _distanceUnit);

  /// An image dimension, in the size unit.
  String _img(double feet) => _sizeUnit == LengthUnit.feet
      ? _ftIn(feet)
      : formatLength(feet, _sizeUnit);

  /// Retypes [c] from one unit to another so the length stays the same.
  void _convert(TextEditingController c, LengthUnit from, LengthUnit to) {
    final v = _num(c);
    if (v > 0 && from != to) {
      c.text = _fmt(v / from.perFoot * to.perFoot, 2);
    }
  }

  void _setDistanceUnit(LengthUnit u) {
    for (final c in [_distance, _bottom, _ceiling]) {
      _convert(c, _distanceUnit, u);
    }
    _distanceUnit = _lastDistanceUnit = u;
  }

  void _setSizeUnit(LengthUnit u) {
    _convert(_size, _sizeUnit, u);
    _sizeUnit = _lastSizeUnit = u;
  }

  /// Like ProjectorCentral's Units box: throw distance, image size and
  /// brightness.
  Future<void> _pickUnits() async {
    var dist = _distanceUnit, size = _sizeUnit, bright = _brightnessUnit;
    final saved = await showMovableDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Widget group<T>(
            String title,
            List<T> values,
            T value,
            String Function(T) label,
            ValueChanged<T> onPick,
            String keyPrefix,
          ) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleSmall),
              RadioGroup<T>(
                groupValue: value,
                onChanged: (v) {
                  if (v != null) setLocal(() => onPick(v));
                },
                child: Wrap(
                  children: [
                    for (final v in values)
                      InkWell(
                        key: ValueKey('${keyPrefix}_${label(v)}'),
                        onTap: () => setLocal(() => onPick(v)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Radio<T>(value: v),
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Text(label(v)),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 20),
            ],
          );
          return AlertDialog(
            title: const Text('Units'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  group<LengthUnit>('Throw distance', LengthUnit.values, dist,
                      (u) => u.label, (u) => dist = u, 'units_distance'),
                  group<LengthUnit>('Image size', LengthUnit.values, size,
                      (u) => u.label, (u) => size = u, 'units_size'),
                  group<BrightnessUnit>('Image brightness',
                      BrightnessUnit.values, bright, (u) => u.label,
                      (u) => bright = u, 'units_brightness'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                key: const ValueKey('units_ok'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('OK'),
              ),
            ],
          );
        },
      ),
    );
    if (saved != true || !mounted) return;
    setState(() {
      _setDistanceUnit(dist);
      _setSizeUnit(size);
      _brightnessUnit = _lastBrightnessUnit = bright;
    });
  }

  @override
  void dispose() {
    for (final c in [
      _throwMin, _throwMax, _lumens, _size, _distance, _gain, _halfGain,
      _ambient, _shiftUp, _shiftDown, _shiftSide, _bottom, _ceiling,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _useSpec(int i) {
    _spec = i;
    if (i < 0) return;
    final s = widget.specs[i];
    if (s.hasThrow) {
      _throwMin.text = _fmt(s.throwMin, 2);
      _throwMax.text = s.throwMax > s.throwMin ? _fmt(s.throwMax, 2) : '';
    }
    if (s.hasLumens) _lumens.text = s.lumens.round().toString();
  }

  double _num(TextEditingController c, [double fallback = 0]) =>
      double.tryParse(c.text.trim().replaceAll(',', '')) ?? fallback;

  static String _fmt(double v, int places) {
    if (!v.isFinite) return '-';
    final s = v.toStringAsFixed(places);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }

  /// Feet as 12' 6".
  static String _ftIn(double feet) {
    if (!feet.isFinite || feet <= 0) return '-';
    var ft = feet.floor();
    var inches = ((feet - ft) * 12).round();
    if (inches == 12) {
      ft++;
      inches = 0;
    }
    return '$ft\' $inches"';
  }

  double get _minRatio => _num(_throwMin);
  double get _maxRatio {
    final m = _num(_throwMax);
    return m > _minRatio ? m : _minRatio;
  }

  double get _ratio => _minRatio + (_maxRatio - _minRatio) * _zoom;

  double get _gainValue {
    final g = _num(_gain, 1);
    return g > 0 ? g : 1;
  }

  double get _halfGainValue {
    final h = _num(_halfGain);
    return h > 0 ? h.clamp(1, 89).toDouble() : typicalHalfGainAngle(_gainValue);
  }

  /// The image the screen size field describes, in feet.
  ImageSize? get _typedImage {
    final typed = _num(_size);
    if (typed <= 0) return null;
    final ft = typed / _sizeUnit.perFoot;
    return switch (_sizeBy) {
      _SizeBy.diagonal => imageFromDiagonal(ft, _aspect),
      _SizeBy.width => imageFromWidth(ft, _aspect),
      _SizeBy.height => imageFromHeight(ft, _aspect),
    };
  }

  /// The image at the chosen zoom.
  ImageSize? get _image {
    if (!_fromDistance) return _typedImage;
    final d = _feet(_distance, _distanceUnit);
    if (d <= 0 || _ratio <= 0) return null;
    return imageFromWidth(imageWidthAt(d, _ratio), _aspect);
  }

  double get _distanceFt {
    if (_fromDistance) return _feet(_distance, _distanceUnit);
    final img = _typedImage;
    return img == null ? 0 : throwDistance(img.width, _ratio);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = _image;
    final distance = _distanceFt;
    final canApply = image != null && distance > 0;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.videocam_outlined),
          const SizedBox(width: 10),
          Expanded(child: Text(widget.title)),
          OutlinedButton.icon(
            key: const ValueKey('projection_units'),
            icon: const Icon(Icons.straighten, size: 16),
            label: const Text('Units'),
            onPressed: _pickUnits,
          ),
        ],
      ),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Wrap(
            spacing: 24,
            runSpacing: 16,
            children: [
              SizedBox(width: 340, child: _inputs(theme)),
              SizedBox(width: 380, child: _results(theme, image, distance)),
              if (image != null && distance > 0 && _minRatio > 0)
                SizedBox(width: 744, child: _diagram(image, distance)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (widget.applyLabel != null)
          ElevatedButton(
            key: const ValueKey('projection_apply'),
            onPressed: canApply
                ? () => Navigator.of(context).pop(
                    ProjectionResult(
                      distanceFt: distance,
                      imageWidthFt: image.width,
                      halfGain: _halfGainValue,
                      gain: _gainValue,
                    ),
                  )
                : null,
            child: Text(widget.applyLabel!),
          ),
      ],
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? suffix,
    String? helper,
    String? hint,
    Key? key,
    double width = 100,
  }) => SizedBox(
    width: width,
    child: TextField(
      key: key,
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        helperText: helper,
        hintText: hint,
        isDense: true,
      ),
      onChanged: (_) => setState(() {}),
    ),
  );

  Widget _heading(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Text(text, style: theme.textTheme.titleSmall),
  );

  Widget _inputs(ThemeData theme) {
    final zoomed = _maxRatio > _minRatio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Projector', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        DropdownButtonFormField<int>(
          key: const ValueKey('projection_spec'),
          initialValue: _spec,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Throw and lumens from',
            isDense: true,
          ),
          items: [
            for (var i = 0; i < widget.specs.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(
                  [
                    widget.specs[i].source,
                    if (widget.specs[i].hasThrow) widget.specs[i].throwLabel,
                    if (widget.specs[i].hasLumens)
                      '${widget.specs[i].lumens.round()} lm',
                  ].join('  ·  '),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const DropdownMenuItem(value: -1, child: Text('Typed in')),
          ],
          onChanged: (v) => setState(() => _useSpec(v ?? -1)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            _field(
              _throwMin,
              'Throw min',
              suffix: ':1',
              key: const ValueKey('projection_throw_min'),
            ),
            _field(
              _throwMax,
              'Throw max',
              suffix: ':1',
              hint: 'fixed',
              key: const ValueKey('projection_throw_max'),
            ),
            _field(
              _lumens,
              'Brightness',
              suffix: 'lm',
              key: const ValueKey('projection_lumens'),
            ),
          ],
        ),
        if (zoomed) ...[
          const SizedBox(height: 8),
          Text(
            'Zoom: ${_fmt(_ratio, 2)}:1',
            style: theme.textTheme.bodySmall,
          ),
          Slider(
            key: const ValueKey('projection_zoom'),
            value: _zoom,
            onChanged: (v) => setState(() => _zoom = v),
          ),
        ],
        _heading(theme, 'Screen'),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('From screen size')),
            ButtonSegment(value: true, label: Text('From distance')),
          ],
          selected: {_fromDistance},
          onSelectionChanged: (s) => setState(() => _fromDistance = s.first),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            SizedBox(
              width: 110,
              child: DropdownButtonFormField<ScreenAspect>(
                initialValue: _aspect,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Aspect',
                  isDense: true,
                ),
                items: [
                  for (final a in kScreenAspects)
                    DropdownMenuItem(value: a, child: Text(a.label)),
                ],
                onChanged: (v) => setState(() => _aspect = v ?? _aspect),
              ),
            ),
            if (!_fromDistance) ...[
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<_SizeBy>(
                  initialValue: _sizeBy,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Size by',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: _SizeBy.diagonal,
                      child: Text('Diagonal'),
                    ),
                    DropdownMenuItem(value: _SizeBy.width, child: Text('Width')),
                    DropdownMenuItem(
                      value: _SizeBy.height,
                      child: Text('Height'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _sizeBy = v ?? _sizeBy),
                ),
              ),
              _field(
                _size,
                'Size',
                suffix: _sizeUnit.short,
                key: const ValueKey('projection_size'),
              ),
              // The image size unit; the number in the box is converted so
              // the screen stays the same size.
              SegmentedButton<LengthUnit>(
                key: const ValueKey('projection_size_unit'),
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  for (final u in LengthUnit.values)
                    ButtonSegment(value: u, label: Text(u.short)),
                ],
                selected: {_sizeUnit},
                onSelectionChanged: (sel) =>
                    setState(() => _setSizeUnit(sel.first)),
              ),
            ] else
              _field(
                _distance,
                'Throw distance',
                suffix: _distanceUnit.short,
                helper: widget.distanceNote,
                key: const ValueKey('projection_distance'),
                width: 170,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            _field(_gain, 'Screen gain', key: const ValueKey('projection_gain')),
            _field(
              _halfGain,
              'Half-gain angle',
              suffix: '°',
              hint: _fmt(typicalHalfGainAngle(_gainValue), 0),
              key: const ValueKey('projection_half_gain'),
              width: 130,
            ),
            _field(
              _ambient,
              'Room light',
              suffix: 'fc',
              helper: 'on the screen',
              width: 110,
            ),
          ],
        ),
        _heading(theme, 'Lens shift and mounting'),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            _field(_shiftUp, 'Shift up', suffix: '%'),
            _field(_shiftDown, 'Shift down', suffix: '%'),
            _field(_shiftSide, 'Shift sideways', suffix: '%', width: 120),
            _field(
              _bottom,
              'Image bottom',
              suffix: _distanceUnit.short,
              helper: 'off the floor',
              width: 120,
            ),
            _field(
              _ceiling,
              'Ceiling',
              suffix: _distanceUnit.short,
              width: 100,
            ),
          ],
        ),
      ],
    );
  }

  /// The answer drawn to scale, side and top, like the throw diagrams on
  /// projector spec sites.
  Widget _diagram(ImageSize image, double distance) {
    final lens = lensHeightRange(
      bottom: _bottomFt,
      imageHeight: image.height,
      shiftUpPct: _num(_shiftUp),
      shiftDownPct: _num(_shiftDown),
    );
    final ceiling = _ceilingFt;
    return ProjectionDiagram(
      key: const ValueKey('projection_diagram'),
      layout: ProjectionLayout(
        image: image,
        distance: distance,
        minDistance: throwDistance(image.width, _minRatio),
        maxDistance: throwDistance(image.width, _maxRatio),
        bottom: _bottomFt,
        lensLow: lens.low,
        lensHigh: lens.high,
        ceiling: ceiling > 0 ? ceiling : 10,
        sideReach: lensSideReach(image.width, _num(_shiftSide)),
        distanceUnit: _distanceUnit,
        sizeUnit: _sizeUnit,
      ),
      onDistanceChanged: (d) => setState(() => _dragTo(d)),
    );
  }

  /// Dragging the projector: the zoom stays put and the image grows or
  /// shrinks with the throw, in whichever field drives the calculator.
  void _dragTo(double feet) {
    if (_fromDistance) {
      _distance.text = _fmt(feet * _distanceUnit.perFoot, 2);
      return;
    }
    if (_ratio <= 0) return;
    final img = imageFromWidth(imageWidthAt(feet, _ratio), _aspect);
    final ft = switch (_sizeBy) {
      _SizeBy.diagonal => img.diagonal,
      _SizeBy.width => img.width,
      _SizeBy.height => img.height,
    };
    _size.text = _fmt(ft * _sizeUnit.perFoot, 1);
  }

  /// Where [fl] sits from too dim to bright enough for a lit room.
  Widget _brightnessGauge(ThemeData theme, double fl) {
    const top = 60.0;
    final (verdict, good) = fl < 12
        ? ('Too dim for most rooms', false)
        : fl <= 20
        ? ('Recommended for dark rooms', true)
        : fl <= 35
        ? ('Recommended for rooms with low ambient light', true)
        : fl <= 50
        ? ('Recommended for rooms with moderate ambient light', true)
        : ('Bright enough for high ambient light', true);
    final dark = theme.brightness == Brightness.dark;
    final ok = dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            height: 16,
            child: LayoutBuilder(
              builder: (context, box) {
                final x = (fl / top).clamp(0.0, 1.0) * box.maxWidth;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 5,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0xFFEF9A9A),
                              Color(0xFF81C784),
                              Color(0xFF81C784),
                              Color(0xFFE6D36A),
                            ],
                            stops: [0, 0.3, 0.55, 1],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: x - 7,
                      top: -4,
                      child: Icon(Icons.arrow_drop_down, size: 16, color: ok),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${_fmt(_brightnessUnit.of(fl), 0)} ${_brightnessUnit.short}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: good ? ok : theme.colorScheme.error,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              verdict,
              style: theme.textTheme.bodySmall?.copyWith(
                color: good ? ok : theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// How far the lens shift can move the image from where it sits.
  String? _shiftSentence(ImageSize image) {
    final up = image.height * _num(_shiftUp) / 100;
    final down = image.height * _num(_shiftDown) / 100;
    final side = image.width * _num(_shiftSide) / 100;
    if (up <= 0 && down <= 0 && side <= 0) return null;
    return 'At this throw distance the image can be shifted '
        '${_img(up)} up, ${_img(down)} down, and ${_img(side)} to '
        'either side using the lens shift.';
  }

  Widget _results(ThemeData theme, ImageSize? image, double distance) {
    if (image == null || _minRatio <= 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Text(
          _minRatio <= 0
              ? 'Enter the projector\'s throw ratio to see the results.'
              : _fromDistance
              ? 'Enter the throw distance.'
              : 'Enter the screen size.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    final lumens = _num(_lumens);
    final gain = _gainValue;
    final halfGain = _halfGainValue;
    final fl = footLamberts(lumens, gain, image.areaSqFt);
    final ambient = ambientFootLamberts(_num(_ambient), gain);
    final contrast = contrastInRoom(fl, ambient);
    final lens = lensHeightRange(
      bottom: _bottomFt,
      imageHeight: image.height,
      shiftUpPct: _num(_shiftUp),
      shiftDownPct: _num(_shiftDown),
    );
    final side = lensSideReach(image.width, _num(_shiftSide));
    final zoomed = _maxRatio > _minRatio;

    Widget row(String label, String value, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          const SizedBox(width: 8),
          Flexible(
            flex: 2,
            child: Text(
              value,
              key: key,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    Widget table(List<String> head, List<List<String>> rows) => Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      columnWidths: const {0: FlexColumnWidth()},
      children: [
        TableRow(
          children: [
            for (final h in head)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 2, 12, 4),
                child: Text(h, style: theme.textTheme.labelSmall),
              ),
          ],
        ),
        for (final r in rows)
          TableRow(
            children: [
              for (final c in r)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 1, 12, 1),
                  child: Text(c, style: theme.textTheme.bodySmall),
                ),
            ],
          ),
      ],
    );

    // Brightness over distance at this zoom: the image grows as the
    // projector moves back, and the same light spreads over more screen.
    final distances = [
      for (final f in [0.6, 0.8, 1.0, 1.2, 1.4]) distance * f,
    ];
    final overDistance = [
      for (final d in distances)
        () {
          final img = imageFromWidth(imageWidthAt(d, _ratio), _aspect);
          final f = footLamberts(lumens, gain, img.areaSqFt);
          return [
            _len(d),
            _img(img.diagonal),
            lumens > 0 ? _fmt(f, 1) : '-',
            lumens > 0 ? _fmt(nitsFromFootLamberts(f), 0) : '-',
          ];
        }(),
    ];
    final overAngle = [
      for (final a in [0, 15, 30, 45, 60, 75])
        () {
          final rel = relativeBrightness(a.toDouble(), halfGain);
          return [
            '$a°',
            '${(rel * 100).round()}%',
            lumens > 0 ? _fmt(fl * rel, 1) : '-',
            lumens > 0 ? _fmt(nitsFromFootLamberts(fl * rel), 0) : '-',
          ];
        }(),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Results', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        row(
          'Image',
          '${_img(image.width)} x ${_img(image.height)}  '
              '(${_img(image.diagonal)} diag)',
          key: const ValueKey('projection_image'),
        ),
        if (_fromDistance && zoomed)
          row(
            'Image range',
            '${_img(imageFromWidth(imageWidthAt(distance, _maxRatio), _aspect).diagonal)} - '
                '${_img(imageFromWidth(imageWidthAt(distance, _minRatio), _aspect).diagonal)} diag',
          ),
        row(
          'Throw distance',
          _len(distance),
          key: const ValueKey('projection_result_distance'),
        ),
        if (!_fromDistance && zoomed)
          row(
            'Throw range',
            '${_len(throwDistance(image.width, _minRatio))} - '
                '${_len(throwDistance(image.width, _maxRatio))}',
            key: const ValueKey('projection_throw_range'),
          ),
        row('Throw ratio', '${_fmt(_ratio, 2)}:1'),
        if (widget.onSaveDistance != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('projection_save_distance'),
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text("Save as the room's throw distance"),
              onPressed: distance > 0
                  ? () {
                      widget.onSaveDistance!(distance);
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(
                          content: Text(
                            'Room throw distance set to ${_len(distance)}.',
                          ),
                        ),
                      );
                    }
                  : null,
            ),
          ),
        const Divider(height: 18),
        row(
          'Brightness, straight on',
          lumens > 0
              ? _brightnessUnit == BrightnessUnit.nits
                    ? '${_fmt(nitsFromFootLamberts(fl), 0)} nits  '
                          '(${_fmt(fl, 1)} ft-L)'
                    : '${_fmt(fl, 1)} ft-L  '
                          '(${_fmt(nitsFromFootLamberts(fl), 0)} nits)'
              : 'enter lumens',
          key: const ValueKey('projection_brightness'),
        ),
        if (lumens > 0) _brightnessGauge(theme, fl),
        if (lumens > 0 && ambient > 0)
          row('Contrast in room light', '${_fmt(contrast, 1)}:1'),
        Text(
          'About 16 ft-L suits a dark room; 50 and up holds up with the '
          'lights on. Rated lumens drop as a lamp ages.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const Divider(height: 18),
        row(
          'Lens height',
          lens.high - lens.low < 0.01
              ? _len(lens.low)
              : '${_len(lens.low)} - ${_len(lens.high)}',
        ),
        if (side > 0) row('Lens off center, either side', 'up to ${_len(side)}'),
        if (_shiftSentence(image) case final text?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(text, style: theme.textTheme.bodySmall),
          ),
        row(
          'Beam angle from above',
          '${_fmt(ProjectionResult(distanceFt: distance, imageWidthFt: image.width, halfGain: halfGain).beamAngle, 0)}°',
        ),
        _heading(theme, 'Brightness over distance (${_fmt(_ratio, 2)}:1)'),
        table(['Distance', 'Image', 'ft-L', 'nits'], overDistance),
        _heading(
          theme,
          'Viewing angle (half as bright at ±${_fmt(halfGain, 0)}°)',
        ),
        table(['Off center', 'Brightness', 'ft-L', 'nits'], overAngle),
      ],
    );
  }
}
