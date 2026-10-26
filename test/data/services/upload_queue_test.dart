import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:secure_messenger/data/services/upload_queue.dart';

void main() {
  group('UploadQueue', () {
    test('exposes active jobs by chat until they complete', () {
      final queue = UploadQueue();
      final id = queue.register(
        chatId: 'chat-a',
        mediaType: 'image',
        fileName: 'photo.jpg',
      );

      expect(queue.jobsFor('chat-a').single.id, id);
      expect(queue.jobsFor('other-chat'), isEmpty);
      queue.updateProgress(id, 0.42);
      expect(queue.jobsFor('chat-a').single.progress, 0.42);
      expect(queue.cancel(id), isTrue);
      expect(queue.jobsFor('chat-a').single.cancellationToken.isCancelled, isTrue);
      queue.complete(id);
      expect(queue.jobsFor('chat-a'), isEmpty);
      queue.dispose();
    });

    test('cancels a queued job without starting its network work', () async {
      final queue = UploadQueue(maxConcurrent: 1);
      final activeGate = Completer<void>();
      final active = queue.run(() async {
        await activeGate.future;
        return 'finished';
      });

      final token = UploadCancellationToken();
      var queuedTaskStarted = false;
      final queued = queue.run(() async {
        queuedTaskStarted = true;
        return 'should not run';
      }, cancellationToken: token);
      await Future<void>.delayed(Duration.zero);
      expect(queue.waiting, 1);

      token.cancel();
      await expectLater(queued, throwsA(isA<UploadCancelledException>()));
      expect(queuedTaskStarted, isFalse);
      expect(queue.waiting, 0);

      activeGate.complete();
      expect(await active, 'finished');
      expect(queue.running, 0);
      queue.dispose();
    });

    test('releases a running slot when an active transfer is cancelled', () async {
      final queue = UploadQueue(maxConcurrent: 1);
      final token = UploadCancellationToken();
      final active = queue.run(() async {
        await token.whenCancelled;
        token.throwIfCancelled();
      }, cancellationToken: token);

      token.cancel();
      await expectLater(active, throwsA(isA<UploadCancelledException>()));
      expect(queue.running, 0);
      queue.dispose();
    });
  });
}
