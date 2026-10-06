import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/chat/chat_link.dart';
import 'package:extron_configurator/chat/chat_view.dart';
import 'package:extron_configurator/chat/gif_search.dart';
import 'package:extron_configurator/chat/project_chat.dart';

/// A link that records what the view asked for.
class _FakeLink implements ChatLink {
  final ValueNotifier<ChatSnapshot?> value;
  final List<String> calls = [];
  _FakeLink(ChatSnapshot snap) : value = ValueNotifier(snap);

  @override
  ValueListenable<ChatSnapshot?> get snapshot => value;
  @override
  Future<String> post(String channel, String text, {String? image}) async {
    calls.add('post:$text');
    return '';
  }

  @override
  Future<String> deleteMessage(String id) async {
    calls.add('delete:$id');
    return '';
  }

  @override
  Future<String> editMessage(String id, String text) async {
    calls.add('edit:$id:$text');
    return '';
  }

  @override
  Future<String> react(String id, String emoji) async {
    calls.add('react:$id:$emoji');
    return '';
  }

  @override
  void select(String channel) {}
  @override
  void setMode(ChatMode mode) {}
  @override
  void close() {}
  @override
  bool get inWindow => false;
}

ChatMessage _msg(String id, String user, String text, {int minute = 0,
        Map<String, List<String>> reactions = const {}, bool edited = false}) =>
    ChatMessage(
      id: id,
      channel: kChatGeneral,
      user: user,
      name: user,
      at: DateTime(2026, 10, 6, 9, minute),
      text: text,
      reactions: reactions,
      editedAt: edited ? DateTime(2026, 10, 6, 10) : null,
    );

ChatSnapshot _snap(List<ChatMessage> messages) => ChatSnapshot(
  me: 'alice',
  attached: true,
  project: 'BSS',
  folder: '',
  people: const [ChatPerson(login: 'alice'), ChatPerson(login: 'bob')],
  channels: const [
    ChatChannel(id: kChatGeneral, label: 'General', kind: 'general'),
  ],
  messages: messages,
  channel: kChatGeneral,
  hereRoomChannel: '',
  hereTabChannel: '',
  mode: ChatMode.slideOut,
);

void main() {
  Future<_FakeLink> pump(WidgetTester tester, List<ChatMessage> messages) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final link = _FakeLink(_snap(messages));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChatView(link: link, onSearchAll: () {})),
    ));
    await tester.pumpAndSettle();
    return link;
  }

  testWidgets('search is a button that opens a bar and filters', (tester) async {
    await pump(tester, [
      _msg('m1', 'alice', 'Projector is mounted'),
      _msg('m2', 'bob', 'Screen arrives Friday', minute: 1),
    ]);
    expect(find.byKey(const ValueKey('chat_search_bar')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat_search_toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat_search_bar')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('chat_search_bar')),
      'screen',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat_message_m2')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat_message_m1')), findsNothing);
    expect(find.text('1 found'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('your own message is edited in place and shows edited', (
    tester,
  ) async {
    final link = await pump(tester, [
      _msg('m1', 'alice', 'Screen at 96 in'),
      _msg('m2', 'bob', 'Ok', minute: 1, edited: true),
    ]);
    expect(find.textContaining('(edited)', findRichText: true), findsOneWidget);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('chat_message_m1'))),
    );
    await tester.pumpAndSettle();
    // Only your own message offers edit.
    expect(find.byKey(const ValueKey('chat_edit_m1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat_edit_m1')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('chat_edit_input')),
      'Screen at 106 in',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(link.calls, contains('edit:m1:Screen at 106 in'));

    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('chat_message_m2'))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat_edit_m2')), findsNothing);
  });

  testWidgets('a reaction chip counts and toggles yours', (tester) async {
    final link = await pump(tester, [
      _msg('m1', 'bob', 'Install Tuesday?', reactions: {
        '👍': ['alice', 'bob'],
      }),
    ]);
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat_reaction_👍')));
    await tester.pump();
    expect(link.calls, ['react:m1:👍']);
  });

  testWidgets('with no GIF key, the GIF button takes a link', (tester) async {
    await pump(tester, [_msg('m1', 'bob', 'Hi')]);
    await tester.tap(find.byKey(const ValueKey('chat_gif')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat_gif_link')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat_gif_query')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('a KLIPY answer reads as GIFs with a preview and the full file', () {
    Map<String, dynamic> size(String url) => {
      'gif': {'url': url, 'width': 320, 'height': 240},
    };
    final gifs = parseKlipy({
      'result': true,
      'data': {
        'data': [
          {
            'id': 123,
            'title': 'thumbs up',
            'type': 'gif',
            'file': {
              'hd': size('https://static.klipy.com/hd.gif'),
              'md': size('https://static.klipy.com/md.gif'),
              'sm': size('https://static.klipy.com/sm.gif'),
            },
          },
          // An ad slot is not a GIF.
          {'id': 9, 'type': 'ad'},
        ],
      },
    });
    expect(gifs, hasLength(1));
    expect(gifs.single.full, 'https://static.klipy.com/md.gif');
    expect(gifs.single.preview, 'https://static.klipy.com/sm.gif');
    final uri = klipyUri('KEY', 'thumbs up', customer: 'c');
    expect(uri.path, '/api/v1/KEY/gifs/search');
    expect(uri.queryParameters['q'], 'thumbs up');
    expect(klipyUri('KEY', '', customer: 'c').path, '/api/v1/KEY/gifs/trending');
    expect(gifSearchKeyOr('  mine  '), 'mine');
  });
}
