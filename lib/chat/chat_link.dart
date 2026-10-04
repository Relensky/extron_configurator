import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'project_chat.dart';

/// ============================================================================
///  ONE CHAT VIEW, THREE PLACES TO PUT IT
/// ============================================================================
///  The slide-out and the floating panel run inside the app; the separate
///  window is a second copy of this .exe started with [kChatWindowFlag],
///  talking back over a loopback socket (the CTS Dashboard's pop-out model).
///  The view is written against [ChatLink] and never knows which it is in.
///
///  Wire protocol, one JSON object per line:
///    window -> app : {cmd:'subscribe', token}  {cmd:'action', action, ...}
///    app -> window : {cmd:'data', payload}  {cmd:'theme', dark, accent}
///                    {cmd:'focus'}
///  Dropping the socket is how the app tells a window it is done with it.
/// ============================================================================

const kChatWindowFlag = '--chat-window';

/// Sets the window's own title and size, and raises it - see
/// windows/runner/flutter_window.cpp.
const MethodChannel kWindowChromeChannel = MethodChannel('rcb/window_chrome');

/// What a chat view talks to.
abstract class ChatLink {
  ValueListenable<ChatSnapshot?> get snapshot;

  /// Posts [text] to [channel]. Returns what went wrong, or ''.
  Future<String> post(String channel, String text);

  void select(String channel);

  /// Moves the chat to another container.
  void setMode(ChatMode mode);

  void close();

  bool get inWindow;
}

/// The in-app link: straight to the app state.
class LocalChatLink implements ChatLink {
  final AppStateProvider provider;

  LocalChatLink(this.provider) {
    provider.chat.addListener(_schedule);
    provider.addListener(_schedule);
    _value.value = provider.chat.snapshot();
  }

  final ValueNotifier<ChatSnapshot?> _value = ValueNotifier(null);
  bool _pending = false;
  bool _disposed = false;

  /// One snapshot per frame at most, however many changes land in it.
  void _schedule() {
    if (_pending || _disposed) return;
    _pending = true;
    scheduleMicrotask(() {
      _pending = false;
      if (!_disposed) _value.value = provider.chat.snapshot();
    });
  }

  @override
  ValueListenable<ChatSnapshot?> get snapshot => _value;

  @override
  Future<String> post(String channel, String text) =>
      provider.chat.post(text, to: channel);

  @override
  void select(String channel) => provider.chat.selectChannel(channel);

  @override
  void setMode(ChatMode mode) {
    provider.setChatMode(mode);
    if (mode == ChatMode.window) ChatWindowHost.instance.open(provider);
  }

  @override
  void close() => provider.chat.setOpen(false);

  @override
  bool get inWindow => false;

  void dispose() {
    _disposed = true;
    provider.chat.removeListener(_schedule);
    provider.removeListener(_schedule);
    _value.dispose();
  }
}

/// The app's end of the separate chat window.
class ChatWindowHost {
  ChatWindowHost._();
  static final ChatWindowHost instance = ChatWindowHost._();

  ServerSocket? _server;
  Socket? _client;
  bool _launching = false;
  AppStateProvider? _provider;
  Timer? _push;

