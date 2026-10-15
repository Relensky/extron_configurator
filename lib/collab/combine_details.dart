import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../room_sidecar.dart';
import 'collab_controller.dart';
import 'json_merge.dart';

/// ============================================================================
///  WHAT A COMBINE IS ABOUT, IN FULL
/// ============================================================================
///  "jsmith saved the room" says too little when nine rooms are open across a
///  team. Here: which room, which job and campus, which file, whose save and
///  when - and for each change, the file it is in, its place in that file and
///  the whole value before and after.
/// ============================================================================

/// The open document by name: "BSS 103 on Bessey Hall" for a room on a job,
/// the job's name for a project.
String collabDocName(AppStateProvider p, CollabDocKind kind) {
  switch (kind) {
    case CollabDocKind.room:
      final ref = p.openProjectRoom;
      final room = ref != null
          ? p.projectRoomLogName(ref.id)
          : p.teamRoomId.isNotEmpty
              ? p.teamRoomId
              : roomStem(p.currentConfigPath);
      return p.hasOpenProject && p.projectDisplayName.isNotEmpty
          ? '$room on ${p.projectDisplayName}'
          : room;
    case CollabDocKind.project:
      return p.projectDisplayName;
    case CollabDocKind.catalog:
      return '';
  }
}

/// The lines at the top of the combine: what, where, whose and when.
Future<List<(String, String)>> combineContextRows(
  AppStateProvider p,
  CollabDocKind kind,
  IncomingChange? incoming,
) async {
  final campus = await p.campusDisplayName();
  final ref = p.openProjectRoom;
  final file = switch (kind) {
    CollabDocKind.room => p.currentConfigPath,
    CollabDocKind.project => p.currentProjectPath,
    CollabDocKind.catalog => p.avDeviceLibrary.filePath,
  };
  String two(int n) => n.toString().padLeft(2, '0');
  return [
    if (kind == CollabDocKind.room)
      (
        'Room',
        ref != null
            ? p.projectRoomLogName(ref.id)
            : p.teamRoomId.isNotEmpty
                ? p.teamRoomId
                : roomStem(p.currentConfigPath),
      ),
    if (p.hasOpenProject) ('Project', p.projectDisplayName),
    if (campus.isNotEmpty) ('Campus', campus),
    if (file.isNotEmpty) ('File', file),
    if (incoming != null) ...[
      ('Saved by', incoming.who),
      (
        'Noticed at',
        '${two(incoming.at.hour)}:${two(incoming.at.minute)}:'
            '${two(incoming.at.second)}',
      ),
    ],
  ];
}

/// The file on disk one change lives in. A room is its config plus the
/// sidecars beside it; its merge document is `{config, av}`, and an `av` key
/// belongs to the sidecar part that owns it.
String fileForMergePath(AppStateProvider p, CollabDocKind kind, String path) {
  switch (kind) {
    case CollabDocKind.project:
      return p.currentProjectPath;
    case CollabDocKind.catalog:
      return p.avDeviceLibrary.filePath;
    case CollabDocKind.room:
      final config = p.currentConfigPath;
      if (config.isEmpty) return '';
      if (!path.startsWith('av')) return config;
      final key = RegExp(r'^av\.([A-Za-z0-9_]+)').firstMatch(path)?.group(1);
      for (final e in kRoomSidecarKeys.entries) {
        if (key != null && e.value.contains(key)) {
          return roomSidecarPath(config, e.key);
        }
      }
      return roomSidecarPath(config, RoomSidecarPart.flow);
  }
}

/// A value in full, for the expanded view: JSON laid out, text as typed.
String fullMergeValue(Object? v) {
  if (v == null) return '(none)';
  if (v is String) return v.isEmpty ? '(blank)' : v;
  if (v is Map || v is List) {
    return const JsonEncoder.withIndent('  ').convert(v);
  }
  return '$v';
}

/// The context lines as a small table.
class CombineContextTable extends StatelessWidget {
  final List<(String, String)> rows;

  const CombineContextTable({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Container(
      key: const ValueKey('combine_context'),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 90,
                    child: Text(label,
                        style:
                            theme.textTheme.bodySmall?.copyWith(color: muted)),
                  ),
                  Expanded(
                    child: SelectableText(
                      value,
                      key: ValueKey('combine_context_$label'),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Everything about one change, shown when its row is opened.
class MergeChangeDetails extends StatelessWidget {
  final MergeChange change;
  final String place;
  final String file;

  const MergeChangeDetails({
    super.key,
    required this.change,
    required this.place,
    required this.file,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'Consolas');
    Widget line(String label, String value, {bool code = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 90,
                child: Text(label,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      value,
                      style: code ? mono : theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
    return Container(
      key: ValueKey('combine_details_${change.key}'),
      margin: const EdgeInsets.fromLTRB(56, 0, 8, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line('Where', place),
          if (file.isNotEmpty) line('File', file),
          line('Data path', change.path, code: true),
          line('Before', fullMergeValue(change.before), code: true),
          line('After', fullMergeValue(change.after), code: true),
        ],
      ),
    );
  }
}

/// The place's parent - everything but its last step - for grouping the
/// changes under the thing they belong to.
String mergePlaceGroup(String place) {
  final i = place.lastIndexOf(' > ');
  return i < 0 ? '' : place.substring(0, i);
}

/// The place's last step - the field itself.
String mergePlaceLeaf(String place) {
  final i = place.lastIndexOf(' > ');
  return i < 0 ? place : place.substring(i + 3);
}
