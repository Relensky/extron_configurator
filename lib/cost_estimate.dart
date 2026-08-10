import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'labor_rates.dart';
import 'report_tools.dart';

/// ============================================================================
///  ROOM COST ESTIMATE
/// ============================================================================
///  What the room on the AV diagram costs to build. The quantities come from
///  the diagram itself — the same grouping the pack list uses, so the estimate
///  and the equipment order can never disagree — and the unit prices come from
///  the device catalog (av_devices.json), with a per-room override for the
///  price you were actually quoted.
///
///  On top of the equipment:
///
///    * FEES are percentages of the total before tax (freight, install,
///      contingency, overhead). Any number of them; each says whether it is
///      itself taxable, because a freight charge usually is and a labour line
///      usually isn't.
///    * LABOR is priced as rate x techs x hours, against the shared rate card
///      (labor_rates.dart) so revising a rate re-costs every estimate that
///      uses it.
///    * OTHER ITEMS are flat lines with their own quantity and unit price —
///      cable, plates, anything not a device on the canvas.
///    * TAX is one percentage applied to the taxable part of the estimate:
///      all equipment, plus the other items and fees marked taxable.
///
///  Everything here is pure data: the view (cost_estimate_view.dart) edits
///  [RoomCostSettings], and [computeRoomCost] turns settings + diagram +
///  catalog into the numbers the screen and the workbook both render.
/// ============================================================================

// ---------------------------------------------------------------------------
//  SETTINGS (persisted in the AV flow sidecar)
// ---------------------------------------------------------------------------

/// A percentage add-on, charged on the estimate's pre-tax total.
class CostFee {
  final String id;
  final String name;
  final double percent;

  /// Whether tax is charged on this fee as well. Freight normally is;
  /// labour normally isn't. Getting this wrong is a quiet few hundred
  /// dollars, so it is a per-fee answer rather than a global assumption.
  final bool taxable;

  const CostFee({
    required this.id,
    required this.name,
    required this.percent,
    this.taxable = true,
  });

  CostFee copyWith({String? name, double? percent, bool? taxable}) => CostFee(
    id: id,
    name: name ?? this.name,
    percent: percent ?? this.percent,
    taxable: taxable ?? this.taxable,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'percent': percent,
    'taxable': taxable,
  };

  factory CostFee.fromJson(Map<String, dynamic> json) => CostFee(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'Fee',
    percent: (json['percent'] as num?)?.toDouble() ?? 0,
    taxable: json['taxable'] != false,
  );
}

/// A line that isn't a device on the canvas: labour, cable, mounts, freight
/// quoted as a figure rather than a percentage.
class CostLineItem {
  final String id;
  final String description;
  final String category;
  final double qty;
  final double unitPrice;
  final bool taxable;

  const CostLineItem({
    required this.id,
    required this.description,
    this.category = '',
    this.qty = 1,
    this.unitPrice = 0,
    this.taxable = true,
  });

  double get total => qty * unitPrice;

  CostLineItem copyWith({
    String? description,
    String? category,
    double? qty,
    double? unitPrice,
    bool? taxable,
  }) => CostLineItem(
    id: id,
    description: description ?? this.description,
    category: category ?? this.category,
    qty: qty ?? this.qty,
    unitPrice: unitPrice ?? this.unitPrice,
    taxable: taxable ?? this.taxable,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    if (category.isNotEmpty) 'category': category,
    'qty': qty,
    'unitPrice': unitPrice,
    'taxable': taxable,
  };

  factory CostLineItem.fromJson(Map<String, dynamic> json) => CostLineItem(
    id: json['id']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    category: json['category']?.toString() ?? '',
    qty: (json['qty'] as num?)?.toDouble() ?? 1,
    unitPrice: (json['unitPrice'] as num?)?.toDouble() ?? 0,
    taxable: json['taxable'] != false,
  );
}

/// The room's estimate settings. Lives in `<config>_av_flow.json` beside the
/// diagram it prices, because a negotiated price is a fact about this job,
/// not about the model.
class RoomCostSettings {
  String currency;
  String taxLabel;
  double taxPercent;
  final List<CostFee> fees;

  /// Line key (see [DeviceGroup.key]) -> the unit price for THIS room,
  /// overriding whatever the catalog says.
  final Map<String, double> priceOverrides;

  final List<CostLineItem> items;

