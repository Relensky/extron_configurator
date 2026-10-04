import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'chat_link.dart';
import 'chat_view.dart';

/// The chat in a window of its own: a second copy of the app that runs
/// nothing but [ChatView], fed by the main app over [SocketChatLink]. It
/// closes itself when the main app lets go of it.
void runChatWindow(String rawArgs) {
  Map args;
  try {
    args = jsonDecode(rawArgs) as Map;
  } catch (_) {
    exit(0);
  }
  final link = SocketChatLink(
    port: (args['port'] as num?)?.toInt() ?? 0,
    token: '${args['token'] ?? ''}',
  )
    ..theme.value = (
      args['dark'] == true,
      (args['accent'] as num?)?.toInt() ?? 0xFF2196F3,
    )
    ..onGone = (() => exit(0))
    ..onFocus = (() =>
        kWindowChromeChannel.invokeMethod('focus').catchError((Object _) {}));
  runApp(_ChatWindowApp(link: link));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    kWindowChromeChannel.invokeMethod('setChrome', {
      'title': 'Project chat - Room Config Builder',
      'width': 560,
      'height': 680,
    }).catchError((Object _) {});
  });
  link.connect();
}

class _ChatWindowApp extends StatelessWidget {
  final SocketChatLink link;

  const _ChatWindowApp({required this.link});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<(bool, int)?>(
      valueListenable: link.theme,
      builder: (context, theme, _) {
        final dark = theme?.$1 ?? true;
        final scheme = ColorScheme.fromSeed(
          seedColor: Color(theme?.$2 ?? 0xFF2196F3),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Project chat',
          theme: ThemeData(colorScheme: scheme, useMaterial3: true),
          home: Scaffold(
            body: SafeArea(child: ChatView(link: link)),
          ),
        );
      },
    );
  }
}
