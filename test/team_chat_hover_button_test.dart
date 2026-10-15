import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/hover_fade.dart';
import 'package:extron_configurator/team/team_chat.dart';
import 'package:extron_configurator/team/team_notices.dart';
import 'package:extron_configurator/team/team_widgets.dart';

/// The team starts after the window is first drawn, so the hovering chat
/// button has to turn up once the chat does - it used to look once, find
/// nothing, and never show.
void main() {
  tearDown(() => Team.chat = null);

  testWidgets('the button turns up once the chat starts', (tester) async {
    Team.chat = null;
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Positioned.fill(child: SizedBox()),
          TeamChatHoverButton(),
        ]),
      ),
    ));
    expect(find.byType(HoverFade), findsNothing);

    Team.chat = TeamChat();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(HoverFade), findsOneWidget);
  });

  test('the count is the color opposite the accent', () {
    // Blue's opposite is an orange; the ink is whichever reads on it.
    final pill = teamComplementOf(const Color(0xFF1565C0));
    final hue = HSLColor.fromColor(pill).hue;
    expect(hue, inInclusiveRange(25, 40));
    final a = pill.computeLuminance(), b = teamInkOn(pill).computeLuminance();
    final contrast = (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
    expect(contrast, greaterThan(3));
    // A gray has no hue to turn, so it flips light for dark.
    final onGray = teamComplementOf(const Color(0xFF424242));
    expect(HSLColor.fromColor(onGray).lightness, greaterThan(0.6));
  });

  testWidgets("the count can take the button's inverse colors",
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: TeamUnreadIcon(
            unread: 3,
            mentions: 0,
            pillColor: Colors.white,
            onPillColor: Colors.indigo,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final pill = tester.widget<Container>(find.ancestor(
      of: find.text('3'),
      matching: find.byType(Container),
    ).first);
    expect((pill.decoration as BoxDecoration).color, Colors.white);
    expect(tester.widget<Text>(find.text('3')).style?.color, Colors.indigo);
  });
}
