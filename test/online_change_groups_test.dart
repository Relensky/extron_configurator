import 'package:extron_configurator/online_change_groups.dart';
import 'package:extron_configurator/online_pull_history.dart';
import 'package:extron_configurator/online_room_edits.dart' show kRoomLineKind;
import 'package:extron_configurator/online_roundtrip.dart';
import 'package:extron_configurator/online_sheet_merge.dart'
    show kSheetEditKind;
import 'package:flutter_test/flutter_test.dart';

/// A pull's review and history are grouped by room and part of the job.
void main() {
  const roomTabs = {
    'Room 101': (id: 'r1', name: 'Room 101'),
    'Room 102': (id: 'r2', name: 'Room 102'),
  };
  const List<OnlineChange> changes = [
    (kind: 'delivery', id: 'd1', name: 'Projector', what: 'Qty 6 -> 8'),
    (
      kind: kRoomLineKind,
      id: 'r1|model:abc',
      name: 'Room 101: Projector',
      what: 'quantity 1 -> 2',
    ),
    (
      kind: kSheetEditKind,
      id: 'Room 102',
      name: 'Room 102',
      what: 'row added or changed to: Document camera | 1 | 450',
    ),
    (
      kind: kRoomLineKind,
      id: 'r2|item1',
      name: 'Room 102: Speaker',
      what: 'row deleted - line removed (was 2)',
    ),
    (kind: 'purchase order', id: '', name: 'PO-1182', what: 'added'),
    (
      kind: kSheetEditKind,
      id: 'Summary',
      name: 'Summary, row 4 (Total)',
      what: 'column B: "1" -> "2"',
    ),
  ];

  test('rooms first, then deliveries, purchase orders and other tabs', () {
    final groups = groupOnlineChanges(changes, roomTabs: roomTabs);
    expect(groups.map((g) => g.title), [
      'Room 101',
      'Room 102',
      'Deliveries',
      'Purchase orders',
      'Summary tab',
    ]);
    final r102 = groups[1];
    expect(r102.room, isTrue);
    expect(r102.changes, hasLength(2));
    expect(r102.added, ['Document camera - 1']);
    expect(r102.summary, '1 added, 1 removed');
    expect(r102.applied, 1);
    expect(r102.byHand, 1);
    expect(onlineChangeLabel(changes[1], groups.first), 'Projector');
    expect(onlineChangeLabel(changes[5], groups.last), 'row 4 (Total)');
    expect(groups[3].added, ['PO-1182']);
  });

  test('the history file is headed by room and section', () {
    final text = formatOnlinePull(
      at: DateTime(2026, 11, 20, 9),
      project: 'Job',
      who: 'me',
      source: 's',
      changes: changes,
      roomTabs: roomTabs,
    );
    expect(text, contains('Room 101 - 1 changed\r\n'));
    expect(
      text,
      contains('Room 102 - 1 added, 1 removed: Document camera - 1\r\n'),
    );
    expect(text, contains('Purchase orders - 1 added: PO-1182\r\n'));
    expect(text, contains('  delivery "Projector": Qty 6 -> 8'));
  });
}
