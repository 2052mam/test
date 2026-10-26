import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/data/services/upload_queue.dart';

void main() {
  test('uploads run in parallel up to the cap, never beyond', () async {
    final queue = UploadQueue(maxConcurrent: 3);
    var running = 0;
    var peak = 0;
    final gates = List.generate(6, (_) => Completer<void>());

    final futures = [
      for (var i = 0; i < 6; i++)
        queue.run(() async {
          running++;
          if (running > peak) peak = running;
          await gates[i].future;
          running--;
          return i;
        }),
    ];

    // Let the first wave start; the rest must be queued, not running.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(running, 3);
    expect(queue.waiting, 3);

    for (final gate in gates) {
      gate.complete();
    }
    final results = await Future.wait(futures);
    expect(results, [0, 1, 2, 3, 4, 5]);
    expect(peak, 3);
    expect(queue.running, 0);
    expect(queue.waiting, 0);
  });

  test('a failing upload releases its slot for the next file', () async {
    final queue = UploadQueue(maxConcurrent: 1);
    final order = <String>[];
    final first = queue.run<String>(() async {
      order.add('first');
      throw StateError('boom');
    });
    final second = queue.run<String>(() async {
      order.add('second');
      return 'done';
    });
    await expectLater(first, throwsStateError);
    expect(await second, 'done');
    expect(order, ['first', 'second']);
  });
}
