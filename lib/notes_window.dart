import 'dart:async';
import 'form_factor.dart' show isMobileDevice;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'export_tools.dart' show roomFolderName;
import 'team/team_floating_panel.dart';

/// ============================================================================
///  THE NOTES WINDOW
/// ============================================================================
///  Ctrl+N: a notes panel that floats over the app and can be dragged
///  anywhere in it, writing straight into the open room's cost notes - or
///  the project's notes on the Project tab. Its pop-out button moves it into
///  a window of its own, which stays in step with the app both ways and can
///  be docked back.
///
///  THE WINDOW IS A SECOND COPY OF THE APP, as the CTS Dashboard's terminal
///  and network windows are: started with [kNotesPopoutFlag], talking back to
///  this one over a loopback socket, one JSON line per message. A
///  multi-window plugin breaks the main window's input on Windows; a second
///  process does not. The copy exits when the socket closes.
/// ============================================================================

/// Starts a copy of the app as the notes window: `--notes-popout <json>`.
const String kNotesPopoutFlag = '--notes-popout';

/// Whose notes the window writes to.
enum NotesTargetKind { room, project }

/// The notes the window is on right now: whose, what it is called, and its
/// text.
typedef NotesTarget = ({NotesTargetKind kind, String key, String title});

/// The room's cost notes when a room is open and the Project tab is not in
/// front; the project's notes on the Project tab, or when only a job is
/// open. Null with neither.
NotesTarget? notesTargetOf(AppStateProvider p) {
  final onProject = p.selectedTabIndex == AppTab.project.index;
  final room = p.roomConfig.isNotEmpty;
  if (p.hasOpenProject && (onProject || !room)) {
    return (
      kind: NotesTargetKind.project,
      key: 'project:${p.currentProjectPath}',
      title: 'Project notes - ${p.projectDisplayName}',
    );
  }
  if (!room) return null;
  return (
    kind: NotesTargetKind.room,
    key: 'room:${p.currentConfigPath}',
    title: 'Room notes - ${roomFolderName(p)}',
  );
}

String notesTextOf(AppStateProvider p, NotesTarget t) =>
    t.kind == NotesTargetKind.room ? p.avCost.notes : p.project.notes;

void writeNotes(AppStateProvider p, NotesTarget t, String text) {
  if (notesTextOf(p, t) == text) return;
  if (t.kind == NotesTargetKind.room) {
    p.setAvCostNotes(text);
  } else {
    p.setProjectField(notes: text);
  }
}

// ---------------------------------------------------------------------------
//  THE PANEL, INSIDE THE APP
// ---------------------------------------------------------------------------

/// The floating panel: one at a time, over the whole app.
abstract final class NotesPanel {
  static OverlayEntry? _entry;

  static bool get isOpen => _entry != null;

  /// Opens the panel, or closes it if it is open. With the window popped out
  /// it brings that to the front instead.
  static void toggle(BuildContext context) {
    if (NotesHost.instance.poppedOut) {
      NotesHost.instance.focusWindow();
      return;
    }
    if (_entry != null) {
      close();
    } else {
      open(context);
    }
  }

  static void open(BuildContext context) {
    if (_entry != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final provider = context.read<AppStateProvider>();
    final entry = OverlayEntry(
      builder: (_) => ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const _NotesPanelHost(),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void close() {
    _entry?.remove();
    _entry = null;
  }
}

class _NotesPanelHost extends StatelessWidget {
  const _NotesPanelHost();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final target = notesTargetOf(provider);
    return Stack(
      children: [
        TeamFloatingPanelFrame(
          key: const ValueKey('notes_panel'),
          geometryKey: 'notes_panel',
          title: target?.title ?? 'Notes',
          initialSize: const Size(520, 420),
          minSize: const Size(320, 220),
          liveResize: true,
          onClose: NotesPanel.close,
          titleBarActions: [
            // iPad / iPhone: no second copy of the app to pop out into - the
            // panel is the notes window there.
            if (target != null && !isMobileDevice)
              IconButton(
                key: const ValueKey('notes_pop_out'),
                tooltip: 'Pop out into its own window',
                icon: const Icon(Icons.open_in_new, size: 18),
                onPressed: () {
                  final dark = Theme.of(context).brightness == Brightness.dark;
                  NotesPanel.close();
                  NotesHost.instance.popOut(provider, dark: dark);
                },
              ),
          ],
          child: target == null
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Open a room or a project to take notes.'),
                )
              : NotesEditor(
                  key: ValueKey('notes_editor_${target.key}'),
                  text: notesTextOf(provider, target),
                  onChanged: (v) => writeNotes(provider, target, v),
                ),
        ),
      ],
    );
  }
}

/// The text box both containers use. [text] is taken in when it changes from
/// outside, except while the person is typing in it.
class NotesEditor extends StatefulWidget {
  const NotesEditor({
    super.key,
    required this.text,
    required this.onChanged,
  });

