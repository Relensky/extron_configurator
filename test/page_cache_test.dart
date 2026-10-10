import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_activity.dart';
import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/page_cache.dart';

/// Visited tabs stay mounted, hidden and frozen; the app pauses while away.
void main() {
  final builds = <String, int>{};

  Widget page(String name) => _Counted(name: name, builds: builds);

  Future<void> show(
    WidgetTester tester,
    AppStateProvider p,
    String name, {
    int epoch = 0,
    bool keep = false,
    bool cacheable = true,
    String Function()? stamp,
  }) async {
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: p,
      child: MaterialApp(
        home: PageCache(
          page: (key: name, keepAcrossEpochs: keep),
          epoch: epoch,
          cacheable: cacheable,
          maxPages: 3,
          stamp: stamp,
          builder: (_) => page(name),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  void ping(AppStateProvider p) =>
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      p.notifyListeners();

  setUp(builds.clear);

  testWidgets('a page left keeps its state and is frozen while hidden',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    await show(tester, p, 'a');
    await tester.tap(find.text('a: 0'));
    await tester.pump();
    expect(find.text('a: 1'), findsOneWidget);

    await show(tester, p, 'b');
    expect(find.text('a: 1'), findsNothing, reason: 'hidden');
    final aBuilds = builds['a']!;

    // The app changes while a is hidden: only b rebuilds.
    ping(p);
    await tester.pump();
    expect(builds['a'], aBuilds);

    // Back to a: its counter is still there, and it catches up once.
    await show(tester, p, 'a');
    expect(find.text('a: 1'), findsOneWidget);
    expect(builds['a'], greaterThan(aBuilds));
    p.dispose();
  });

  testWidgets('a page that is not cacheable is dropped when left',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    await show(tester, p, 'a', cacheable: false);
    await tester.tap(find.text('a: 0'));
    await tester.pump();
    await show(tester, p, 'b');
    await show(tester, p, 'a', cacheable: false);
    expect(find.text('a: 0'), findsOneWidget);
    p.dispose();
  });

  testWidgets('another room drops the room pages but keeps the job',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    await show(tester, p, 'room');
    await tester.tap(find.text('room: 0'));
    await show(tester, p, 'job', keep: true);
    await tester.tap(find.text('job: 0'));
    await tester.pump();

    await show(tester, p, 'other', epoch: 1);
    await show(tester, p, 'job', epoch: 1, keep: true);
    expect(find.text('job: 1'), findsOneWidget);
    await show(tester, p, 'room', epoch: 1);
    expect(find.text('room: 0'), findsOneWidget, reason: 'built afresh');
    p.dispose();
  });

  testWidgets('only the most recent pages stay', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    await show(tester, p, 'a');
    await tester.tap(find.text('a: 0'));
    await show(tester, p, 'b');
    await show(tester, p, 'c');
    await show(tester, p, 'd');
    await show(tester, p, 'a');
    expect(find.text('a: 0'), findsOneWidget, reason: 'a was evicted');
    p.dispose();
  });

  testWidgets('a form page is built afresh only if the room changed',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    var room = 'one';
    String stamp() => room;
    await show(tester, p, 'form', stamp: stamp);
    await tester.tap(find.text('form: 0'));
    await tester.pump();

    // Nothing changed while away: shown as it was.
    await show(tester, p, 'other');
    await show(tester, p, 'form', stamp: stamp);
    expect(find.text('form: 1'), findsOneWidget);

    // The room changed while away: built afresh.
    await show(tester, p, 'other');
    room = 'two';
    await show(tester, p, 'form', stamp: stamp);
    expect(find.text('form: 0'), findsOneWidget);
    p.dispose();
  });

  test('away while hidden or locked, and back', () {
    final a = AppActivity.instance;
    var heard = 0;
    void listener() => heard++;
    a.addListener(listener);
    expect(AppActivity.away, isFalse);
    a.setLocked(true);
    expect(AppActivity.away, isTrue);
    a.setHidden(true);
    a.setLocked(false);
    expect(AppActivity.away, isTrue, reason: 'still minimized');
    a.setHidden(false);
    expect(AppActivity.away, isFalse);
    expect(heard, 2, reason: 'once away, once back');
    a.removeListener(listener);
  });
}

class _Counted extends StatefulWidget {
  const _Counted({required this.name, required this.builds});
  final String name;
  final Map<String, int> builds;

  @override
  State<_Counted> createState() => _CountedState();
}

class _CountedState extends State<_Counted> {
  int taps = 0;

  @override
  Widget build(BuildContext context) {
    context.watch<AppStateProvider>();
    widget.builds[widget.name] = (widget.builds[widget.name] ?? 0) + 1;
    return Center(
      child: TextButton(
        onPressed: () => setState(() => taps++),
        child: Text('${widget.name}: $taps'),
      ),
    );
  }
}