  /// The crews on this job: which rate, how many techs, how many hours.
  final List<LaborLine> labor;

  RoomCostSettings({
    this.currency = r'$',
    this.taxLabel = 'Sales tax',
    this.taxPercent = 0,
    List<CostFee>? fees,
    Map<String, double>? priceOverrides,
    List<CostLineItem>? items,
    List<LaborLine>? labor,
  }) : fees = fees ?? [],
       priceOverrides = priceOverrides ?? {},
       items = items ?? [],
       labor = labor ?? [];

  bool get isEmpty =>
      taxPercent == 0 &&
      fees.isEmpty &&
      priceOverrides.isEmpty &&
      items.isEmpty &&
      labor.isEmpty;

  void clear() {
    currency = r'$';
    taxLabel = 'Sales tax';
    taxPercent = 0;
    fees.clear();
    priceOverrides.clear();
    items.clear();
    labor.clear();
  }

  Map<String, dynamic> toJson() => {
    'currency': currency,
    'taxLabel': taxLabel,
    'taxPercent': taxPercent,
    'fees': [for (final f in fees) f.toJson()],
    'priceOverrides': priceOverrides,
    'items': [for (final i in items) i.toJson()],
    'labor': [for (final l in labor) l.toJson()],
  };

  void readJson(Map<String, dynamic> json) {
    clear();
    currency = json['currency']?.toString() ?? r'$';
    taxLabel = json['taxLabel']?.toString() ?? 'Sales tax';
    taxPercent = (json['taxPercent'] as num?)?.toDouble() ?? 0;
    for (final f in (json['fees'] as List? ?? [])) {
      if (f is Map) fees.add(CostFee.fromJson(Map<String, dynamic>.from(f)));
    }
    final overrides = json['priceOverrides'];
    if (overrides is Map) {
      overrides.forEach((key, value) {
        final price = (value as num?)?.toDouble();
        if (price != null) priceOverrides[key.toString()] = price;
      });
    }
    for (final i in (json['items'] as List? ?? [])) {
      if (i is Map) {
        items.add(CostLineItem.fromJson(Map<String, dynamic>.from(i)));
      }
    }
    for (final l in (json['labor'] as List? ?? [])) {
      if (l is Map) {
        labor.add(LaborLine.fromJson(Map<String, dynamic>.from(l)));
      }
    }
  }
}

// ---------------------------------------------------------------------------
//  GROUPING (shared with the pack list)
// ---------------------------------------------------------------------------

/// Devices on the diagram that count as "the same thing to order". Keyed on
/// model, so three identical displays are one line of quantity 3; a device
/// with no model stays on its own, because a pair of unnamed boxes merging
/// silently is how a pack list starts lying.
class DeviceGroup {
  final String key;
  final List<AvNode> nodes;

  const DeviceGroup({required this.key, required this.nodes});

  AvNode get first => nodes.first;
  int get qty => nodes.length;
  String get model => first.model.trim();

  /// One name, or every name when several devices share the model — the
  /// pack list is read to find the boxes, so the names have to be there.
  String get label =>
      nodes.length == 1 ? first.label : nodes.map((n) => n.label).join(', ');

  String get notes => nodes
      .map((n) => n.note)
      .where((n) => n.trim().isNotEmpty)
      .toSet()
      .join('; ');

  /// Watts for the whole group; 0 when nobody recorded a figure.
  double get watts => nodes.fold(0.0, (sum, n) => sum + n.powerWatts);

  bool get anyUnmetered => nodes.any((n) => n.powerWatts <= 0);
}

/// The diagram's devices, grouped for ordering. Jack fields are included:
/// a 12-port patch panel is a thing you buy.
List<DeviceGroup> groupDevices(AvFlowModel model) {
  final grouped = <String, List<AvNode>>{};
  for (final node in model.nodes) {
    final key = node.model.trim().isEmpty
        ? 'device:${node.id}'
        : 'model:${node.model.trim().toLowerCase()}';
    grouped.putIfAbsent(key, () => []).add(node);
  }
  return [
    for (final e in grouped.entries) DeviceGroup(key: e.key, nodes: e.value),
  ];
}

// ---------------------------------------------------------------------------
//  THE COMPUTED ESTIMATE
// ---------------------------------------------------------------------------

/// Where a line's unit price came from — shown in the table and the report so
/// a number can always be traced back to a decision.
enum PriceSource { override, catalog, none }