  final String text;
  final ValueChanged<String> onChanged;

  @override
  State<NotesEditor> createState() => _NotesEditorState();
}

class _NotesEditorState extends State<NotesEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.text);
  final FocusNode _focus = FocusNode();
  DateTime _typedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void didUpdateWidget(NotesEditor old) {
    super.didUpdateWidget(old);
    // A change made elsewhere comes in - but not over what is being typed:
    // an echo of an older keystroke would otherwise take the newer ones back.
    final typing = DateTime.now().difference(_typedAt) <
        const Duration(milliseconds: 1500);
    if (widget.text != _controller.text && !typing) {
      _controller.value = TextEditingValue(
        text: widget.text,
        selection: TextSelection.collapsed(offset: widget.text.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    // Its own: the panel sits in the root overlay, above every Material.
    type: MaterialType.transparency,
    child: Padding(
    padding: const EdgeInsets.all(8),
    child: TextField(
      key: const ValueKey('notes_text'),
      controller: _controller,
      focusNode: _focus,
      autofocus: true,
      expands: true,
      maxLines: null,
      minLines: null,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontSize: 14),
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        hintText: 'Notes...',
      ),
      onChanged: (v) {
        _typedAt = DateTime.now();
        widget.onChanged(v);
      },
    ),
    ),
  );
}

// ---------------------------------------------------------------------------
//  THE LINK, ON THE APP'S SIDE
// ---------------------------------------------------------------------------

/// Serves the popped-out notes window: starts it, sends it the notes as they
/// change, and writes back what is typed there.
class NotesHost {
  NotesHost._();
  static final NotesHost instance = NotesHost._();

  ServerSocket? _server;
  Socket? _client;
  AppStateProvider? _provider;
  Timer? _push;
  String _sentKey = '';
  String _sentText = '';
  String _sentTitle = '';
  bool _launching = false;

  /// For tests: replaces starting the copy of the app.
  @visibleForTesting
  static Future<void> Function(List<String> args)? launchForTest;

  bool get poppedOut => _client != null || _launching;

  /// Pops the notes out into a window of their own.
  Future<void> popOut(AppStateProvider provider, {bool dark = false}) async {
    if (_client != null) {
      focusWindow();
      return;
    }
    if (_launching) return;
    _launching = true;
    _attach(provider);
    try {
      final server = _server ??= await _listen();
      final args = jsonEncode({
        'port': server.port,
        'dark': dark,
      });
      final launch = launchForTest;
      if (launch != null) {
        await launch([kNotesPopoutFlag, args]);
      } else {
        await Process.start(
          Platform.resolvedExecutable,
          [kNotesPopoutFlag, args],
          mode: ProcessStartMode.detached,
        );
      }
    } catch (_) {
      _launching = false;
      rethrow;
    }
    // The window gets ten seconds to call back before another can start.
    Timer(const Duration(seconds: 10), () => _launching = false);
  }

  /// Brings the window to the front.
  void focusWindow() => _send({'cmd': 'focus'});

  void _attach(AppStateProvider provider) {
    if (identical(_provider, provider)) return;
    _provider?.removeListener(_schedule);
    _provider = provider;
    provider.addListener(_schedule);
  }

  Future<ServerSocket> _listen() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_accept);
    return server;
  }

  void _accept(Socket socket) {
    _client?.destroy();
    _client = socket;
    _launching = false;
    _sentKey = _sentText = _sentTitle = '';
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_line, onDone: () => _gone(socket), onError: (_) => _gone(socket));
    _flush();
  }

  void _gone(Socket socket) {
    if (identical(_client, socket)) _client = null;
  }

  void _line(String line) {
    final Object? msg;
    try {
      msg = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (msg is! Map) return;
    final provider = _provider;
    if (provider == null) return;
    switch (msg['cmd']) {
      case 'setText':
        // Only into the notes the window was showing: a page change while
        // typing must not put one room's note into another.
        final target = notesTargetOf(provider);
        if (target == null || target.key != msg['key']) return;
        final text = msg['text']?.toString() ?? '';
        _sentText = text;
        writeNotes(provider, target, text);
      case 'dock':
        final context = _dockContext?.call();
        if (context != null && context.mounted) NotesPanel.open(context);
        _client?.destroy();
        _client = null;
    }
  }

  /// Where the panel goes when the window is docked back. Set by the app.
  BuildContext? Function()? _dockContext;
  set dockContext(BuildContext? Function() f) => _dockContext = f;

  void _schedule() {
    if (_client == null) return;
    _push ??= Timer(const Duration(milliseconds: 150), () {
      _push = null;
      _flush();
    });
  }

  void _flush() {
    final provider = _provider;
    if (provider == null || _client == null) return;
    final target = notesTargetOf(provider);
    final key = target?.key ?? '';
    final text = target == null ? '' : notesTextOf(provider, target);
    final title = target?.title ?? 'Notes';
    if (key == _sentKey && text == _sentText && title == _sentTitle) return;
    _sentKey = key;
    _sentText = text;
    _sentTitle = title;
    _send({'cmd': 'data', 'key': key, 'title': title, 'text': text});
  }

  void _send(Map<String, Object?> msg) {
    try {
      _client?.write('${jsonEncode(msg)}\n');
    } catch (_) {}
  }

  /// For tests: drops the window and the server.
  @visibleForTesting
  Future<void> resetForTest() async {
    _client?.destroy();
    _client = null;
    await _server?.close();
    _server = null;
    _provider?.removeListener(_schedule);
    _provider = null;
    _launching = false;
    _sentKey = _sentText = _sentTitle = '';
  }

  @visibleForTesting
  int? get portForTest => _server?.port;
}

