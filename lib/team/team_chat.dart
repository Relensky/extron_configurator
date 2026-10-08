import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'team_fx.dart' show TeamEmojiStore;
import 'team_host.dart';
import 'team_presence.dart';

// ============================================================================
// [TEAM CHAT]: a conversation for everyone using the dashboard, and a thread
// for each room, kept in the team folder - no server, only the share:
//
//     <team folder>/chat/
//         messages/<login>@<machine>.jsonl   one line per message
//         people/<login>.json                everyone who has opened it
//         read/<login>.json                  how far each person has read
//         files/<login>@<machine>-<n>.png    pictures posted (1.23.0)
//
// Ported from the configurator's project chat (lib/chat/project_chat.dart
// there), with the same files and the same rules: each dashboard appends to
// its OWN messages file and reads everybody else's, so no two PCs ever write
// one file; only the bytes added since the last look are read; a message is
// taken back with a deletion line in its author's own file.
//
// 1.23.0 adds, the same way - a line in the author's own file:
//   - an edit:     {"edits": <id>, "editText": "..."} - only the author's
//                  count, the newest wins, and the message says "edited";
//   - a reaction:  {"react": <id>, "emoji": "<emoji>", "on": true|false} -
//                  one person's newest line per emoji wins;
//   - pictures:    "attachments": [{"kind": "image", "file": "files/..."}
//                  or {"kind": "gif", "url": "https://..."}] on a message.
// Edits and reactions carry no "text", so a dashboard older than 1.23.0
// skips them instead of showing them as new messages.
// ============================================================================

const Duration kChatPoll = Duration(seconds: 4);
const Duration kChatPeoplePoll = Duration(seconds: 30);

/// The channel everyone shares - since the team kit, the CTS Dashboard's own
/// conversation (its history from before is all here), shown as
/// "CTS Dashboard". See [kChatAllApps] for the one every app shares.
const String kChatEveryone = 'everyone';

/// [TEAM KIT]: the conversation every CTS app shows first - "All CTS apps".
const String kChatAllApps = 'all';

/// [TEAM KIT]: an app's own conversation: the dashboard's is [kChatEveryone]
/// (its history from before the kit), the others' `app:<id>`.
String appChannel(String appId) =>
    appId.isEmpty || appId == 'dashboard' ? kChatEveryone : 'app:$appId';

/// The app an app channel belongs to, or null for any other channel.
String? appOfChannel(String id) => id == kChatEveryone
    ? 'dashboard'
    : id.startsWith('app:')
        ? id.substring(4)
        : null;

/// The two conversations every app pins at the top of its list: everyone in
/// every app, then this app's own.
List<String> get pinnedChannels => [kChatAllApps, appChannel(TeamHost.appId)];

/// A room's thread.
String roomChannel(String room) => 'room:${room.trim()}';

/// [TEAM CHAT - PROJECTS]: a project's thread, named by the project (so a
/// moved or copied project file keeps it). Every app lists them.
String projectChannel(String project) => 'project:${project.trim()}';

/// One message from an older chat, for [TeamChat.importMessages].
typedef ImportedMessage = ({
  String id,
  String user,
  String name,
  DateTime at,
  String text,
  String room,
});

/// Messages copied in from an older chat (a project's old `<project>_chat`
/// folder) carry ids starting with this. They never count as unread or pop
/// a notice: they are history, not news.
const String kImportedIdPrefix = 'imp-';

/// [TEAM CHAT - 1.23.1]: a thread about anything, named by a hashtag:
/// `#projector-bulbs` -> 'topic:projector-bulbs'. Null when [tag] has no
/// letters or digits.
String? topicChannel(String tag) {
  final t = tag
      .trim()
      .replaceFirst(RegExp(r'^#+'), '')
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '')
      .replaceAll(RegExp(r'-{2,}'), '-');
  return t.isEmpty ? null : 'topic:$t';
}

/// [TEAM CHAT - TOPICS]: a message that STARTS with a hashtag goes to that
/// topic's thread, started if it is new - `#lunch anyone?` posts "anyone?"
/// in #lunch, and `#lunch` alone opens it. Every app sees the thread once it
/// has a message. Returns the thread and the rest of the message, or null
/// when [text] does not start with a hashtag.
(String, String)? topicLead(String text) {
  final m = RegExp(r'^\s*#([A-Za-z][\w-]{1,48})(?:\s+|$)', dotAll: true)
      .firstMatch(text);
  if (m == null) return null;
  final id = topicChannel(m[1]!);
  return id == null ? null : (id, text.substring(m.end).trimRight());
}

/// The two-person conversation between logins [a] and [b] - the same id
/// whoever starts it.
String dmChannel(String a, String b) {
  final pair = [a.trim().toLowerCase(), b.trim().toLowerCase()]..sort();
  return 'dm:${pair.join('+')}';
}

/// A group conversation (its members are in `chat/groups/<id>.json`).
String groupChannel(String id) => 'group:$id';

/// A group chat: a name and the people in it.
class ChatGroup {
  final String id;
  final String name;

  /// Logins, the person who made it included.
  final List<String> members;
  final String createdBy;
  final DateTime? created;

  const ChatGroup({
    required this.id,
    required this.name,
    required this.members,
    this.createdBy = '',
    this.created,
  });

