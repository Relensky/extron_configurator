import 'av_device_library.dart'
    show AvDeviceLibrary, AvDeviceTemplate, PricingTier;
import 'base_costs.dart' show BaseCostBook;
import 'building_project.dart' show ManualRoom, ManualRoomItem;

/// ============================================================================
///  WHAT IS IN A ROOM NOBODY HAS DRAWN, AND WHAT IT IS WORTH
/// ============================================================================
///  A line item on the refresh plan is a date, a life and a figure — see
///  [ManualRoom]. The figure came off the estate's master sheet, which priced
///  the room against a room TYPE, and for most of the estate that figure is
///  every fact anybody has. It is enough to budget with and not enough to
///  argue with: "twenty-four thousand for AGYM 129" is a number, not a case.
///
///  A survey of the control systems answers the other half — the projectors,
///  the switcher, the touch panel, the camera, by model — and this file is
///  what turns that list into money.
///
///  THE SAME LADDER A DRAWN ROOM'S BOXES GO DOWN, deliberately: the catalog's
///  price for the model, then the base-cost card's figure for what the box
///  DOES, then nothing. See [equipmentReplacementPrice], which does exactly
///  this for a position on a drawing. Two rooms holding the same projector
///  must not be priced two different ways because one of them has been drawn.
///
///  AND IT IS NOT THE REFRESH FIGURE. The survey is what is installed today,
///  most of it eight or ten years old; the refresh figure is what it costs to
///  put a new room in, cabling and labor included. They answer different
///  questions and the screen shows both, labeled. Nothing in this file feeds
///  the year columns, the totals or the campus rollup.
/// ============================================================================

/// One surveyed box, priced.
typedef ManualItemPrice = ({
  /// Unit price, or 0 when nothing can price it.
  double unit,

  /// [unit] times the quantity.
  double line,

  /// True when the figure is a typical price off the base-cost card rather
  /// than a catalog price for this model. Said out loud everywhere it is
  /// shown — a card figure read as a quote is how a budget goes wrong quietly.
  bool estimated,

  /// The model the figure is actually FOR, when that is not the model in the
  /// room: the successor to a retired entry, or the model the card was
  /// benchmarked on. Empty when the price is the row's own.
  String pricedAs,
});

/// What one line of a survey costs to buy today.
///
/// [library] and [baseCosts] are both optional and the answer degrades rather
/// than failing: with neither, everything reports as unpriced, which is the
/// truthful answer for a caller that has no catalog.
ManualItemPrice manualRoomItemPrice(
  ManualRoomItem item, {
  AvDeviceLibrary? library,
  BaseCostBook? baseCosts,
  PricingTier tier = PricingTier.msrp,
}) {
  final quantity = item.quantity < 1 ? 1 : item.quantity;

  // WHAT WOULD ACTUALLY BE BOUGHT. Half this survey is models Extron stopped
  // selling years ago, which is rather the point of a refresh plan; pricing
  // one at the list of a product nobody sells is the failure this follows the
  // retirement chain to avoid.
  final AvDeviceTemplate? found = library?.templateForModel(item.model);
  final buying = found == null ? null : (library!.successorFor(item.model) ?? found);
  final catalog = buying?.priceForTier(tier).price ?? 0;
  if (catalog > 0) {
    final swapped = buying!.model.trim().toLowerCase() !=
        item.model.trim().toLowerCase();
    return (
      unit: catalog,
      line: catalog * quantity,
      estimated: false,
      pricedAs: swapped ? buying.model : '',
    );
  }

  if (baseCosts == null) {
    return (unit: 0, line: 0, estimated: false, pricedAs: '');
  }

  // Two goes at the card, the same two the drawn-room ladder takes: what the
  // box DOES first, because that is the role the survey recorded, then the
  // catalog family it was filed under, because 'Matrix' is what a manufacturer
  // calls a switcher and the card is written in this app's words.
  final role = item.category.trim();
  final family = found?.category.trim() ?? '';
  var base = baseCosts.priceFor(role, tier);
  var card = baseCosts.byCategory(baseCosts.resolveCategory(role));
  if (base.price <= 0 && family.isNotEmpty && family != role) {
    base = baseCosts.priceFor(family, tier);
    card = baseCosts.byCategory(baseCosts.resolveCategory(family));
  }
  if (base.price <= 0) {
    return (unit: 0, line: 0, estimated: false, pricedAs: '');
  }
  return (
    unit: base.price,
    line: base.price * quantity,
    estimated: true,
    // The card can name the model it was benchmarked on, which is what makes
    // a typical figure something a reader can argue with.
    pricedAs: card?.standardModel.trim() ?? '',
  );
}