// ---------------------------------------------------------------------------
//  THE WINDOW, IN ITS OWN COPY OF THE APP
// ---------------------------------------------------------------------------

/// The notes window's side of the link.
class NotesClient extends ChangeNotifier {
  NotesClient(this.port);

  final int port;
  Socket? _socket;

  String key = '';
  String title = 'Notes';
  String text = '';

  /// Called when the app asks the window to come forward.
  VoidCallback? onFocus;

  /// Called when the app goes away: the window closes with it.
  VoidCallback? onGone;

  Future<void> connect() async {
    final socket =
        await Socket.connect(InternetAddress.loopbackIPv4, port);
    _socket = socket;
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_line, onDone: () => onGone?.call(), onError: (_) => onGone?.call());
  }

  void _line(String line) {
    final Object? msg;
    try {
      msg = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (msg is! Map) return;
    switch (msg['cmd']) {
      case 'data':
        key = msg['key']?.toString() ?? '';
        title = msg['title']?.toString() ?? 'Notes';
        text = msg['text']?.toString() ?? '';
        notifyListeners();
      case 'focus':
        onFocus?.call();
    }
  }

  void setText(String value) {
    text = value;
    _send({'cmd': 'setText', 'key': key, 'text': value});
  }

  void dock() => _send({'cmd': 'dock'});

  void _send(Map<String, Object?> msg) {
    try {
      _socket?.write('${jsonEncode(msg)}\n');
    } catch (_) {}
  }

  void close() => _socket?.destroy();
}

const MethodChannel _chrome = MethodChannel('rcb/window_chrome');

/// Runs this process as the notes window. Never returns to the normal app.
Future<void> runNotesPopout(String argsJson) async {
  WidgetsFlutterBinding.ensureInitialized();
  final args = jsonDecode(argsJson) as Map;
  final port = (args['port'] as num).toInt();
  final dark = args['dark'] == true;
  final client = NotesClient(port);
  client.onGone = () => exit(0);
  client.onFocus = () {
    _chrome.invokeMethod<void>('focus').catchError((_) {});
  };
  try {
    await client.connect();
  } catch (_) {
    exit(0);
  }
  runApp(_NotesWindowApp(client: client, dark: dark));
  void chrome() => _chrome.invokeMethod<void>('setChrome', {
    'title': client.title,
    'width': 560,
    'height': 640,
  }).catchError((_) {});
  chrome();
  var lastTitle = client.title;
  client.addListener(() {
    if (client.title == lastTitle) return;
    lastTitle = client.title;
    _chrome.invokeMethod<void>('setChrome', {'title': client.title})
        .catchError((_) {});
  });
}

class _NotesWindowApp extends StatelessWidget {
  const _NotesWindowApp({required this.client, required this.dark});

  final NotesClient client;
  final bool dark;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: dark ? Brightness.dark : Brightness.light,
      useMaterial3: true,
    ),
    home: NotesWindowPage(client: client),
  );
}

/// The window's one page: the title, a dock-back button, and the notes.
class NotesWindowPage extends StatelessWidget {
  const NotesWindowPage({super.key, required this.client});

  final NotesClient client;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: client,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(client.title, style: const TextStyle(fontSize: 15)),
        actions: [
          TextButton.icon(
            key: const ValueKey('notes_dock'),
            icon: const Icon(Icons.vertical_align_bottom, size: 18),
            label: const Text('Back into the app'),
            onPressed: client.dock,
          ),
        ],
      ),
      body: client.key.isEmpty
          ? const Center(child: Text('Open a room or a project to take notes.'))
          : NotesEditor(
              key: ValueKey('notes_editor_${client.key}'),
              text: client.text,
              onChanged: client.setText,
            ),
    ),
  );
}
