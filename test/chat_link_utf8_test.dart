import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:extron_configurator/chat/chat_link.dart';

void main() {
  test('the chat window reads a character split across two reads', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    const text = 'Café — Mañana · ok';
    final bytes = utf8.encode('${jsonEncode({'cmd': 'error', 'text': text})}\n');
    // Cut inside the two bytes of the é.
    final cut = utf8.encode('{"cmd":"error","text":"Caf').length + 1;
    server.listen((socket) async {
      socket.add(bytes.sublist(0, cut));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      socket.add(bytes.sublist(cut));
      await socket.flush();
    });

    final link = SocketChatLink(port: server.port, token: 't');
    final got = Completer<String>();
    link.error.addListener(() {
      final v = link.error.value;
      if (v != null && !got.isCompleted) got.complete(v);
    });
    await link.connect();
    expect(await got.future.timeout(const Duration(seconds: 5)), text);
    await server.close();
  });
}