/// A whole room's survey, priced.
typedef ManualRoomEquipmentTotal = ({
  /// What every priced line adds up to.
  double cost,

  /// How many boxes are in the room, counting quantities.
  int count,

  /// How many of them nothing could price. Reported rather than folded into
  /// [cost] as zero: a room reading '9,400' with four boxes missing from it is
  /// a wrong number, and one reading '9,400, 4 unpriced' is an answer.
  int unpriced,

  /// True when any figure in [cost] came off the base-cost card.
  bool estimated,
});

/// Adds up what a line item's surveyed equipment costs to buy today.
ManualRoomEquipmentTotal manualRoomEquipmentTotal(
  ManualRoom room, {
  AvDeviceLibrary? library,
  BaseCostBook? baseCosts,
  PricingTier tier = PricingTier.msrp,
}) {
  var cost = 0.0;
  var count = 0;
  var unpriced = 0;
  var estimated = false;
  for (final item in room.equipment) {
    final quantity = item.quantity < 1 ? 1 : item.quantity;
    count += quantity;
    final price = manualRoomItemPrice(
      item,
      library: library,
      baseCosts: baseCosts,
      tier: tier,
    );
    if (price.line <= 0) {
      unpriced += quantity;
      continue;
    }
    cost += price.line;
    estimated |= price.estimated;
  }
  return (cost: cost, count: count, unpriced: unpriced, estimated: estimated);
}

/// The survey rolled up by what the boxes DO — 'Projector ×2', 'Camera ×1'.
///
/// Eleven models is a list to read; four roles is a sentence, and the row on
/// the plan has space for a sentence. Ordered by count so the room leads with
/// what it is mostly made of, and by name inside a tie so two rooms with the
/// same kit read the same way.
List<({String role, int count})> manualRoomRoleCounts(ManualRoom room) {
  final counts = <String, int>{};
  for (final item in room.equipment) {
    final role = item.category.trim().isEmpty ? 'Other' : item.category.trim();
    counts[role] = (counts[role] ?? 0) + (item.quantity < 1 ? 1 : item.quantity);
  }
  final rows = [
    for (final entry in counts.entries) (role: entry.key, count: entry.value),
  ];
  rows.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.role.compareTo(b.role);
  });
  return rows;
}

/// The survey as one phrase: 'in the room: 2 Projector, 1 Switcher, 1 Camera'.
///
/// Capped, because a lecture hall surveys at nine roles and the row it sits on
/// is one line high. The count leads so the tail that gets cut is the part
/// nobody was reading.
String manualRoomEquipmentSummary(ManualRoom room, {int most = 4}) {
  final roles = manualRoomRoleCounts(room);
  if (roles.isEmpty) return '';
  final shown = roles.take(most).map((r) => '${r.count} ${r.role}').join(', ');
  final rest = roles.length - most;
  return rest > 0 ? 'in the room: $shown +$rest more' : 'in the room: $shown';
}

/// What to call a surveyed box on screen.
///
/// The model, with the maker in front of it when the model ALONE says nothing:
/// the catalog carries a Da-Lite screen controller whose model is the word
/// 'Controller' and an Inogeni USB switch whose model is 'Toggle', and forty
/// rows reading 'Controller' is a list nobody can check against a room.
///
/// A model with a number in it identifies itself - 'PT-VMZ62BU8', 'TLP Pro
/// 725T' - and is left alone, because the maker in front of every one of those
/// is a column of noise. The stored model is untouched either way; this is a
/// label, and [manualRoomItemPrice] still looks the catalog up by the real
/// thing.
String manualRoomItemLabel(ManualRoomItem item, {AvDeviceLibrary? library}) {
  final model = item.model.trim();
  if (model.isEmpty || model.contains(RegExp(r'[0-9]'))) return model;
  final maker = library?.templateForModel(model)?.manufacturer.trim() ?? '';
  if (maker.isEmpty) return model;
  return model.toLowerCase().startsWith(maker.toLowerCase())
      ? model
      : '$maker $model';
}