const Map<PriceSource, String> kPriceSourceLabels = {
  PriceSource.override: 'Room price',
  PriceSource.catalog: 'Catalog',
  PriceSource.none: 'Not priced',
};

class CostLine {
  final String key;
  final String description;
  final String model;
  final String category;
  final double qty;
  final double unitPrice;
  final bool taxable;
  final PriceSource source;

  const CostLine({
    required this.key,
    required this.description,
    this.model = '',
    this.category = '',
    required this.qty,
    required this.unitPrice,
    this.taxable = true,
    this.source = PriceSource.none,
  });

  double get total => qty * unitPrice;
}

/// One fee with the money it works out to.
typedef FeeAmount = ({CostFee fee, double amount});

/// A crew line, costed. The hours and head count are kept alongside the money
/// because "two CTS III for three days" is what gets checked; the total is
/// just what it comes to.
class LaborCostLine {
  final String id;
  final String roleName;
  final String description;
  final double techs;
  final double hours;
  final double hourlyRate;
  final bool taxable;

  /// True when the rate card has no figure for this role yet.
  final bool unrated;

  const LaborCostLine({
    required this.id,
    required this.roleName,
    required this.description,
    required this.techs,
    required this.hours,
    required this.hourlyRate,
    required this.taxable,
    required this.unrated,
  });

  double get totalHours => techs * hours;
  double get total => totalHours * hourlyRate;
}

class CostEstimate {
  final String currency;
  final List<CostLine> equipment;
  final List<CostLine> extras;

  /// Crews, priced from the rate card. Kept apart from [extras] because a
  /// quote is read as equipment + labour, and because the hours behind the
  /// figure are what get argued about.
  final List<LaborCostLine> labor;
  final List<FeeAmount> fees;
  final double equipmentTotal;
  final double extrasTotal;
  final double laborTotal;
  final double laborHours;

  /// Labour lines whose rate is 0 — the rate card has no figure for that job
  /// type yet, so the hours are real but the money is missing.
  final int unratedLabor;

  /// Equipment + other items: the "total before taxes" every fee is a
  /// percentage of.
  final double subtotal;
  final double feeTotal;
  final double taxableBase;
  final double taxPercent;
  final String taxLabel;
  final double tax;
  final double grandTotal;

  /// Devices on the diagram with no price anywhere — the estimate is short by
  /// however much these cost, and says so instead of reading as complete.
  final int unpricedLines;
  final int unpricedDevices;

  const CostEstimate({
    required this.currency,
    required this.equipment,
    required this.extras,
    required this.labor,
    required this.fees,
    required this.equipmentTotal,
    required this.extrasTotal,
    required this.laborTotal,
    required this.laborHours,
    required this.unratedLabor,
    required this.subtotal,
    required this.feeTotal,
    required this.taxableBase,
    required this.taxPercent,
    required this.taxLabel,
    required this.tax,
    required this.grandTotal,
    required this.unpricedLines,
    required this.unpricedDevices,
  });

  bool get isComplete => unpricedLines == 0 && unratedLabor == 0;
}

/// Rounds to cents. Percentages of percentages otherwise leave a fraction of a
/// cent in the total, which is the kind of thing that gets a quote queried.
double _cents(double value) => (value * 100).roundToDouble() / 100;

