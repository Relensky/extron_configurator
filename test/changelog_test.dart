import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/changelog.dart';
import 'package:extron_configurator/help_view.dart';

/// The version in Help and the changelog under it.
void main() {
  test('the app version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)!.group(1);
    expect(kAppVersion, version);
  });

  test('the newest entry is this version', () {
    expect(kChangelog.first.version, kAppVersionShort);
  });

  test('every entry says when and what', () {
    for (final entry in kChangelog) {
      expect(entry.date.trim(), isNotEmpty);
      expect(entry.title.trim(), isNotEmpty);
      expect(entry.changes, isNotEmpty);
    }
  });

  testWidgets("Help shows the version and What's new", (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HelpBook())),
    );
    await tester.pump();
    expect(find.text('v$kAppVersionShort'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('help_whats_new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('help_changelog')), findsOneWidget);
    expect(find.text(kChangelog.first.title), findsOneWidget);
  });
}
