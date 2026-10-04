import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../collab/presence.dart';

/// ============================================================================
///  PROJECT CHAT, KEPT WITH THE PROJECT
/// ============================================================================
///  The job's conversation lives in a folder beside the project file, so it
///  travels with the job and needs no server - only the file share:
///
///      <project folder>/<project>_chat/
///          messages/<login>@<machine>.jsonl   one line per message
///          people/<login>.json                everyone who has opened the job
///          read/<login>.json                  how far each person has read
///
///  Each copy of the app appends to its OWN messages file and reads everybody
///  else's, so no two machines ever write one file - the race a shared folder
///  cannot referee. The folder is polled every few seconds; only the bytes
///  added since the last look are read.
/// ============================================================================

/// How often the chat folder is checked for new messages.
const kChatPoll = Duration(seconds: 4);

/// How often the people folder is re-read.
const kChatPeoplePoll = Duration(seconds: 30);

/// The channel every job has.
const kChatGeneral = 'general';

/// The folder a project's chat is kept in.
String chatFolderFor(String projectPath) {
  var stem = path.basename(projectPath);
  const suffix = '_project.json';
  if (stem.toLowerCase().endsWith(suffix)) {
    stem = stem.substring(0, stem.length - suffix.length);
  } else {
    stem = path.basenameWithoutExtension(stem);
  }
  return path.join(path.dirname(projectPath), '${stem}_chat');
}

/// The @logins named in [text] that belong to [people].
List<String> mentionsIn(String text, Iterable<ChatPerson> people) {
  final logins = {for (final p in people) p.login.toLowerCase(): p.login};
  final out = <String>[];
  for (final m in RegExp(r'@([A-Za-z0-9._-]+)').allMatches(text)) {
    final hit = logins[m.group(1)!.toLowerCase()];
    if (hit != null && !out.contains(hit)) out.add(hit);
  }
  return out;
}

class ChatMessage {
  final String id;
  final String channel;

  /// The Windows login, and the profile name it went under.
  final String user;
  final String name;
  final DateTime at;
  final String text;

  /// Logins this message @mentions.
  final List<String> mentions;

  /// Where the writer was: the room open and the tab on screen.
  final String room;
  final String tab;

  const ChatMessage({
    required this.id,
    required this.channel,
    required this.user,
    required this.name,
    required this.at,
    required this.text,
    this.mentions = const [],
    this.room = '',
    this.tab = '',
  });

  String get who => name.trim().isEmpty ? user : name.trim();

  bool mentionsUser(String login) =>
      mentions.any((m) => m.toLowerCase() == login.toLowerCase());

  Map<String, dynamic> toJson() => {
        'id': id,
        'channel': channel,
        'user': user,
        if (name.isNotEmpty) 'name': name,
        'at': at.toUtc().toIso8601String(),
        'text': text,
        if (mentions.isNotEmpty) 'mentions': mentions,
        if (room.isNotEmpty) 'room': room,
        if (tab.isNotEmpty) 'tab': tab,
      };

  static ChatMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse(json['at']?.toString() ?? '');
    final text = json['text']?.toString() ?? '';
    if (at == null || text.isEmpty) return null;
    return ChatMessage(
      id: json['id']?.toString() ?? '${at.microsecondsSinceEpoch}',
      channel: json['channel']?.toString() ?? kChatGeneral,
      user: json['user']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      at: at.toLocal(),
      text: text,
      mentions: [
        for (final m in (json['mentions'] as List? ?? const [])) '$m',
      ],
      room: json['room']?.toString() ?? '',
      tab: json['tab']?.toString() ?? '',
    );
  }
}

/// Somebody who has opened the job.
class ChatPerson {
  final String login;
  final String name;
  final String email;
  final String machine;
  final DateTime? firstSeen;
  final DateTime? lastSeen;

  const ChatPerson({
    required this.login,
    this.name = '',
    this.email = '',
    this.machine = '',
    this.firstSeen,
    this.lastSeen,
  });

  String get label =>
      name.trim().isEmpty || name.trim().toLowerCase() == login.toLowerCase()
          ? login
          : '${name.trim()} ($login)';

