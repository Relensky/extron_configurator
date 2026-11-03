import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/deploy_build.dart';

/// Build for Deployment: the template's local_build.py, run from the app.
void main() {
  late Directory tmp;
  late String root;

  /// A template: local_build.py, two rooms, and ARTS107's config.
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('deploy_build_');
    root = path.join(tmp.path, 'ControlScript-Template');
    File(path.join(root, kLocalBuildScript)).createSync(recursive: true);
    for (final r in ['BSS108', 'ARTS107']) {
      File(path.join(root, 'rooms', r, 'code', 'upload_to_root', 'config.json'))
          .createSync(recursive: true);
    }
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String config(String room) =>
      path.join(root, 'rooms', room, 'code', 'upload_to_root', 'config.json');

  /// What local_build.py leaves in dist for [room].
  void built(String room, {List<String> extras = const []}) {
    for (final f in [
      'main.py',
      'upload_to_root/config.json',
      'upload_to_root/MainTLP_WhereUsedReportSheet.csv',
      ...extras,
    ]) {
      File(path.join(root, 'dist', room, f)).createSync(recursive: true);
    }
  }

  test('the template and room are found from the open config', () {
    expect(controlScriptRootOf(config('ARTS107')), root);
    expect(controlScriptRootOf(root), root);
    expect(controlScriptRootOf(tmp.path), isNull);
    expect(controlScriptRootOf(''), isNull);
    expect(templateRoomOf(config('ARTS107'), root), 'ARTS107');
    expect(templateRoomOf(path.join(tmp.path, 'x.json'), root), '');
    expect(templateRooms(root), ['ARTS107', 'BSS108']);
  });

  test('the script always gets its rooms and options, so it never asks', () {
    expect(localBuildArgs(['A', 'B']),
        ['-u', 'local_build.py', 'A', 'B', '--prune-modules']);
    expect(localBuildArgs(['A'], prune: false, skipCheck: true),
        ['-u', 'local_build.py', 'A', '--all-modules', '--skip-check']);
  });

  test('each room\'s outcome is read from the script\'s summary', () {
    const rooms = ['A', 'B', 'C', 'D'];
    expect(
      parseLocalBuild('All 4 room(s) built and passed', rooms, 0).values,
      everyElement(RoomBuildStatus.ready),
    );
    final mixed = parseLocalBuild(
      '1 of 4 room(s) OK.\n'
      'Build failed: B\n'
      'Built, but NOT safe to upload: C, D\n'
      '   Per-room detail: dist/<Room>-platform-check.log',
      rooms,
      1,
    );
    expect(mixed, {
      'A': RoomBuildStatus.ready,
      'B': RoomBuildStatus.failed,
      'C': RoomBuildStatus.notSafe,
      'D': RoomBuildStatus.notSafe,
    });
    // Died before its summary: nothing came out.
    expect(
      parseLocalBuild('Traceback ...', rooms, 1).values,
      everyElement(RoomBuildStatus.failed),
    );
    expect(parseLocalBuild('', ['A'], 0, skipCheck: true),
        {'A': RoomBuildStatus.unchecked});
    expect(RoomBuildStatus.unchecked.shippable, isTrue);
    expect(RoomBuildStatus.notSafe.shippable, isFalse);
  });

  test('a built room is copied out whole, replacing the last one', () async {
    built('ARTS107', extras: [
      'upload_to_root/room_files/ARTS107_cost.json',
      'upload_to_root/.editing/config.json/me@pc.json',
    ]);
    expect(extraRootFiles(path.join(root, 'dist', 'ARTS107')), [
      path.join('.editing', 'config.json', 'me@pc.json'),
      path.join('room_files', 'ARTS107_cost.json'),
    ]);
    final dest = path.join(tmp.path, 'send');
    File(path.join(dest, 'ARTS107', 'stale.py')).createSync(recursive: true);
    final to = await copyBuiltRoom(root, 'ARTS107', dest);
    expect(to, path.join(dest, 'ARTS107'));
    expect(File(path.join(to, 'main.py')).existsSync(), isTrue);
    expect(File(path.join(to, 'upload_to_root', 'config.json')).existsSync(),
        isTrue);
    expect(File(path.join(to, 'stale.py')).existsSync(), isFalse);
    // Into the template's own dist: already there.
    expect(await copyBuiltRoom(root, 'ARTS107', path.join(root, 'dist')),
        path.join(root, 'dist', 'ARTS107'));
  });

  testWidgets('the open room builds and lands in the distribution folder', (
    tester,
  ) async {
    final dest = path.join(tmp.path, 'send');
    final p = AppStateProvider(autoLoadSettings: false)
      ..currentConfigPath = config('ARTS107')
      ..deployOutputPath = dest;
    List<String>? ran;
    var exit = 0;
    var summary = 'All 1 room(s) built and passed their platform checks.';
    Future<int> fake(
      String at,
      List<String> args,
      void Function(String) onLine,
      void Function(Process) started,
    ) async {
      expect(at, root);
      ran = args;
      for (final r in args.where((a) => !a.startsWith('-') && a != kLocalBuildScript)) {
        built(r, extras: ['upload_to_root/room_files/x.json']);
      }
      onLine('--- Building room ---');
      onLine(summary);
      return exit;
    }

    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(body: DeployBuildDialog(runner: fake)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<SelectableText>(
          find.byKey(const ValueKey('deploy_build_root'))).data,
      root,
    );
    expect(
      tester.widget<FilterChip>(
          find.byKey(const ValueKey('deploy_build_room_ARTS107'))).selected,
      isTrue,
    );
    expect(
      tester.widget<FilterChip>(
          find.byKey(const ValueKey('deploy_build_room_BSS108'))).selected,
      isFalse,
    );

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('deploy_build_go')));
      await tester.pump();
      for (var i = 0; i < 50 && find.byType(LinearProgressIndicator)
          .evaluate().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(ran, ['-u', 'local_build.py', 'ARTS107', '--prune-modules']);
    expect(find.text('ARTS107: Built and checked'), findsOneWidget);
    expect(File(path.join(dest, 'ARTS107', 'main.py')).existsSync(), isTrue);
    expect(find.byKey(const ValueKey('deploy_build_extras_ARTS107')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('deploy_build_open_dest')),
        findsOneWidget);

    // Both rooms; BSS108 fails its check and is not copied out.
    await tester.tap(find.byKey(const ValueKey('deploy_build_all')));
    await tester.pump();
    exit = 1;
    summary = 'Built, but NOT safe to upload: BSS108';
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('deploy_build_go')));
      await tester.pump();
      for (var i = 0; i < 50 && find.byType(LinearProgressIndicator)
          .evaluate().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(ran, [
      '-u', 'local_build.py', 'ARTS107', 'BSS108', '--prune-modules',
    ]);
    expect(find.text('BSS108: Built, but NOT safe to upload'), findsOneWidget);
    expect(Directory(path.join(dest, 'BSS108')).existsSync(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