  bool has(String login) =>
      members.any((m) => m.toLowerCase() == login.toLowerCase());

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'members': members,
        if (createdBy.isNotEmpty) 'createdBy': createdBy,
        if (created != null) 'created': created!.toUtc().toIso8601String(),
      };

  static ChatGroup? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    final members = [
      for (final m in (json['members'] is List ? json['members'] as List : const []))
        if ('$m'.trim().isNotEmpty) '$m'.trim()
    ];
    if (id.isEmpty || members.isEmpty) return null;
    return ChatGroup(
      id: id,
      name: (json['name']?.toString() ?? '').trim(),
      members: members,
      createdBy: json['createdBy']?.toString() ?? '',
      created: DateTime.tryParse(json['created']?.toString() ?? '')?.toLocal(),
    );
  }
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

/// A picture on a message: a file posted to the chat folder (a pasted
/// screenshot, an image or GIF from disk), or a GIF from the web.
class ChatAttachment {
  /// 'image' (a file in the chat folder) or 'gif' (a web address).
  final String kind;

  /// For a file: its path inside the chat folder, `files/<name>`.
  final String file;

  /// For a GIF from the web: where it is.
  final String url;

  /// Its size in pixels, when known, so the space is kept while it loads.
  final int width;
  final int height;

  const ChatAttachment({
    required this.kind,
    this.file = '',
    this.url = '',
    this.width = 0,
    this.height = 0,
  });

  bool get isWeb => url.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (file.isNotEmpty) 'file': file,
        if (url.isNotEmpty) 'url': url,
        if (width > 0) 'w': width,
        if (height > 0) 'h': height,
      };

  static ChatAttachment? fromJson(Object? json) {
    if (json is! Map) return null;
    final file = json['file']?.toString() ?? '';
    final url = json['url']?.toString() ?? '';
    // Only the chat's own folder, and only the web: a path elsewhere on the
    // PC, or a "file:" link, is never followed.
    final bool fileOk = file.startsWith('files/') &&
        file.length > 6 &&
        !file.contains('..') &&
        !file.contains(':') &&
        !file.contains('\\');
    final bool urlOk = url.startsWith('https://') || url.startsWith('http://');
    if (!fileOk && !urlOk) return null;
    int size(Object? v) => v is num ? v.toInt() : 0;
    return ChatAttachment(
      kind: json['kind']?.toString() ?? (fileOk ? 'image' : 'gif'),
      file: fileOk ? file : '',
      url: fileOk ? '' : url,
      width: size(json['w']),
      height: size(json['h']),
    );
  }
}

/// Who reacted to a message with one emoji.
class ChatReaction {
  final String emoji;

  /// Logins, in the order they reacted.
  final List<String> users;

  /// Whether this person is one of them.
  final bool mine;

  const ChatReaction(
      {required this.emoji, required this.users, required this.mine});
}

class TeamMessage {
  final String id;
  final String channel;

  /// The Windows login, and the name shown for it.
  final String user;
  final String name;
  final DateTime at;
  final String text;
  final List<String> mentions;

  /// Where the writer was: the room on screen and the tab.
  final String room;
  final String tab;

  /// [TEAM KIT]: the app it was written in ('dashboard', 'configurator',
  /// 'instructor'); '' on a message from before the kit - the dashboard.
  final String app;

  /// The app in words.
  String get appName => teamAppName(app);

  /// Set on a deletion: the id of the message its author took back.
  final String deletes;

  /// Set on an edit: the id of the message its author changed, and the new
  /// words.
  final String edits;
  final String editText;

  /// Set on a reaction: the message, the emoji, and whether it was added
  /// (true) or taken off.
  final String react;
  final String emoji;
  final bool on;

  /// Pictures on the message.
  final List<ChatAttachment> attachments;

  /// When its author last changed it; null when never. Worked out from the
  /// edit lines, not stored with the message.
  final DateTime? editedAt;

  const TeamMessage({
    required this.id,
    required this.channel,
    required this.user,
    required this.name,
    required this.at,
    required this.text,
    this.mentions = const [],
    this.room = '',
    this.tab = '',
    this.app = '',
    this.deletes = '',
    this.edits = '',
    this.editText = '',
    this.react = '',
    this.emoji = '',
    this.on = true,
    this.attachments = const [],
    this.editedAt,
  });

  /// A deletion, an edit or a reaction: a change to another message, not a
  /// message to show.
  bool get isChange =>
      deletes.isNotEmpty || edits.isNotEmpty || react.isNotEmpty;