  Map<String, dynamic> toJson() => {
        'login': login,
        if (name.isNotEmpty) 'name': name,
        if (email.isNotEmpty) 'email': email,
        if (machine.isNotEmpty) 'machine': machine,
        if (firstSeen != null) 'firstSeen': firstSeen!.toUtc().toIso8601String(),
        if (lastSeen != null) 'lastSeen': lastSeen!.toUtc().toIso8601String(),
      };

  static ChatPerson? fromJson(Object? json) {
    if (json is! Map) return null;
    final login = json['login']?.toString().trim() ?? '';
    if (login.isEmpty) return null;
    DateTime? time(String k) =>
        DateTime.tryParse(json[k]?.toString() ?? '')?.toLocal();
    return ChatPerson(
      login: login,
      name: json['name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      machine: json['machine']?.toString() ?? '',
      firstSeen: time('firstSeen'),
      lastSeen: time('lastSeen'),
    );
  }
}

/// One conversation in the job: General, a room, or a tab.
class ChatChannel {
  final String id;
  final String label;

  /// 'general', 'room' or 'tab'.
  final String kind;
  final int unread;
  final int mentions;

  const ChatChannel({
    required this.id,
    required this.label,
    required this.kind,
    this.unread = 0,
    this.mentions = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'kind': kind,
        'unread': unread,
        'mentions': mentions,
      };

  static ChatChannel fromJson(Map json) => ChatChannel(
        id: '${json['id']}',
        label: '${json['label']}',
        kind: '${json['kind']}',
        unread: (json['unread'] as num?)?.toInt() ?? 0,
        mentions: (json['mentions'] as num?)?.toInt() ?? 0,
      );
}

/// How the chat is shown.
enum ChatMode {
  slideOut('Slide-out'),
  floating('Floating panel'),
  window('Separate window');

  final String label;
  const ChatMode(this.label);
}

/// Reads and writes one project's chat folder.
class ChatStore {
  final String folder;

  ChatStore(this.folder);

  String get messagesDir => path.join(folder, 'messages');
  String get peopleDir => path.join(folder, 'people');
  String get readDir => path.join(folder, 'read');

  static String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// Bytes read so far, per messages file.
  final Map<String, int> _offsets = {};

  /// Appends [m] to [me]'s own file.
  Future<void> append(CollabIdentity me, ChatMessage m) async {
    await Directory(messagesDir).create(recursive: true);
    final file = File(path.join(messagesDir, '${me.fileStem}.jsonl'));
    await file.writeAsString('${jsonEncode(m.toJson())}\n',
        mode: FileMode.append, flush: true);
  }

  /// Every message added since the last call. The first call reads all.
  Future<List<ChatMessage>> readNew() async {
    final out = <ChatMessage>[];
    final dir = Directory(messagesDir);
    if (!await dir.exists()) return out;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
      try {
        final length = await entity.length();
        var from = _offsets[entity.path] ?? 0;
        if (length < from) from = 0; // rewritten; start over
        if (length == from) continue;
        final raf = await entity.open();
        try {
          await raf.setPosition(from);
          final bytes = await raf.read(length - from);
          // Only whole lines: a line still being written is read next time.
          final end = bytes.lastIndexOf(10);
          if (end < 0) continue;
          final text = utf8.decode(bytes.sublist(0, end), allowMalformed: true);
          for (final line in const LineSplitter().convert(text)) {
            if (line.trim().isEmpty) continue;
            try {
              final m = ChatMessage.fromJson(jsonDecode(line));
              if (m != null) out.add(m);
            } catch (_) {}
          }
          _offsets[entity.path] = from + end + 1;
        } finally {
          await raf.close();
        }
      } catch (_) {
        // Locked or mid-sync; read it next time round.
      }
    }
    return out;
  }

