import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/collab/collab_controller.dart';

/// Merges and saves run one at a time.
void main() {
  test('jobs run in the order they were queued, never together', () async {
    final c = CollabController();
    final log = <String>[];
    var running = 0;
    var most = 0;

    Future<void> job(String name, int ms) => c.enqueue(() async {
          running++;
          most = running > most ? running : most;
          log.add('start $name');
          await Future<void>.delayed(Duration(milliseconds: ms));
          log.add('end $name');
          running--;
        });

    expect(c.queued, 0);
    final all = Future.wait([job('a', 30), job('b', 5), job('c', 1)]);
    expect(c.queued, 3);
    await all;

    expect(most, 1);
    expect(log, [
      'start a', 'end a', 'start b', 'end b', 'start c', 'end c', //
    ]);
    expect(c.queued, 0);
  });

  test('a job that queues more work does not wait on itself', () async {
    final c = CollabController();
    final inner = await c
        .enqueue(() => c.enqueue(() async => 'inner'))
        .timeout(const Duration(seconds: 2));
    expect(inner, 'inner');
  });

  test('a failed job does not stop the ones behind it', () async {
    final c = CollabController();
    final failed = c.enqueue<void>(() async => throw StateError('no'));
    final next = c.enqueue(() async => 'next');
    await expectLater(failed, throwsStateError);
    expect(await next, 'next');
    expect(c.queued, 0);
  });
}
