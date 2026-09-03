import 'av_device_library.dart' show AvDeviceLibrary, AvDeviceTemplate;
import 'av_flow_model.dart' show AvFlowModel, AvNode;
import 'base_costs.dart' show categoryForConfigKey;
import 'building_project.dart' show ManualRoomItem;

/// ============================================================================
///  PUTTING THE SURVEY ONTO THE ROOM SOMEBODY JUST DREW
/// ============================================================================
///  Building a room from a line item stamps out the ROOM TYPE the estate's
///  sheet priced it against: a two-projector room gets two projectors, a
///  switcher, a touch panel, wired the way that type is wired. That is the
///  right skeleton and the wrong bill of materials - the models on it are the
///  type's models, and the room has whatever went in in 2015.
///
///  The survey knows what actually went in. So the two are reconciled: the
///  preset keeps the drawing, the cabling and the jack numbering, and the
///  survey supplies the MODELS. What comes out is a room that is wired like
///  its type and stocked like itself, which is what somebody about to refresh
///  it needs to look at.
///
///  MATCHED BY WHAT A BOX DOES, not by name and not by position. The survey
///  has no positions - it is an inventory - and the preset's labels are the
///  type's labels. What both ends agree on is the role: a projector is the
///  room's projector whether the drawing calls it 'Projector 1' and the poll
///  calls it 'Epson EB-L630U'.
///
///  WHAT IS NOT MATCHED IS REPORTED, NOT INVENTED. A surveyed box with no
///  position of its own on the drawing is left over and said out loud; adding
///  an unwired, unplaced box to a drawing to make a count come out even is how
///  a diagram stops being a diagram. Equally, a preset position the survey
///  never mentioned keeps the type's model: the alternative is blanking a box
///  because a poll could not see it, and a poll cannot see a screen.
///
///  NOTHING HERE WRITES. This is the arithmetic; see `applySurveyToRoom` in
///  save_actions.dart for the half that goes through the provider.
/// ============================================================================

/// One surveyed box, and the position on the drawing it belongs on.
typedef SurveyPlacement = ({
  /// What the survey says is in the room.
  ManualRoomItem item,

  /// The position it is going onto.
  AvNode onto,

  /// The catalog entry for the surveyed model, when the catalog has one. Null
  /// means the model is real and the catalog has never carried it - most of
  /// this estate - and the position gets the NAME without the ports, the
  /// wattage or the rack height, because inventing those would be worse than
  /// leaving the type's.
  AvDeviceTemplate? template,
});

/// What reconciling a survey against a drawn room comes to.
typedef SurveyPlan = ({
  /// The positions that are getting a surveyed model.
  List<SurveyPlacement> placements,

  /// Surveyed boxes with no position to go on, as 'role: model' - a document
  /// camera in a room type that has none, a second display in a one-display
  /// room. Said out loud so nobody reads the room as the whole survey.
  List<String> leftOver,

  /// Positions the survey never mentioned, by label. They keep the room
  /// type's model.
  List<String> untouched,
});

/// What a position on the drawing DOES, in the base-cost card's words.
///
/// The catalog's category when it names a role, and the config key otherwise -
/// the same two-step every price in this app takes, so a box priced as a
/// switcher is matched as one.
String roleOfNode(AvNode node, AvDeviceLibrary? library) {
  final template = library?.templateForModel(node.model);
  final family = template?.category.trim() ?? '';
  final byKey = categoryForConfigKey(node.id);
  if (byKey.isNotEmpty) return byKey;
  return family;
}

/// Works out which surveyed box goes on which position. Nothing is written.
///
/// Quantities are expanded first: a survey line of two projectors is two boxes
/// looking for two positions, and a room with one gets one of them placed and
/// one left over.
SurveyPlan planSurveyOntoRoom({
  required List<ManualRoomItem> survey,
  required AvFlowModel model,
  AvDeviceLibrary? library,
}) {
  // Positions that can take a model, by role. Jack fields are not boxes and
  // never carry one.
  final free = <String, List<AvNode>>{};
  for (final node in model.nodes) {
    if (node.isJackField) continue;
    final role = roleOfNode(node, library);
    if (role.isEmpty) continue;
    free.putIfAbsent(role, () => []).add(node);
  }

  final placements = <SurveyPlacement>[];
  final leftOver = <String>[];
  final claimed = <String>{};

  for (final item in survey) {
    final role = item.category.trim();
    final wanted = item.quantity < 1 ? 1 : item.quantity;
    final template = library?.templateForModel(item.model);
    for (var n = 0; n < wanted; n++) {
      final queue = free[role];
      if (role.isEmpty || queue == null || queue.isEmpty) {
        leftOver.add(role.isEmpty ? item.model : '$role: ${item.model}');
        continue;
      }
      final onto = queue.removeAt(0);
      claimed.add(onto.id);
      // A position that already carries the surveyed model needs no swap, and
      // is not reported as one - a room type whose projector IS what went in
      // is the happy case, not an edit.
      if (onto.model.trim().toLowerCase() == item.model.trim().toLowerCase()) {
        continue;
      }
      placements.add((item: item, onto: onto, template: template));
    }
  }

  final untouched = [
    for (final node in model.nodes)
      if (!node.isJackField &&
          !claimed.contains(node.id) &&
          roleOfNode(node, library).isNotEmpty)
        node.label,
  ];

  return (placements: placements, leftOver: leftOver, untouched: untouched);
}

/// The plan as a sentence, for the dialog that asks whether to apply it.
String describeSurveyPlan(SurveyPlan plan) {
  final parts = <String>[
    plan.placements.isEmpty
        ? 'Nothing on the drawing changes model'
        : '${plan.placements.length} position'
              '${plan.placements.length == 1 ? '' : 's'} take the surveyed '
              'model',
    if (plan.leftOver.isNotEmpty)
      '${plan.leftOver.length} surveyed box'
          '${plan.leftOver.length == 1 ? '' : 'es'} have no position on this '
          'room type',
    if (plan.untouched.isNotEmpty)
      '${plan.untouched.length} position'
          '${plan.untouched.length == 1 ? '' : 's'} the survey never mentioned '
          'keep the room type model',
  ];
  return parts.join('  ·  ');
}