  /// This message with an edit applied.
  TeamMessage edited(String newText, DateTime when, List<String> newMentions) =>
      TeamMessage(
        id: id,
        channel: channel,
        user: user,
        name: name,
        at: at,
        text: newText,
        mentions: newMentions,
        room: room,
        tab: tab,
        app: app,
        attachments: attachments,
        editedAt: when,
      );

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
        if (app.isNotEmpty) 'app': app,
        if (deletes.isNotEmpty) 'deletes': deletes,
        if (edits.isNotEmpty) 'edits': edits,
        if (edits.isNotEmpty) 'editText': editText,
        if (react.isNotEmpty) 'react': react,
        if (react.isNotEmpty) 'emoji': emoji,
        if (react.isNotEmpty) 'on': on,
        if (attachments.isNotEmpty)
          'attachments': [for (final a in attachments) a.toJson()],
      };

  static TeamMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse(json['at']?.toString() ?? '');
    final text = json['text']?.toString() ?? '';
    final deletes = json['deletes']?.toString() ?? '';
    final edits = json['edits']?.toString() ?? '';
    final react = json['react']?.toString() ?? '';
    final emoji = json['emoji']?.toString() ?? '';
    final attachments = <ChatAttachment>[
      for (final a in (json['attachments'] is List
          ? json['attachments'] as List
          : const []))
        if (ChatAttachment.fromJson(a) case final ChatAttachment ok) ok
    ];
    if (at == null ||
        (text.isEmpty &&
            deletes.isEmpty &&
            edits.isEmpty &&
            (react.isEmpty || emoji.isEmpty) &&
            attachments.isEmpty)) {
      return null;
    }
    return TeamMessage(
      id: json['id']?.toString() ?? '${at.microsecondsSinceEpoch}',
      channel: json['channel']?.toString() ?? kChatEveryone,
      user: json['user']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      at: at.toLocal(),
      text: text,
      mentions: [for (final m in (json['mentions'] as List? ?? const [])) '$m'],
      room: json['room']?.toString() ?? '',
      tab: json['tab']?.toString() ?? '',
      app: json['app']?.toString() ?? '',
      deletes: deletes,
      edits: edits,
      editText: json['editText']?.toString() ?? '',
      react: react,
      emoji: emoji,
      on: json['on'] != false,
      attachments: attachments,
    );
  }
}

/// Somebody who has opened the chat.
class ChatPerson {
  final String login;
  final String name;
  final String machine;
  final DateTime? firstSeen;
  final DateTime? lastSeen;

  const ChatPerson({
    required this.login,
    this.name = '',
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
      machine: json['machine']?.toString() ?? '',
      firstSeen: time('firstSeen'),
      lastSeen: time('lastSeen'),
    );
  }
}

/// One conversation: Everyone, or a room.
class ChatChannel {
  final String id;
  final String label;
  final int unread;
  final int mentions;
  final DateTime? last;

  /// How many messages it holds (filled in by [TeamChat.roomThreads]).
  final int count;

  const ChatChannel({
    required this.id,
    required this.label,
    this.unread = 0,
    this.mentions = 0,
    this.last,
    this.count = 0,
  });

  bool get isRoom => id.startsWith('room:');
  bool get isProject => id.startsWith('project:');
  bool get isTopic => id.startsWith('topic:');
  bool get isDirect => id.startsWith('dm:');
  bool get isGroup => id.startsWith('group:');

  /// A conversation with chosen people (a direct message or a group).
  bool get isPrivate => isDirect || isGroup;
}

/// Reads and writes the chat folder.
class ChatStore {
  final String folder;
  ChatStore(this.folder);

  static final String _sep = Platform.pathSeparator;
  String get messagesDir => '$folder${_sep}messages';
  String get peopleDir => '$folder${_sep}people';
  String get readDir => '$folder${_sep}read';
  String get filesDir => '$folder${_sep}files';
  String get groupsDir => '$folder${_sep}groups';