  Future<List<ChatPerson>> readPeople() async {
    final out = <ChatPerson>[];
    final dir = Directory(peopleDir);
    if (!await dir.exists()) return out;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final p = ChatPerson.fromJson(jsonDecode(await entity.readAsString()));
          if (p != null) out.add(p);
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  /// Records that [me] has opened the job, keeping when they first did.
  Future<void> announce(ChatPerson me) async {
    try {
      await Directory(peopleDir).create(recursive: true);
      final file = File(path.join(peopleDir, '${safe(me.login)}.json'));
      DateTime? first;
      if (await file.exists()) {
        try {
          first = ChatPerson.fromJson(jsonDecode(await file.readAsString()))
              ?.firstSeen;
        } catch (_) {}
      }
      final now = DateTime.now();
      final entry = ChatPerson(
        login: me.login,
        name: me.name,
        email: me.email,
        machine: me.machine,
        firstSeen: first ?? now,
        lastSeen: now,
      );
      await _writeJson(file, entry.toJson());
    } catch (_) {
      // A read-only share must not stop anybody working.
    }
  }

  Future<Map<String, DateTime>> readMarks(String login) async {
    try {
      final file = File(path.join(readDir, '${safe(login)}.json'));
      if (!await file.exists()) return {};
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (DateTime.tryParse('${e.value}') != null)
            '${e.key}': DateTime.parse('${e.value}').toLocal(),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> writeMarks(String login, Map<String, DateTime> marks) async {
    try {
      await Directory(readDir).create(recursive: true);
      await _writeJson(File(path.join(readDir, '${safe(login)}.json')), {
        for (final e in marks.entries) e.key: e.value.toUtc().toIso8601String(),
      });
    } catch (_) {}
  }

  static Future<void> _writeJson(File file, Object json) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(file.path);
  }
}

/// What a chat view shows, in a form that crosses a socket.
class ChatSnapshot {
  final String me;
  final bool attached;
  final String project;
  final String folder;
  final List<ChatPerson> people;
  final List<ChatChannel> channels;
  final List<ChatMessage> messages;

  /// The channel to show, and where the person is now (for "this room").
  final String channel;
  final String hereRoomChannel;
  final String hereTabChannel;
  final ChatMode mode;

  const ChatSnapshot({
    required this.me,
    required this.attached,
    required this.project,
    required this.folder,
    required this.people,
    required this.channels,
    required this.messages,
    required this.channel,
    required this.hereRoomChannel,
    required this.hereTabChannel,
    required this.mode,
  });

  Map<String, dynamic> toJson() => {
        'me': me,
        'attached': attached,
        'project': project,
        'folder': folder,
        'people': [for (final p in people) p.toJson()],
        'channels': [for (final c in channels) c.toJson()],
        'messages': [for (final m in messages) m.toJson()],
        'channel': channel,
        'hereRoom': hereRoomChannel,
        'hereTab': hereTabChannel,
        'mode': mode.name,
      };

  static ChatSnapshot fromJson(Map json) => ChatSnapshot(
        me: '${json['me'] ?? ''}',
        attached: json['attached'] == true,
        project: '${json['project'] ?? ''}',
        folder: '${json['folder'] ?? ''}',
        people: [
          for (final p in (json['people'] as List? ?? const []))
            ?ChatPerson.fromJson(p),
        ],
        channels: [
          for (final c in (json['channels'] as List? ?? const []))
            if (c is Map) ChatChannel.fromJson(c),
        ],
        messages: [
          for (final m in (json['messages'] as List? ?? const []))
            ?ChatMessage.fromJson(m),
        ],
        channel: '${json['channel'] ?? kChatGeneral}',
        hereRoomChannel: '${json['hereRoom'] ?? ''}',
        hereTabChannel: '${json['hereTab'] ?? ''}',
        mode: ChatMode.values.firstWhere((m) => m.name == json['mode'],
            orElse: () => ChatMode.slideOut),
      );
}

/// The chat for whichever project is open. Owned by the app state.
class ProjectChat extends ChangeNotifier {
  final CollabIdentity me;

  /// Who [me] is, as the profile has it.
  String Function() myName = () => '';
  String Function() myEmail = () => '';

  /// Where this person is: the open room's id and code, and the tab.
  ({String roomId, String roomLabel, String tabId, String tabLabel})
      Function()? whereAmI;

  /// Every room on the job, as id -> label.
  Map<String, String> Function() rooms = () => const {};

  /// The logins in the job's edit history, so people who edited before the
  /// chat existed can still be @mentioned.
  List<String> Function() historyLogins = () => const [];

  /// Called with each message that arrives from somebody else.
  void Function(ChatMessage message)? onIncoming;

  ProjectChat({CollabIdentity? identity})
      : me = identity ?? CollabIdentity.current();

  ChatStore? _store;
  String _projectPath = '';
  Timer? _timer;
  DateTime _lastPeopleRead = DateTime.fromMillisecondsSinceEpoch(0);
  bool _polling = false;

  final List<ChatMessage> _messages = [];
  final Set<String> _ids = {};
  List<ChatPerson> _people = [];
  Map<String, DateTime> _marks = {};

  /// Whether the chat is on screen, and which channel it shows.
  bool open = false;
  String channel = kChatGeneral;
  ChatMode mode = ChatMode.slideOut;

  bool get attached => _store != null;
  String get projectPath => _projectPath;
  String get folder => _store?.folder ?? '';
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Starts following [projectPath]'s chat, or stops with ''.
  Future<void> attach(String projectPath) async {
    if (projectPath == _projectPath) return;
    _timer?.cancel();
    _timer = null;
    _projectPath = projectPath;
    _messages.clear();
    _ids.clear();
    _people = [];
    _marks = {};
    channel = kChatGeneral;
    if (projectPath.isEmpty) {
      _store = null;
      notifyListeners();
      return;
    }
    final store = ChatStore(chatFolderFor(projectPath));
    _store = store;
    await store.announce(ChatPerson(
      login: me.user,
      name: myName(),
      email: myEmail(),
      machine: me.machine,
    ));
    if (_store != store) return;
    _marks = await store.readMarks(me.user);
    await poll(initial: true);
    _timer = Timer.periodic(kChatPoll, (_) => poll());
  }

  /// Reads whatever has arrived. Never throws.
  Future<void> poll({bool initial = false}) async {
    final store = _store;
    if (store == null || _polling) return;
    _polling = true;
    try {
      final fresh = await store.readNew();
      if (_store != store) return;
      final now = DateTime.now();
      var changed = false;
      if (initial || now.difference(_lastPeopleRead) > kChatPeoplePoll) {
        _lastPeopleRead = now;
        _people = await store.readPeople();
        changed = true;
      }
      final added = <ChatMessage>[];
      for (final m in fresh) {
        if (_ids.add(m.id)) added.add(m);
      }
      if (added.isNotEmpty) {
        _messages
          ..addAll(added)
          ..sort((a, b) => a.at.compareTo(b.at));
        changed = true;
        if (!initial) {
          for (final m in added) {
            if (!_isMine(m)) onIncoming?.call(m);
          }
        }
      }
      if (open && _markRead(channel)) changed = true;
      if (changed) notifyListeners();
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  bool _isMine(ChatMessage m) => m.user.toLowerCase() == me.user.toLowerCase();

  /// Everyone who can be @mentioned: who has opened the job, and who is in its
  /// history. Me included, so the list reads true.
  List<ChatPerson> get people {
    final byLogin = {for (final p in _people) p.login.toLowerCase(): p};
    for (final login in historyLogins()) {
      byLogin.putIfAbsent(login.toLowerCase(), () => ChatPerson(login: login));
    }
    for (final m in _messages) {
      byLogin.putIfAbsent(
          m.user.toLowerCase(), () => ChatPerson(login: m.user, name: m.name));
    }
    byLogin.putIfAbsent(me.user.toLowerCase(),
        () => ChatPerson(login: me.user, name: myName(), machine: me.machine));
    final out = byLogin.values.where((p) => p.login.isNotEmpty).toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return out;
  }

  /// Posts [text] to [channel]. Returns what went wrong, or ''.
  Future<String> post(String text, {String? to}) async {
    final store = _store;
    final body = text.trim();
    if (store == null) return 'Save the project first - its chat is kept beside it.';
    if (body.isEmpty) return '';
    final where = whereAmI?.call();
    final now = DateTime.now();
    final m = ChatMessage(
      id: '${me.fileStem}-${now.microsecondsSinceEpoch}-${Random().nextInt(1 << 20)}',
      channel: to ?? channel,
      user: me.user,
      name: myName(),
      at: now,
      text: body,
      mentions: mentionsIn(body, people),
      room: where?.roomLabel ?? '',
      tab: where?.tabLabel ?? '',
    );
    try {
      await store.append(me, m);
    } catch (e) {
      return 'The message could not be saved to the chat folder: $e';
    }
    if (_ids.add(m.id)) _messages.add(m);
    _markRead(m.channel);
    notifyListeners();
    return '';
  }

  /// Shows [id] and marks it read.
  void selectChannel(String id) {
    channel = id;
    if (open) _markRead(id);
    notifyListeners();
  }

  void setOpen(bool value) {
    open = value;
    if (open) _markRead(channel);
    notifyListeners();
  }

  bool _markRead(String id) {
    final last = _messages.lastWhere(
      (m) => m.channel == id && !_isMine(m),
      orElse: () => ChatMessage(
          id: '', channel: id, user: '', name: '', at: DateTime(0), text: ''),
    );
    if (last.id.isEmpty) return false;
    final mark = _marks[id];
    if (mark != null && !last.at.isAfter(mark)) return false;
    _marks[id] = last.at;
    final store = _store;
    if (store != null) unawaited(store.writeMarks(me.user, Map.of(_marks)));
    return true;
  }

  bool _isUnread(ChatMessage m) {
    if (_isMine(m)) return false;
    final mark = _marks[m.channel];
    return mark == null || m.at.isAfter(mark);
  }

  int get unreadCount => _messages.where(_isUnread).length;

  int get mentionCount =>
      _messages.where((m) => _isUnread(m) && m.mentionsUser(me.user)).length;

  /// General, every room on the job, and every tab that has been talked
  /// about - plus where this person is now.
  List<ChatChannel> get channels {
    final where = whereAmI?.call();
    final roomLabels = {...rooms()};
    if (where != null && where.roomId.isNotEmpty) {
      roomLabels.putIfAbsent(where.roomId, () => where.roomLabel);
    }
    final tabLabels = <String, String>{};
    for (final m in _messages) {
      if (m.channel.startsWith('tab:')) {
        tabLabels.putIfAbsent(m.channel.substring(4), () => m.tab);
      } else if (m.channel.startsWith('room:')) {
        roomLabels.putIfAbsent(m.channel.substring(5), () => m.room);
      }
    }
    if (where != null && where.tabId.isNotEmpty) {
      tabLabels[where.tabId] = where.tabLabel;
    }
    ChatChannel make(String id, String label, String kind) {
      final mine = _messages.where((m) => m.channel == id && _isUnread(m));
      return ChatChannel(
        id: id,
        label: label.isEmpty ? id : label,
        kind: kind,
        unread: mine.length,
        mentions: mine.where((m) => m.mentionsUser(me.user)).length,
      );
    }

    final roomList = roomLabels.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return [
      make(kChatGeneral, 'General', 'general'),
      for (final e in roomList) make('room:${e.key}', e.value, 'room'),
      for (final e in tabLabels.entries) make('tab:${e.key}', e.value, 'tab'),
    ];
  }

  /// Everything a view needs, at most [perChannel] messages per channel.
  ChatSnapshot snapshot({int perChannel = 300}) {
    final where = whereAmI?.call();
    final counts = <String, int>{};
    final kept = <ChatMessage>[];
    for (final m in _messages.reversed) {
      final n = counts[m.channel] = (counts[m.channel] ?? 0) + 1;
      if (n <= perChannel) kept.add(m);
    }
    return ChatSnapshot(
      me: me.user,
      attached: attached,
      project: _projectPath.isEmpty ? '' : path.basename(_projectPath),
      folder: folder,
      people: people,
      channels: channels,
      messages: kept.reversed.toList(),
      channel: channel,
      hereRoomChannel: where == null || where.roomId.isEmpty
          ? ''
          : 'room:${where.roomId}',
      hereTabChannel:
          where == null || where.tabId.isEmpty ? '' : 'tab:${where.tabId}',
      mode: mode,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
