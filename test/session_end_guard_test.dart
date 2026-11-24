import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/session_end_guard.dart';

/// The runner hears when work goes unsaved and saved again, and a held-up
/// sign-out reaches the app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('rcb/session_end_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('tells the runner only when unsaved changes', () async {
    final sent = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setUnsaved') sent.add(call.arguments);
      return null;
    });
    final changes = ChangeNotifier();
    var dirty = false;
    final guard = SessionEndGuard(
      listenable: changes,
      unsaved: () => dirty,
      onSessionEnding: () async {},
      channel: channel,
    )..start();

    changes.notifyListeners(); // still saved: nothing new
    dirty = true;
    changes.notifyListeners();
    changes.notifyListeners(); // still unsaved: nothing new
    dirty = false;
    changes.notifyListeners();
    await Future<void>.delayed(Duration.zero);
    expect(sent, [false, true, false]);

    guard.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a held-up sign-out reaches the app', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    var asked = 0;
    final guard = SessionEndGuard(
      listenable: ChangeNotifier(),
      unsaved: () => true,
      onSessionEnding: () async => asked++,
      channel: channel,
    )..start();

    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('sessionEnding')),
      (_) {},
    );
    expect(asked, 1);

    guard.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });
}
