import 'package:flutter/foundation.dart';

/// Which rows on a project's Rooms pane are opened out: the room rows and
/// the priorities on the funding card. Everything starts collapsed; Expand
/// all and Collapse all set every row at once. Kept for the session only.
class ProjectFold extends ChangeNotifier {
  ProjectFold._();
  static final ProjectFold instance = ProjectFold._();

  /// What a room row is until it is toggled. Tests that read row details
  /// set it.
  bool defaultOpen = false;

  /// What a priority group is until it is toggled: open, so the rooms under
  /// each priority show without a click.
  bool defaultPriorityOpen = true;

  /// Rows toggled away from their default.
  final Set<String> _flipped = {};

  bool isOpen(String key) =>
      (key.startsWith('priority:') ? defaultPriorityOpen : defaultOpen) !=
      _flipped.contains(key);

  void toggle(String key) {
    if (!_flipped.remove(key)) _flipped.add(key);
    notifyListeners();
  }

  /// Opens or closes every row.
  void setAll(bool open) {
    defaultOpen = open;
    defaultPriorityOpen = open;
    _flipped.clear();
    notifyListeners();
  }

  /// Opens or closes every priority group, leaving the room rows.
  void setAllPriorities(bool open) {
    defaultPriorityOpen = open;
    _flipped.removeWhere((k) => k.startsWith('priority:'));
    notifyListeners();
  }

  /// Opens or closes every room row, leaving the priority groups.
  void setAllRooms(bool open) {
    defaultOpen = open;
    _flipped.removeWhere((k) => k.startsWith('room:'));
    notifyListeners();
  }

  static String room(String id) => 'room:$id';
  static String priority(int p) => 'priority:$p';
}
