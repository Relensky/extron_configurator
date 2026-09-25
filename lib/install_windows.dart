import 'dart:math';

import 'class_schedule.dart' show formatScheduleMinutes;

/// ============================================================================
///  AN INSTALL WINDOW ON THE JOB'S TIMELINE
/// ============================================================================
///  A stretch of time a room is free - picked off the class schedule (see
///  class_schedule.dart and install_window_finder.dart) - put on the project
///  so the timeline shows when each room can actually be worked on.
///
///  Ids are random rather than counted, for the same reason the budget's are:
///  two people adding windows to one job at once must not collide.
/// ============================================================================
class InstallWindow {
  final String id;

  /// The project room it is for ([ProjectRoomRef.id] or [ManualRoom.id]).
  final String roomId;

  /// What the room is called, kept so the timeline reads even if the room is
  /// later taken off the job.
  final String roomLabel;

  final DateTime day;
  final int startMinutes;
  final int endMinutes;
  final bool wholeDay;
  final String notes;

  const InstallWindow({
    required this.id,
    required this.roomId,
    required this.roomLabel,
    required this.day,
    required this.startMinutes,
    required this.endMinutes,
    this.wholeDay = false,
    this.notes = '',
  });

  factory InstallWindow.create({
    required String roomId,
    required String roomLabel,
    required DateTime day,
    required int startMinutes,
    required int endMinutes,
    bool wholeDay = false,
  }) =>
      InstallWindow(
        id: 'iw-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
            '${Random().nextInt(1 << 30).toRadixString(36)}',
        roomId: roomId,
        roomLabel: roomLabel,
        day: DateTime(day.year, day.month, day.day),
        startMinutes: startMinutes,
        endMinutes: endMinutes,
        wholeDay: wholeDay,
      );

  /// The room number alone - "BUTTE 101" out of "BUTTE 101 - Lecture Hall".
  String get roomCode {
    final code = roomLabel.split(' - ').first.trim();
    return code.isEmpty ? roomLabel : code;
  }

  DateTime get start => day.add(Duration(minutes: startMinutes));
  DateTime get end => day.add(Duration(minutes: endMinutes));

  String get timeLabel => wholeDay
      ? 'All day'
      : '${formatScheduleMinutes(startMinutes)} - '
          '${formatScheduleMinutes(endMinutes)}';

  /// Whether this is the same slot as another, for "already added".
  bool sameSlot(String room, DateTime d, int s, int e) =>
      roomId == room &&
      day.year == d.year &&
      day.month == d.month &&
      day.day == d.day &&
      startMinutes == s &&
      endMinutes == e;

  InstallWindow copyWith({String? notes}) => InstallWindow(
        id: id,
        roomId: roomId,
        roomLabel: roomLabel,
        day: day,
        startMinutes: startMinutes,
        endMinutes: endMinutes,
        wholeDay: wholeDay,
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'roomId': roomId,
        'roomLabel': roomLabel,
        'day': '${day.year.toString().padLeft(4, '0')}-'
            '${day.month.toString().padLeft(2, '0')}-'
            '${day.day.toString().padLeft(2, '0')}',
        'start': startMinutes,
        'end': endMinutes,
        if (wholeDay) 'wholeDay': true,
        if (notes.isNotEmpty) 'notes': notes,
      };

  static InstallWindow? fromJson(Map<String, dynamic> json) {
    final day = DateTime.tryParse(json['day']?.toString() ?? '');
    final s = (json['start'] as num?)?.toInt();
    final e = (json['end'] as num?)?.toInt();
    if (day == null || s == null || e == null) return null;
    return InstallWindow(
      id: json['id']?.toString() ?? 'iw-$s-$e-${day.millisecondsSinceEpoch}',
      roomId: json['roomId']?.toString() ?? '',
      roomLabel: json['roomLabel']?.toString() ?? '',
      day: day,
      startMinutes: s,
      endMinutes: e,
      wholeDay: json['wholeDay'] == true,
      notes: json['notes']?.toString() ?? '',
    );
  }
}