  Future<List<ChatGroup>> readGroups() async {
    final out = <ChatGroup>[];
    final dir = Directory(groupsDir);
    if (!await dir.exists()) return out;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final g = ChatGroup.fromJson(jsonDecode(await entity.readAsString()));
          if (g != null) out.add(g);
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  Future<void> writeGroup(ChatGroup g) async {
    await Directory(groupsDir).create(recursive: true);
    await _writeJson(File('$groupsDir$_sep${safe(g.id)}.json'), g.toJson());
  }

  /// Where an attachment's file is on the share.
  String pathOf(ChatAttachment a) =>
      '$folder$_sep${a.file.replaceAll('/', _sep)}';

  /// Saves a picture to the chat folder; returns its `files/...` path.
  Future<String> saveFile(TeamIdentity me, List<int> bytes, String ext) async {
    await Directory(filesDir).create(recursive: true);
    final clean = ext.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final name = '${me.fileStem}-${DateTime.now().microsecondsSinceEpoch}'
        '.${clean.isEmpty ? 'png' : clean}';
    final tmp = File('$filesDir$_sep$name.$pid.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename('$filesDir$_sep$name');
    return 'files/$name';
  }

  static String safe(String s) => TeamIdentity.safeName(s);

  final Map<String, int> _offsets = {};

  Future<void> append(TeamIdentity me, TeamMessage m) async {
    await Directory(messagesDir).create(recursive: true);
    final file = File('$messagesDir$_sep${me.fileStem}.jsonl');
    await file.writeAsString('${jsonEncode(m.toJson())}\n',
        mode: FileMode.append, flush: true);
  }

  /// Every message added since the last call. The first call reads all.
  Future<List<TeamMessage>> readNew() async {
    final out = <TeamMessage>[];
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
          final text =
              utf8.decode(bytes.sublist(0, end), allowMalformed: true);
          for (final line in const LineSplitter().convert(text)) {
            if (line.trim().isEmpty) continue;
            try {
              final m = TeamMessage.fromJson(jsonDecode(line));
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
          final p =
              ChatPerson.fromJson(jsonDecode(await entity.readAsString()));
          if (p != null) out.add(p);
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  /// Records that [me] has opened the chat, keeping when they first did.
  Future<void> announce(ChatPerson me) async {
    try {
      await Directory(peopleDir).create(recursive: true);
      final file = File('$peopleDir$_sep${safe(me.login)}.json');
      DateTime? first;
      if (await file.exists()) {
        try {
          first = ChatPerson.fromJson(jsonDecode(await file.readAsString()))
              ?.firstSeen;
        } catch (_) {}
      }
      final now = DateTime.now();
      await _writeJson(
          file,
          ChatPerson(
            login: me.login,
            name: me.name,
            machine: me.machine,
            firstSeen: first ?? now,
            lastSeen: now,
          ).toJson());
    } catch (_) {}
  }

  Future<Map<String, DateTime>> readMarks(String login) async {
    try {
      final file = File('$readDir$_sep${safe(login)}.json');
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
      await _writeJson(File('$readDir$_sep${safe(login)}.json'), {
        for (final e in marks.entries) e.key: e.value.toUtc().toIso8601String(),
      });
    } catch (_) {}
  }

  static Future<void> _writeJson(File file, Object json) async {
    final tmp = File('${file.path}.$pid.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(file.path);
  }
}

/// The team chat. Owned by the dashboard's main window.
class TeamChat extends ChangeNotifier {
  TeamChat({TeamIdentity? identity}) : me = identity ?? TeamIdentity.current();

  final TeamIdentity me;

  /// The name shown with this person's messages (their GVE login, say).
  String Function() myName = () => '';

  /// Where this person is now: the room on screen and the tab.
  ({String room, String tab}) Function()? whereAmI;

  /// Called with each message that arrives from somebody else.
  void Function(TeamMessage message)? onIncoming;

  ChatStore? _store;
  String _folder = '';
  Timer? _timer;

  /// [TEAM CHAT]: a new line in anyone's messages file is read at once; the
  /// 4 s poll stays for shares that cannot be watched. Off in tests.
  bool watch = !Platform.environment.containsKey('FLUTTER_TEST');
  StreamSubscription<FileSystemEvent>? _watcher;
  Timer? _settle;
  bool _firstRead = true;
  bool _polling = false;
  DateTime _lastPeopleRead = DateTime.fromMillisecondsSinceEpoch(0);

  final List<TeamMessage> _messages = [];
  final Set<String> _ids = {};
  final Set<String> _deleted = {};

  /// Group chats, by id (all of them; [canSee] keeps others' private).
  final Map<String, ChatGroup> _groups = {};

  /// The newest edit of each message, by [_deleteKey] (author and id).
  final Map<String, TeamMessage> _edits = {};

  /// Reactions: message id -> emoji -> login (lower case) -> that person's
  /// newest line for it.
  final Map<String, Map<String, Map<String, TeamMessage>>> _reactions = {};
  List<ChatPerson> _people = [];
  final Map<String, DateTime> _marks = {};

  /// Whether the chat is on screen, and which channel it shows.
  bool _open = false;
  /// Opens on this app's own conversation.
  String channel = appChannel(TeamHost.appId);

  bool get attached => _store != null;
  bool get isOpen => _open;
  String get folder => _folder;
  List<TeamMessage> get messages => List.unmodifiable(_messages);

  static String _deleteKey(String user, String id) =>
      '${user.toLowerCase()}|$id';

  /// Follows [teamFolder]'s chat, or stops with ''.
  Future<void> attach(String teamFolder) async {
    final f = teamFolder.isEmpty
        ? ''
        : '$teamFolder${Platform.pathSeparator}chat';
    if (f == _folder) return;
    _folder = f;
    // The whole set of animated emoji is kept beside the chat.
    TeamEmojiStore.sharedFolder =
        teamFolder.isEmpty ? '' : '$teamFolder${Platform.pathSeparator}emoji';
    _messages.clear();
    _ids.clear();
    _deleted.clear();
    _edits.clear();
    _reactions.clear();
    _groups.clear();
    _marks.clear();
    _people = [];
    _firstRead = true;
    _timer?.cancel();
    _timer = null;
    _stopWatching();
    if (f.isEmpty) {
      _store = null;
      notifyListeners();
      return;
    }
    final store = ChatStore(f);
    _store = store;
    _timer = Timer.periodic(kChatPoll, (_) => poll());
    await store.announce(ChatPerson(
        login: me.user, name: myName(), machine: me.machine));
    if (_store != store) return;
    _marks.addAll(await store.readMarks(me.user));
    notifyListeners();
    await poll();
  }

  /// Reads what has arrived. Never throws.
  Future<void> poll() async {
    final store = _store;
    if (store == null || _polling) return;
    _startWatching(store);
    _polling = true;
    try {
      final first = _firstRead;
      final fresh = await store.readNew();
      if (_store != store) return;
      _firstRead = false;
      var changed = false;
      final now = DateTime.now();
      if (first || now.difference(_lastPeopleRead) > kChatPeoplePoll) {
        _lastPeopleRead = now;
        _people = await store.readPeople();
        await _readGroups(store);
        // Read marks another window of this person's moved (the chat in its
        // own window), so the counts here keep up with it.
        final marks = await store.readMarks(me.user);
        marks.forEach((k, v) {
          final mine = _marks[k];
          if (mine == null || v.isAfter(mine)) _marks[k] = v;
        });
        changed = true;
      }
      if (fresh.any((m) =>
          m.channel.startsWith('group:') &&
          !_groups.containsKey(m.channel.substring(6)))) {
        await _readGroups(store);
        changed = true;
      }
      for (final m in fresh) {
        if (m.deletes.isNotEmpty) _deleted.add(_deleteKey(m.user, m.deletes));
        if (m.edits.isNotEmpty && _takeEdit(m)) changed = true;
        if (m.react.isNotEmpty && _takeReaction(m)) changed = true;
      }
      final before = _messages.length;
      _messages.removeWhere((x) => _deleted.contains(_deleteKey(x.user, x.id)));
      if (_messages.length != before) changed = true;
      final added = <TeamMessage>[];
      for (final m in fresh) {
        if (m.isChange) continue;
        if (_deleted.contains(_deleteKey(m.user, m.id))) continue;
        if (_ids.add(m.id)) added.add(_withEdit(m));
      }
      if (added.isNotEmpty) {
        _messages
          ..addAll(added)
          ..sort((a, b) => a.at.compareTo(b.at));
        changed = true;
        if (!first) {
          for (final m in added) {
            if (!_isMine(m) &&
                canSee(m.channel) &&
                !m.id.startsWith(kImportedIdPrefix)) {
              onIncoming?.call(m);
            }
          }
        }
      }
      if (_open && _markRead(channel)) changed = true;
      if (changed) notifyListeners();
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  bool _isMine(TeamMessage m) => m.user.toLowerCase() == me.user.toLowerCase();

  /// Everyone who can be @mentioned, me included.
  List<ChatPerson> get people {
    final byLogin = {for (final p in _people) p.login.toLowerCase(): p};
    for (final m in _messages) {
      byLogin.putIfAbsent(
          m.user.toLowerCase(), () => ChatPerson(login: m.user, name: m.name));
    }
    byLogin.putIfAbsent(me.user.toLowerCase(),
        () => ChatPerson(login: me.user, name: myName(), machine: me.machine));
    return byLogin.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  }

  // --- edits and reactions ---------------------------------------------------

  /// Records [e] if it is the newest edit of its message; applies it to a
  /// message already here. True when something on screen changed.
  bool _takeEdit(TeamMessage e) {
    final key = _deleteKey(e.user, e.edits);
    final had = _edits[key];
    if (had != null && !e.at.isAfter(had.at)) return false;
    _edits[key] = e;
    final i = _messages.indexWhere(
        (m) => m.id == e.edits && m.user.toLowerCase() == e.user.toLowerCase());
    if (i < 0) return false;
    _messages[i] = _withEdit(_messages[i]);
    return true;
  }

  /// [m] with its author's newest edit, if any.
  TeamMessage _withEdit(TeamMessage m) {
    final e = _edits[_deleteKey(m.user, m.id)];
    if (e == null) return m;
    return m.edited(e.editText, e.at,
        e.editText.contains('@') ? mentionsIn(e.editText, people) : const []);
  }

  bool _takeReaction(TeamMessage r) {
    final byEmoji = _reactions.putIfAbsent(r.react, () => {});
    final byUser = byEmoji.putIfAbsent(r.emoji, () => {});
    final key = r.user.toLowerCase();
    final had = byUser[key];
    if (had != null && !r.at.isAfter(had.at)) return false;
    byUser[key] = r;
    return true;
  }

  /// The reactions on message [id]: each emoji someone has on it now, in the
  /// order they were first added.
  List<ChatReaction> reactionsOf(String id) {
    final byEmoji = _reactions[id];
    if (byEmoji == null) return const [];
    final out = <(DateTime, ChatReaction)>[];
    byEmoji.forEach((emoji, byUser) {
      final on = byUser.values.where((r) => r.on).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (on.isEmpty) return;
      out.add((
        on.first.at,
        ChatReaction(
          emoji: emoji,
          users: [for (final r in on) r.user],
          mine: on.any(_isMine),
        )
      ));
    });
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final x in out) x.$2];
  }

  /// The name to show for [login]: who they said they are, else the login.
  String nameOf(String login) {
    for (final p in people) {
      if (p.login.toLowerCase() == login.toLowerCase()) {
        return p.name.trim().isEmpty ? p.login : p.name.trim();
      }
    }
    return login;
  }

  /// Adds this person's [emoji] to message [id], or takes it off again.
  Future<String> toggleReaction(String id, String emoji) async {
    final store = _store;
    if (store == null) return 'The team folder cannot be reached.';
    final i = _messages.indexWhere((m) => m.id == id);
    if (i < 0) return '';
    final mine = _reactions[id]?[emoji]?[me.user.toLowerCase()];
    final now = DateTime.now();
    final line = TeamMessage(
      id: '${me.fileStem}-${now.microsecondsSinceEpoch}-r',
      channel: _messages[i].channel,
      user: me.user,
      name: myName(),
      at: now,
      text: '',
      react: id,
      emoji: emoji,
      on: !(mine?.on ?? false),
    );
    try {
      await store.append(me, line);
    } catch (e) {
      return 'The reaction could not be saved: $e';
    }
    _takeReaction(line);
    notifyListeners();
    return '';
  }

  /// Changes the words of one of this person's own messages. Returns what
  /// went wrong, or ''.
  Future<String> editMessage(String id, String text) async {
    final i = _messages.indexWhere((m) => m.id == id);
    if (i < 0) return '';
    final m = _messages[i];
    if (!_isMine(m)) return 'Only the person who wrote a message can edit it.';
    final body = text.trim();
    if (body == m.text) return '';
    if (body.isEmpty && m.attachments.isEmpty) {
      return 'A message needs some words. Delete it instead.';
    }
    final store = _store;
    if (store == null) return 'The team folder cannot be reached.';
    final now = DateTime.now();
    final line = TeamMessage(
      id: '${me.fileStem}-${now.microsecondsSinceEpoch}-e',
      channel: m.channel,
      user: me.user,
      name: myName(),
      at: now,
      text: '',
      edits: id,
      editText: body,
    );
    try {
      await store.append(me, line);
    } catch (e) {
      return 'The change could not be saved: $e';
    }
    _takeEdit(line);
    notifyListeners();
    return '';
  }

  // --- pictures ---------------------------------------------------------------

  /// Copies a picture into the chat folder, ready to post with a message.
  /// Throws when the folder cannot be reached or written.
  Future<ChatAttachment> savePicture(List<int> bytes, String ext,
      {int width = 0, int height = 0}) async {
    final store = _store;
    if (store == null) throw StateError('The team folder cannot be reached.');
    final file = await store.saveFile(me, bytes, ext);
    return ChatAttachment(
        kind: 'image', file: file, width: width, height: height);
  }

  /// Where an attached file is, or '' for a web GIF.
  String pathOf(ChatAttachment a) =>
      a.file.isEmpty || _store == null ? '' : _store!.pathOf(a);

  /// Posts [text] to [to] (the shown channel when null), with any
  /// [attachments]. Returns what went wrong, or ''.
  Future<String> post(String text,
      {String? to, List<ChatAttachment> attachments = const []}) async {
    final store = _store;
    final body = text.trim();
    if (store == null) return 'The team folder cannot be reached.';
    if (body.isEmpty && attachments.isEmpty) return '';
    if (body.contains('@')) {
      try {
        _people = await store.readPeople();
      } catch (_) {}
    }
    final where = whereAmI?.call();
    final now = DateTime.now();
    final m = TeamMessage(
      id: '${me.fileStem}-${now.microsecondsSinceEpoch}-${Random().nextInt(1 << 20)}',
      channel: to ?? channel,
      user: me.user,
      name: myName(),
      at: now,
      text: body,
      mentions: mentionsIn(body, people),
      room: where?.room ?? '',
      tab: where?.tab ?? '',
      app: TeamHost.appId,
      attachments: attachments,
    );
    try {
      await store.append(me, m);
    } catch (e) {
      return 'The message could not be saved to the team folder: $e';
    }
    if (_ids.add(m.id)) _messages.add(m);
    _markRead(m.channel);
    notifyListeners();
    return '';
  }

  /// [TEAM CHAT - PROJECTS]: copies messages from an older chat into
  /// [channel], under their own writers and times. Each keeps a stable id
  /// ([kImportedIdPrefix] + [ImportedMessage.id]), so running it again - or
  /// on two PCs at once - adds nothing twice. Returns how many were new.
  Future<int> importMessages(
      String channel, Iterable<ImportedMessage> items) async {
    final store = _store;
    // Not before the folder's first read: the ids it holds are how a
    // message already copied in is recognised.
    if (store == null || _firstRead) return 0;
    var added = 0;
    for (final it in items) {
      final id = '$kImportedIdPrefix${it.id}';
      if (_ids.contains(id) || it.text.trim().isEmpty) continue;
      final m = TeamMessage(
        id: id,
        channel: channel,
        user: it.user,
        name: it.name,
        at: it.at,
        text: it.text,
        mentions: const [],
        room: it.room,
        app: TeamHost.appId,
      );
      await store.append(me, m);
      if (_ids.add(m.id)) _messages.add(m);
      added++;
    }
    if (added > 0) {
      _messages.sort((a, b) => a.at.compareTo(b.at));
      notifyListeners();
    }
    return added;
  }

  /// Takes back one of this person's own messages.
  Future<String> deleteMessage(String id) async {
    final i = _messages.indexWhere((m) => m.id == id);
    if (i < 0) return '';
    final m = _messages[i];
    if (!_isMine(m)) return 'Only the person who wrote a message can delete it.';
    final store = _store;
    if (store == null) return 'The team folder cannot be reached.';
    final now = DateTime.now();
    try {
      await store.append(
          me,
          TeamMessage(
            id: '${me.fileStem}-${now.microsecondsSinceEpoch}-d',
            channel: m.channel,
            user: me.user,
            name: myName(),
            at: now,
            text: '',
            deletes: id,
          ));
    } catch (e) {
      return 'The message could not be deleted: $e';
    }
    _deleted.add(_deleteKey(me.user, id));
    _messages.removeAt(i);
    notifyListeners();
    return '';
  }

  /// Shows [id]. [reopen]: a thread this person closed comes back into their
  /// list (opened from a search, say).
  void selectChannel(String id, {bool reopen = false}) {
    if (reopen && _marks.remove('$_closedPrefix$id') != null) {
      final store = _store;
      if (store != null) unawaited(store.writeMarks(me.user, Map.of(_marks)));
    }
    channel = id;
    if (_open) _markRead(id);
    notifyListeners();
  }

  void setOpen(bool value) {
    _open = value;
    if (_open) _markRead(channel);
    notifyListeners();
  }

  bool _markRead(String id) {
    TeamMessage? last;
    for (final m in _messages.reversed) {
      if (m.channel == id && !_isMine(m)) {
        last = m;
        break;
      }
    }
    if (last == null) return false;
    final mark = _marks[id];
    if (mark != null && !last.at.isAfter(mark)) return false;
    _marks[id] = last.at;
    final store = _store;
    if (store != null) {
      unawaited(store.writeMarks(me.user, Map.of(_marks)));
    }
    return true;
  }

  // --- who sees what -----------------------------------------------------------

  Future<void> _readGroups(ChatStore store) async {
    final groups = await store.readGroups();
    for (final g in groups) {
      _groups[g.id] = g;
    }
  }

  /// Whether this person is in [id]: everything but other people's direct
  /// messages and groups. (The share itself is readable by the team - a
  /// filter for the screen, not a lock.)
  bool canSee(String id) {
    if (id.startsWith('dm:')) {
      return id.substring(3).split('+').contains(me.user.toLowerCase());
    }
    if (id.startsWith('group:')) {
      return _groups[id.substring(6)]?.has(me.user) ?? false;
    }
    return true;
  }

  /// The group behind [id], if it is one.
  ChatGroup? groupOf(String id) =>
      id.startsWith('group:') ? _groups[id.substring(6)] : null;

  /// The other person in a direct message.
  String otherIn(String dmId) {
    final logins = dmId.substring(3).split('+');
    return logins.firstWhere((l) => l != me.user.toLowerCase(),
        orElse: () => logins.first);
  }

  /// What [id] is called on screen: Everyone, a room, #tag, a person, or a
  /// group's name.
  String labelOf(String id) {
    if (id == kChatAllApps) return 'All CTS apps';
    final app = appOfChannel(id);
    if (app != null) return teamAppName(app);
    if (id.startsWith('room:')) return id.substring(5);
    if (id.startsWith('project:')) return id.substring(8);
    if (id.startsWith('topic:')) return '#${id.substring(6)}';
    if (id.startsWith('dm:')) return nameOf(otherIn(id));
    final g = groupOf(id);
    if (g != null) {
      if (g.name.isNotEmpty) return g.name;
      return [
        for (final m in g.members)
          if (m.toLowerCase() != me.user.toLowerCase()) nameOf(m)
      ].join(', ');
    }
    return id.contains(':') ? id.substring(id.indexOf(':') + 1) : id;
  }

  /// Opens the direct conversation with [login].
  void openDirect(String login) =>
      selectChannel(dmChannel(me.user, login), reopen: true);

  /// Makes a group chat of [members] (this person is added) called [name],
  /// and opens it. Returns what went wrong, or ''.
  Future<String> createGroup(String name, List<String> members) async {
    final store = _store;
    if (store == null) return 'The team folder cannot be reached.';
    final people = <String>{me.user.toLowerCase()};
    final list = <String>[me.user];
    for (final m in members) {
      if (people.add(m.trim().toLowerCase())) list.add(m.trim());
    }
    if (list.length < 2) return 'Pick at least one other person.';
    final now = DateTime.now();
    final g = ChatGroup(
      id: '${me.fileStem}-${now.microsecondsSinceEpoch}',
      name: name.trim(),
      members: list,
      createdBy: me.user,
      created: now,
    );
    try {
      await store.writeGroup(g);
    } catch (e) {
      return 'The group could not be saved to the team folder: $e';
    }
    _groups[g.id] = g;
    selectChannel(groupChannel(g.id));
    return '';
  }

  bool _isUnread(TeamMessage m) {
    if (_isMine(m) || !canSee(m.channel)) return false;
    if (m.id.startsWith(kImportedIdPrefix)) return false;
    final mark = _marks[m.channel];
    return mark == null || m.at.isAfter(mark);
  }

  int get unreadCount => _messages.where(_isUnread).length;

  /// Unread messages meant for this person: an @mention, or anything in
  /// their direct messages and groups.
  int get mentionCount => _messages.where((m) => _isUnread(m) && isForMe(m)).length;

  bool isForMe(TeamMessage m) =>
      m.mentionsUser(me.user) ||
      ((m.channel.startsWith('dm:') || m.channel.startsWith('group:')) &&
          canSee(m.channel));

  /// Unread messages in [room]'s thread.
  int unreadInRoom(String room) {
    final id = roomChannel(room);
    return _messages.where((m) => m.channel == id && _isUnread(m)).length;
  }

  /// Messages in [room]'s thread.
  int countInRoom(String room) {
    final id = roomChannel(room);
    return _messages.where((m) => m.channel == id).length;
  }

  /// Everyone, then every topic, room thread, direct message and group this
  /// person is in - newest conversation first in each. The room on screen
  /// is not added by itself (1.23.0): the chat offers a button to go to its
  /// thread, or start one.
  List<ChatChannel> get channels {
    final last = <String, DateTime>{};
    final unread = <String, int>{};
    final mentions = <String, int>{};
    for (final m in _messages) {
      if (!canSee(m.channel)) continue;
      last[m.channel] = m.at;
      if (_isUnread(m)) {
        unread[m.channel] = (unread[m.channel] ?? 0) + 1;
        if (m.mentionsUser(me.user) || m.channel.startsWith('dm:') ||
            m.channel.startsWith('group:')) {
          mentions[m.channel] = (mentions[m.channel] ?? 0) + 1;
        }
      }
    }
    ChatChannel make(String id) => ChatChannel(
          id: id,
          label: labelOf(id),
          unread: unread[id] ?? 0,
          mentions: mentions[id] ?? 0,
          last: last[id],
        );
    final pinned = pinnedChannels;
    final ids = {
      ...last.keys.where((id) => !pinned.contains(id)),
      if (!pinned.contains(channel) && canSee(channel)) channel,
      // A group someone added this person to shows before anyone writes.
      for (final g in _groups.values)
        if (g.has(me.user)) groupChannel(g.id),
    }.where((id) => id == channel || !isClosed(id, last[id])).toList()
      ..sort((a, b) {
        final la = last[a], lb = last[b];
        if (la == null && lb == null) return a.compareTo(b);
        if (la == null) return 1;
        if (lb == null) return -1;
        return lb.compareTo(la);
      });
    return [for (final id in pinned) make(id), for (final id in ids) make(id)];
  }

  // --- closing and clearing -------------------------------------------------

  /// Closed threads are kept with the read marks ('closed:room:ARTS 209' ->
  /// when), so the choice follows the person to any PC.
  static const String _closedPrefix = 'closed:';

  /// Whether [id] was closed and nobody has written in it since.
  bool isClosed(String id, [DateTime? lastMessage]) {
    final closed = _marks['$_closedPrefix$id'];
    if (closed == null) return false;
    lastMessage ??= _lastIn(id);
    return lastMessage == null || !lastMessage.isAfter(closed);
  }

  DateTime? _lastIn(String id) {
    for (final m in _messages.reversed) {
      if (m.channel == id) return m.at;
    }
    return null;
  }

  /// Takes a thread out of this person's list until someone writes in it
  /// again. Everyone stays a channel that cannot be closed.
  void closeChannel(String id) {
    if (pinnedChannels.contains(id)) return;
    _markRead(id);
    _marks['$_closedPrefix$id'] = DateTime.now();
    final store = _store;
    if (store != null) unawaited(store.writeMarks(me.user, Map.of(_marks)));
    if (channel == id) channel = appChannel(TeamHost.appId);
    notifyListeners();
  }

  /// How many of this person's own messages are in [id].
  int myMessageCount(String id) =>
      _messages.where((m) => m.channel == id && _isMine(m)).length;

  /// Takes back every one of this person's messages in [id], for everyone.
  /// Returns what went wrong, or ''.
  Future<String> deleteMyMessagesIn(String id) async {
    final mine = [
      for (final m in _messages)
        if (m.channel == id && _isMine(m)) m.id
    ];
    for (final messageId in mine) {
      final problem = await deleteMessage(messageId);
      if (problem.isNotEmpty) return problem;
    }
    return '';
  }

  /// Every room thread with messages in it - closed ones too - whose room
  /// matches [query] (space-agnostic), newest first. All of them for ''.
  List<ChatChannel> roomThreads({String query = ''}) =>
      threads(query: query, topics: false, projects: false);

  /// [TEAM CHAT - PROJECTS]: every project thread with messages in it,
  /// closed ones too, newest first - the chat's Projects list, in every app.
  List<ChatChannel> projectThreads({String query = ''}) =>
      threads(query: query, rooms: false, topics: false);

  /// Room threads and #topics with messages in them, closed ones too, whose
  /// name matches [query] (space-agnostic, a leading # ignored).
  List<ChatChannel> threads(
      {String query = '',
      bool topics = true,
      bool rooms = true,
      bool projects = true}) {
    final q = query.replaceAll(' ', '').replaceFirst(RegExp(r'^#+'), '').toLowerCase();
    final last = <String, DateTime>{};
    final count = <String, int>{};
    final unread = <String, int>{};
    for (final m in _messages) {
      if (!(rooms && m.channel.startsWith('room:')) &&
          !(projects && m.channel.startsWith('project:')) &&
          !(topics && m.channel.startsWith('topic:'))) {
        continue;
      }
      last[m.channel] = m.at;
      count[m.channel] = (count[m.channel] ?? 0) + 1;
      if (_isUnread(m)) unread[m.channel] = (unread[m.channel] ?? 0) + 1;
    }
    final ids = last.keys
        .where((id) => id
            .substring(id.indexOf(':') + 1)
            .replaceAll(' ', '')
            .toLowerCase()
            .contains(q))
        .toList()
      ..sort((a, b) => last[b]!.compareTo(last[a]!));
    return [
      for (final id in ids)
        ChatChannel(
          id: id,
          label: labelOf(id),
          unread: unread[id] ?? 0,
          count: count[id] ?? 0,
          last: last[id],
        )
    ];
  }

  /// How many messages [id] holds.
  int countIn(String id) => _messages.where((m) => m.channel == id).length;

  /// Messages in [id], or every channel's matching [query] (space-agnostic).
  List<TeamMessage> shown({String? id, String query = ''}) {
    final q = query.replaceAll(' ', '').toLowerCase();
    return [
      for (final m in _messages)
        if (canSee(m.channel) &&
            (q.isNotEmpty || m.channel == (id ?? channel)) &&
            (q.isEmpty ||
                '${m.text}${m.who}${m.room}'
                    .replaceAll(' ', '')
                    .toLowerCase()
                    .contains(q)))
          m
    ];
  }

  void _startWatching(ChatStore store) {
    if (!watch || _watcher != null) return;
    try {
      final dir = Directory(store.messagesDir);
      if (!dir.existsSync()) return;
      _watcher = dir.watch().listen((_) {
        _settle?.cancel();
        _settle = Timer(const Duration(milliseconds: 250), () {
          unawaited(poll());
        });
      }, onError: (_) => _stopWatching(), onDone: _stopWatching,
          cancelOnError: true);
    } catch (_) {
      _watcher = null;
    }
  }

  void _stopWatching() {
    _settle?.cancel();
    _settle = null;
    final w = _watcher;
    _watcher = null;
    if (w != null) unawaited(w.cancel());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopWatching();
    super.dispose();
  }
}
