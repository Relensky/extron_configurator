import 'package:flutter/foundation.dart';

/// Which rows on a project's Rooms pane are opened out: the room rows and
/// the priorities on the funding card. Everything starts collapsed; Expand
/// all and Collapse all set every row at once. Kept for the session only.
class ProjectFold extends ChangeNotifier {
  ProjectFold._();
  static final ProjectFold instance = ProjectFold._();

  /// What a row is until it is toggled. Tests that read row details set it.
  bool defaultOpen = false;

  /// Rows toggled away from [defaultOpen].
  final Set<String> _flipped = {};

  bool isOpen(String key) => defaultOpen != _flipped.contains(key);

  void toggle(String key) {
    if (!_flipped.remove(key)) _flipped.add(key);
    notifyListeners();
  }

  /// Opens or closes every row.
  void setAll(bool open) {
    defaultOpen = open;
    _flipped.clear();
    notifyListeners();
  }

  static String room(String id) => 'room:$id';
  static String priority(int p) => 'priority:$p';
}