/// Prices [model]'s devices against [library] and [settings].
CostEstimate computeRoomCost({
  required AvFlowModel model,
  required AvDeviceLibrary library,
  required RoomCostSettings settings,
  LaborRateBook? rates,
}) {
  final book = rates ?? LaborRateBook.builtIn();
  final equipment = <CostLine>[];
  int unpricedLines = 0;
  int unpricedDevices = 0;

  final groups = groupDevices(model)
    ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

  for (final group in groups) {
    final catalog = library.templateForModel(group.model);
    final override = settings.priceOverrides[group.key];

    final double price;
    final PriceSource source;
    if (override != null) {
      price = override;
      source = PriceSource.override;
    } else if (catalog != null && catalog.price > 0) {
      price = catalog.price;
      source = PriceSource.catalog;
    } else {
      price = 0;
      source = PriceSource.none;
    }
    if (source == PriceSource.none) {
      unpricedLines++;
      unpricedDevices += group.qty;
    }

    equipment.add(
      CostLine(
        key: group.key,
        description: group.label,
        model: group.model,
        category: catalog?.category ?? '',
        qty: group.qty.toDouble(),
        unitPrice: price,
        source: source,
      ),
    );
  }

  final extras = [
    for (final item in settings.items)
      CostLine(
        key: item.id,
        description: item.description.trim().isEmpty
            ? '(unnamed item)'
            : item.description,
        category: item.category,
        qty: item.qty,
        unitPrice: item.unitPrice,
        taxable: item.taxable,
      ),
  ];

  // --- labour: rate x techs x hours, off the shared rate card -------------
  final labor = <LaborCostLine>[];
  for (final line in settings.labor) {
    final rate = book.byId(line.rateId);
    final hourly = line.rateFrom(book);
    labor.add(
      LaborCostLine(
        id: line.id,
        roleName: rate?.name ?? (line.rateId.isEmpty ? 'Labor' : line.rateId),
        description: line.description,
        techs: line.techs,
        hours: line.hours,
        hourlyRate: hourly,
        taxable: line.taxable,
        // Hours with no rate behind them: real work, missing money.
        unrated: hourly <= 0 && line.totalHours() > 0,
      ),
    );
  }
  final laborTotal = _cents(labor.fold(0.0, (sum, l) => sum + l.total));
  final laborHours = labor.fold(0.0, (sum, l) => sum + l.totalHours);
  final unratedLabor = labor.where((l) => l.unrated).length;

  final equipmentTotal = _cents(
    equipment.fold(0.0, (sum, l) => sum + l.total),
  );
  final extrasTotal = _cents(extras.fold(0.0, (sum, l) => sum + l.total));
  final subtotal = _cents(equipmentTotal + extrasTotal + laborTotal);

  // Every fee is a percentage of the SAME pre-tax subtotal — they don't
  // compound onto each other, because two 5% fees quoted on a job mean 10% of
  // the job, not 10.25%.
  final fees = <FeeAmount>[
    for (final fee in settings.fees)
      (fee: fee, amount: _cents(subtotal * fee.percent / 100)),
  ];
  final feeTotal = _cents(fees.fold(0.0, (sum, f) => sum + f.amount));

  final taxableExtras = _cents(
    extras.where((l) => l.taxable).fold(0.0, (sum, l) => sum + l.total),
  );
  final taxableLabor = _cents(
    labor.where((l) => l.taxable).fold(0.0, (sum, l) => sum + l.total),
  );
  final taxableFees = _cents(
    fees.where((f) => f.fee.taxable).fold(0.0, (sum, f) => sum + f.amount),
  );
  final taxableBase = _cents(
    equipmentTotal + taxableExtras + taxableLabor + taxableFees,
  );
  final tax = _cents(taxableBase * settings.taxPercent / 100);

  return CostEstimate(
    currency: settings.currency,
    equipment: equipment,
    extras: extras,
    labor: labor,
    fees: fees,
    equipmentTotal: equipmentTotal,
    extrasTotal: extrasTotal,
    laborTotal: laborTotal,
    laborHours: laborHours,
    unratedLabor: unratedLabor,
    subtotal: subtotal,
    feeTotal: feeTotal,
    taxableBase: taxableBase,
    taxPercent: settings.taxPercent,
    taxLabel: settings.taxLabel,
    tax: tax,
    grandTotal: _cents(subtotal + feeTotal + tax),
    unpricedLines: unpricedLines,
    unpricedDevices: unpricedDevices,
  );
}

// ---------------------------------------------------------------------------
//  FORMATTING
// ---------------------------------------------------------------------------

/// "$12,480.00". Hand-rolled because the app carries no intl dependency and
/// an estimate with an unseparated five-figure number is hard to read.
String formatMoney(double value, [String currency = r'$']) {
  final negative = value < 0;
  final fixed = value.abs().toStringAsFixed(2);
  final parts = fixed.split('.');
  final digits = parts[0];
  final buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${negative ? '-' : ''}$currency$buffer.${parts[1]}';
}

/// A number the way it should sit in a text field: "90", not "90.0", and
/// "12.5" kept as "12.5". Used for the watts and percentage fields, where a
/// trailing ".0" is noise the user then has to edit around.
String trimNumber(num value) {
  final fixed = value.toStringAsFixed(2);
  if (!fixed.contains('.')) return fixed;
  return fixed
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
}

