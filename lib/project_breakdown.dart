import 'building_project.dart';
import 'project_estimate.dart';

/// ============================================================================
///  BUILDINGS AND DEPARTMENTS
/// ============================================================================
///  Every room on the job - drawn rooms and line items - with the building it
///  is in, the department it is for, the money set aside for it and what it
///  comes to. The funding card and the building filter both read from here.
/// ============================================================================

/// One room's share of the budget.
typedef ProjectBudgetEntry = ({
  String roomId,
  String manualId,
  String building,
  String department,
  double target,
  double? total,
});

/// The building codes typed into the project's Buildings field, upper case.
List<String> typedBuildingCodes(String field) => [
  for (final part in field.split(RegExp(r'[,;/]+|\s+')))
    if (part.trim().isNotEmpty) part.trim().toUpperCase(),
];

/// A line item's building: the first word of its name ('BSS 214') when that
/// is one of [known].
String lineItemBuilding(String name, Set<String> known) {
  final first = name.trim().split(RegExp(r'\s+')).first.toUpperCase();
  return known.contains(first) ? first : '';
}

/// Every counted room on [project], priced off [full] - the job's whole
/// estimate, not a filtered one.
List<ProjectBudgetEntry> projectBudgetEntries(
  BuildingProject project,
  ProjectEstimate full,
) {
  final costs = {for (final r in full.rooms) r.ref.id: r};
  final drawn = [
    for (final ref in project.includedRooms)
      (
        ref: ref,
        building: buildingCodeFromConfig(costs[ref.id]?.room.config ?? const {}),
      ),
  ];
  final known = {
    ...typedBuildingCodes(project.building),
    for (final d in drawn)
      if (d.building.isNotEmpty) d.building,
  };
  return [
    for (final d in drawn)
      (
        roomId: d.ref.id,
        manualId: '',
        building: d.building,
        department: d.ref.department.trim(),
        target: d.ref.targetPrice,
        total: costs[d.ref.id]?.ok == true ? costs[d.ref.id]!.total : null,
      ),
    for (final line in project.manualRooms)
      (
        roomId: '',
        manualId: line.id,
        building: lineItemBuilding(line.name, known),
        department: line.department.trim(),
        target: line.targetPrice,
        total: line.replacementCost > 0 ? line.replacementCost : null,
      ),
  ];
}

/// Rooms added up under one building or department.
class ProjectBudgetGroup {
  /// The building code or department; '' for rooms with none.
  final String name;
  int rooms = 0;
  double target = 0;
  double total = 0;

  ProjectBudgetGroup(this.name);
}

/// [entries] added up by [keyOf], named groups first in order, the blank
/// group last. [names] are listed even with no rooms.
List<ProjectBudgetGroup> groupBudget(
  Iterable<ProjectBudgetEntry> entries,
  String Function(ProjectBudgetEntry) keyOf, {
  Iterable<String> names = const [],
}) {
  // Case-insensitive, so 'physics' and 'Physics' are one department.
  final groups = <String, ProjectBudgetGroup>{
    for (final n in names) n.toLowerCase(): ProjectBudgetGroup(n),
  };
  for (final e in entries) {
    final name = keyOf(e);
    final g = groups.putIfAbsent(
      name.toLowerCase(),
      () => ProjectBudgetGroup(name),
    );
    g
      ..rooms += 1
      ..target += e.target
      ..total += e.total ?? 0;
  }
  return groups.values.toList()..sort((a, b) {
    if (a.name.isEmpty != b.name.isEmpty) return a.name.isEmpty ? 1 : -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
}

/// The job's buildings, each with its rooms and money - for the filter.
List<ProjectBudgetGroup> projectBuildings(
  BuildingProject project,
  ProjectEstimate full,
) => groupBudget(
  projectBudgetEntries(project, full),
  (e) => e.building,
  names: typedBuildingCodes(project.building),
);