  /// Shared with the window on its command line, so nothing else on this
  /// machine that finds the port can post as you.
  final String _token = List.generate(
          16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();

  /// Dark or light, and the accent, for the window to draw itself in. Kept
  /// current by the chat layer.
  bool dark = true;
  int accent = 0xFF2196F3;

  bool get isOpen => _client != null;

  /// Opens the window, or brings it forward when it is already open.
  Future<void> open(AppStateProvider provider) async {
    _provider = provider;
    provider.chat.setOpen(true);
    if (_client != null) {
      _send({'cmd': 'focus'});
      return;
    }
    if (_launching) return;
    _launching = true;
    try {
      if (_server == null) {
        final server =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        server.listen(_onConnection);
        _server = server;
      }
      final args = jsonEncode({
        'port': _server!.port,
        'token': _token,
        'dark': dark,
        'accent': accent,
      });
      await Process.start(Platform.resolvedExecutable, [kChatWindowFlag, args],
          mode: ProcessStartMode.detached);
      Timer(const Duration(seconds: 15), () => _launching = false);
    } catch (e) {
      _launching = false;
      debugPrint('Chat window failed to open: $e');
    }
  }

  void pushTheme() => _send({'cmd': 'theme', 'dark': dark, 'accent': accent});

  void _onConnection(Socket socket) {
    var buffer = '';
    var subscribed = false;
    socket.listen(
      (bytes) {
        buffer += utf8.decode(bytes, allowMalformed: true);
        int nl;
        while ((nl = buffer.indexOf('\n')) >= 0) {
          final line = buffer.substring(0, nl);
          buffer = buffer.substring(nl + 1);
          Map msg;
          try {
            msg = jsonDecode(line) as Map;
          } catch (_) {
            continue;
          }
          if (!subscribed) {
            if (msg['cmd'] != 'subscribe' || msg['token'] != _token) {
              socket.destroy();
              return;
            }
            subscribed = true;
            _attach(socket);
            continue;
          }
          if (identical(socket, _client)) _handle(msg);
        }
      },
      onDone: () => _drop(socket),
      onError: (_) => _drop(socket),
      cancelOnError: true,
    );
  }

  void _attach(Socket socket) {
    _client?.destroy();
    _client = socket;
    _launching = false;
    final p = _provider;
    if (p != null) {
      p.chat.addListener(_schedule);
      p.addListener(_schedule);
    }
    pushTheme();
    _flush();
  }

  void _drop(Socket socket) {
    if (!identical(socket, _client)) return;
    _client = null;
    final p = _provider;
    if (p != null) {
      p.chat.removeListener(_schedule);
      p.removeListener(_schedule);
      // The window was closed: the chat is closed, unless it moved in-app.
      if (p.chatMode == ChatMode.window) p.chat.setOpen(false);
    }
  }

  void _schedule() {
    if (_push?.isActive ?? false) return;
    _push = Timer(const Duration(milliseconds: 150), _flush);
  }

  void _flush() {
    final p = _provider;
    if (p == null) return;
    _send({'cmd': 'data', 'payload': p.chat.snapshot().toJson()});
  }

  Future<void> _handle(Map msg) async {
    final p = _provider;
    if (p == null || msg['cmd'] != 'action') return;
    switch (msg['action']) {
      case 'post':
        final error = await p.chat.post('${msg['text'] ?? ''}',
            to: '${msg['channel'] ?? kChatGeneral}');
        if (error.isNotEmpty) _send({'cmd': 'error', 'text': error});
      case 'select':
        p.chat.selectChannel('${msg['channel'] ?? kChatGeneral}');
      case 'mode':
        final mode = ChatMode.values.firstWhere((m) => m.name == msg['mode'],
            orElse: () => ChatMode.slideOut);
        if (mode == ChatMode.window) return;
        // Back into the app: the panel opens, then the window is let go.
        p.setChatMode(mode);
        p.chat.setOpen(true);
        final socket = _client;
        _drop(socket!);
        socket.destroy();
      case 'close':
        p.chat.setOpen(false);
        _client?.destroy();
    }
  }

  void _send(Map<String, dynamic> msg) {
    try {
      _client?.write('${jsonEncode(msg)}\n');
    } catch (_) {}
  }

  /// Closes the window, when the chat moves back into the app.
  void closeWindow() {
    final socket = _client;
    if (socket == null) return;
    _drop(socket);
    socket.destroy();
  }
}

/// The window's end: what [ChatLink] is in the separate window.
class SocketChatLink implements ChatLink {
  final int port;
  final String token;

  SocketChatLink({required this.port, required this.token});

  final ValueNotifier<ChatSnapshot?> _value = ValueNotifier(null);
  final ValueNotifier<(bool, int)?> theme = ValueNotifier(null);
  final ValueNotifier<String?> error = ValueNotifier(null);
  Socket? _socket;

  /// Called when the app lets go of the window.
  VoidCallback? onGone;
  VoidCallback? onFocus;

  Future<void> connect() async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      _socket = socket;
      var buffer = '';
      socket.listen(
        (bytes) {
          buffer += utf8.decode(bytes, allowMalformed: true);
          int nl;
          while ((nl = buffer.indexOf('\n')) >= 0) {
            final line = buffer.substring(0, nl);
            buffer = buffer.substring(nl + 1);
            try {
              _handle(jsonDecode(line) as Map);
            } catch (_) {}
          }
        },
        onDone: () => onGone?.call(),
        onError: (_) => onGone?.call(),
        cancelOnError: true,
      );
      _send({'cmd': 'subscribe', 'token': token});
    } catch (_) {
      onGone?.call();
    }
  }

  void _handle(Map msg) {
    switch (msg['cmd']) {
      case 'data':
        if (msg['payload'] is Map) {
          _value.value = ChatSnapshot.fromJson(msg['payload'] as Map);
        }
      case 'theme':
        theme.value = (
          msg['dark'] == true,
          (msg['accent'] as num?)?.toInt() ?? 0xFF2196F3,
        );
      case 'focus':
        onFocus?.call();
      case 'error':
        error.value = '${msg['text'] ?? ''}';
    }
  }

  void _send(Map<String, dynamic> msg) {
    try {
      _socket?.write('${jsonEncode(msg)}\n');
    } catch (_) {}
  }

  void _action(String action, [Map<String, dynamic> extra = const {}]) =>
      _send({'cmd': 'action', 'action': action, ...extra});

  @override
  ValueListenable<ChatSnapshot?> get snapshot => _value;

  @override
  Future<String> post(String channel, String text) async {
    _action('post', {'channel': channel, 'text': text});
    return '';
  }

  @override
  void select(String channel) => _action('select', {'channel': channel});

  @override
  void setMode(ChatMode mode) => _action('mode', {'mode': mode.name});

  @override
  void close() => _action('close');

  @override
  bool get inWindow => true;
}