/// Trims a percentage to something a quote would print: 8.25%, 3%, 0.5%.
String formatPercent(double value) => '${trimNumber(value)}%';

/// Money as a NUMBER for the workbook, so the cells can be summed in Excel
/// rather than being text that merely looks like money.
double money(double value) => _cents(value);

// ---------------------------------------------------------------------------
//  REPORT SECTIONS
// ---------------------------------------------------------------------------

/// The Cost Estimate sheet: what is being bought, what is being added on top,
/// and what it comes to.
List<ReportSection> costReportSections(CostEstimate estimate) {
  // Nothing priced, nothing added, no fees, no tax: a totals table of zeros
  // says less than nothing. The caller shows an explanation instead.
  if (estimate.equipment.isEmpty &&
      estimate.extras.isEmpty &&
      estimate.labor.isEmpty &&
      estimate.fees.isEmpty &&
      estimate.taxPercent == 0) {
    return const [];
  }

  final currency = estimate.currency;

  final sections = <ReportSection>[
    (
      title: 'Equipment',
      header: [
        'Device',
        'Model',
        'Qty',
        'Unit price ($currency)',
        'Extended ($currency)',
        'Price from',
      ],
      rows: [
        for (final line in estimate.equipment)
          [
            line.description,
            line.model,
            line.qty,
            money(line.unitPrice),
            money(line.total),
            kPriceSourceLabels[line.source] ?? '',
          ],
      ],
    ),
    (
      title: 'Labor',
      header: [
        'Role',
        'Scope',
        'Techs',
        'Hours ea.',
        'Total hours',
        'Rate ($currency/hr)',
        'Extended ($currency)',
        'Taxable',
      ],
      rows: [
        for (final line in estimate.labor)
          [
            line.roleName,
            line.description,
            line.techs,
            line.hours,
            line.totalHours,
            line.unrated ? 'no rate set' : money(line.hourlyRate),
            money(line.total),
            line.taxable ? 'Yes' : 'No',
          ],
      ],
    ),
    (
      title: 'Other Items',
      header: [
        'Description',
        'Category',
        'Qty',
        'Unit price ($currency)',
        'Extended ($currency)',
        'Taxable',
      ],
      rows: [
        for (final line in estimate.extras)
          [
            line.description,
            line.category,
            line.qty,
            money(line.unitPrice),
            money(line.total),
            line.taxable ? 'Yes' : 'No',
          ],
      ],
    ),
  ];

  final totals = <List<dynamic>>[
    ['Equipment', money(estimate.equipmentTotal)],
    if (estimate.labor.isNotEmpty) ...[
      [
        'Labor (${trimNumber(estimate.laborHours)} h)',
        money(estimate.laborTotal),
      ],
    ],
    if (estimate.extras.isNotEmpty) ['Other items', money(estimate.extrasTotal)],
    ['Subtotal (before fees and tax)', money(estimate.subtotal)],
    for (final f in estimate.fees)
      [
        '${f.fee.name} (${formatPercent(f.fee.percent)} of subtotal)'
            '${f.fee.taxable ? '' : ' — not taxed'}',
        money(f.amount),
      ],
    if (estimate.fees.length > 1) ['Fees total', money(estimate.feeTotal)],
    if (estimate.taxPercent > 0) ...[
      ['Taxable amount', money(estimate.taxableBase)],
      [
        '${estimate.taxLabel} (${formatPercent(estimate.taxPercent)})',
        money(estimate.tax),
      ],
    ],
    ['TOTAL ($currency)', money(estimate.grandTotal)],
    if (estimate.unpricedLines > 0)
      [
        'Not included — devices with no price',
        '${estimate.unpricedDevices} device'
            '${estimate.unpricedDevices == 1 ? '' : 's'} '
            'on ${estimate.unpricedLines} line'
            '${estimate.unpricedLines == 1 ? '' : 's'}',
      ],
    if (estimate.unratedLabor > 0)
      [
        'Not included — labor with no rate',
        '${estimate.unratedLabor} line'
            '${estimate.unratedLabor == 1 ? '' : 's'} of hours whose job type '
            'has no rate set on the rate card',
      ],
  ];

  sections.add((title: 'Totals', header: ['Item', 'Amount'], rows: totals));
  return sections.where((s) => s.rows.isNotEmpty).toList();
}
