import 'dart:math';

/// ============================================================================
///  THE JOB'S BUDGET, FILLED IN AS IT GOES
/// ============================================================================
///  A job usually starts with a number - what the department has to spend -
///  long before anything is priced. The budget holds that number and the lines
///  spent against it, typed in as the job goes: a quote that came back, a PO
///  raised, an invoice paid. Beside it the Project tab shows what the rooms'
///  estimates come to, so "are we inside the budget" can be answered at any
///  point - with a guess on day one and with invoices at the end.
///
///  Each line is PLANNED (expected), COMMITTED (ordered or signed) or SPENT
///  (paid). Remaining is the budget less everything committed or spent; the
///  planned lines are shown as the forecast on top of that.
///
///  Ids are random rather than counted, so two people adding lines to the
///  same job at the same time never hand out the same id - see
///  collab/json_merge.dart, which merges the list line by line on save.
/// ============================================================================

enum BudgetStatus { planned, committed, spent }

const kBudgetStatusLabels = {
  BudgetStatus.planned: 'Planned',
  BudgetStatus.committed: 'Committed',
  BudgetStatus.spent: 'Spent',
};

/// The categories offered for a line. Free text is allowed too.
const kBudgetCategories = [
  'Equipment',
  'Labor',
  'Cabling',
  'Infrastructure',
  'Furniture',
  'Services',
  'Contingency',
  'Other',
];

class BudgetLine {
  final String id;
  final String item;
  final String category;
  final String vendor;
  final double amount;
  final BudgetStatus status;
  final DateTime? date;
  final String notes;

  const BudgetLine({
    required this.id,
    this.item = '',
    this.category = '',
    this.vendor = '',
    this.amount = 0,
    this.status = BudgetStatus.planned,
    this.date,
    this.notes = '',
  });

  /// A fresh line with an id nobody else's copy of the job will also issue.
  factory BudgetLine.create({
    String item = '',
    String category = '',
    String vendor = '',
    double amount = 0,
    BudgetStatus status = BudgetStatus.planned,
    DateTime? date,
    String notes = '',
  }) =>
      BudgetLine(
        id: newBudgetLineId(),
        item: item,
        category: category,
        vendor: vendor,
        amount: amount,
        status: status,
        date: date,
        notes: notes,
      );

  BudgetLine copyWith({
    String? item,
    String? category,
    String? vendor,
    double? amount,
    BudgetStatus? status,
    DateTime? date,
    bool clearDate = false,
    String? notes,
  }) =>
      BudgetLine(
        id: id,
        item: item ?? this.item,
        category: category ?? this.category,
        vendor: vendor ?? this.vendor,
        amount: amount ?? this.amount,
        status: status ?? this.status,
        date: clearDate ? null : (date ?? this.date),
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'item': item,
        if (category.isNotEmpty) 'category': category,
        if (vendor.isNotEmpty) 'vendor': vendor,
        'amount': amount,
        'status': status.name,
        if (date != null)
          'date': '${date!.year.toString().padLeft(4, '0')}-'
              '${date!.month.toString().padLeft(2, '0')}-'
              '${date!.day.toString().padLeft(2, '0')}',
        if (notes.isNotEmpty) 'notes': notes,
      };

  factory BudgetLine.fromJson(Map<String, dynamic> json) {
    final raw = json['amount'];
    return BudgetLine(
      id: json['id']?.toString().trim().isNotEmpty == true
          ? json['id'].toString()
          : newBudgetLineId(),
      item: json['item']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      vendor: json['vendor']?.toString() ?? '',
      amount: raw is num
          ? raw.toDouble()
          : double.tryParse('${raw ?? ''}'.replaceAll(RegExp(r'[^0-9.\-]'), '')) ??
              0,
      status: BudgetStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => BudgetStatus.planned,
      ),
      date: DateTime.tryParse(json['date']?.toString() ?? ''),
      notes: json['notes']?.toString() ?? '',
    );
  }
}

final _rnd = Random();

/// `bud-<time>-<random>`: unique across machines without a shared counter.
String newBudgetLineId() =>
    'bud-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
    '${_rnd.nextInt(1 << 30).toRadixString(36)}';

/// The budget read against its lines and the rooms' estimate.
class BudgetSummary {
  final double budget;
  final double planned;
  final double committed;
  final double spent;

  /// What the rooms' estimates come to, for comparison. 0 when not priced.
  final double estimate;

  const BudgetSummary({
    required this.budget,
    required this.planned,
    required this.committed,
    required this.spent,
    required this.estimate,
  });

  factory BudgetSummary.of(
    double budget,
    List<BudgetLine> lines, {
    double estimate = 0,
  }) {
    double sum(BudgetStatus s) => lines
        .where((l) => l.status == s)
        .fold(0.0, (a, l) => a + l.amount);
    return BudgetSummary(
      budget: budget,
      planned: sum(BudgetStatus.planned),
      committed: sum(BudgetStatus.committed),
      spent: sum(BudgetStatus.spent),
      estimate: estimate,
    );
  }

  /// Committed plus spent - money that is gone or promised.
  double get used => committed + spent;

  /// The budget less what is committed or spent.
  double get remaining => budget - used;

  /// Remaining once the planned lines land too.
  double get forecastRemaining => budget - used - planned;

  /// The budget less the rooms' estimate.
  double get estimateHeadroom => budget - estimate;

  bool get hasBudget => budget > 0;

  /// 0..1+ share of the budget used; 0 with no budget.
  double get usedFraction => hasBudget ? used / budget : 0;

  double get forecastFraction => hasBudget ? (used + planned) / budget : 0;
}
