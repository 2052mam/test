import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// A user-cancelled transfer; callers can treat this as a normal termination.
class UploadCancelledException implements Exception {
  const UploadCancelledException();

  @override
  String toString() => 'Upload cancelled';
}

/// Cancellation signal shared by the scheduler and the HTTP multipart request.
class UploadCancellationToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const UploadCancelledException();
  }
}

/// App-scoped status for an upload. Jobs outlive the chat route that created
/// them, so leaving and reopening a chat keeps its progress and cancel action.
class UploadTask {
  UploadTask({
    required this.id,
    required this.chatId,
    required this.mediaType,
    required this.fileName,
    required this.cancellationToken,
  });

  final String id;
  final String chatId;
  final String mediaType;
  final String? fileName;
  final UploadCancellationToken cancellationToken;
  double? progress;
  bool isFinalizing = false;
  bool cancelRequested = false;

  bool get canCancel => !isFinalizing && !cancelRequested;
}

class _QueueWaiter {
  final Completer<void> ready = Completer<void>();
}

/// App-wide, bounded upload scheduler and progress registry.
///
/// Transfers continue independently of a ChatScreen's lifecycle. The same
/// registry feeds the composer when the user returns to that chat. Queued jobs
/// can be removed immediately; active HTTP requests receive an abort signal.
class UploadQueue extends ChangeNotifier {
  UploadQueue({this.maxConcurrent = 3});

  static final UploadQueue instance = UploadQueue();

  final int maxConcurrent;
  int _running = 0;
  int _sequence = 0;
  final Queue<_QueueWaiter> _waiters = Queue<_QueueWaiter>();
  final LinkedHashMap<String, UploadTask> _tasks =
      LinkedHashMap<String, UploadTask>();

  int get running => _running;
  int get waiting => _waiters.length;

  List<UploadTask> jobsFor(String chatId) => List.unmodifiable(
        _tasks.values.where((task) => task.chatId == chatId),
      );

  String register({
    required String chatId,
    required String mediaType,
    String? fileName,
  }) {
    final id = 'upload-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    _tasks[id] = UploadTask(
      id: id,
      chatId: chatId,
      mediaType: mediaType,
      fileName: fileName,
      cancellationToken: UploadCancellationToken(),
    );
    notifyListeners();
    return id;
  }

  UploadCancellationToken? tokenFor(String id) => _tasks[id]?.cancellationToken;

  void updateProgress(String id, double progress) {
    final task = _tasks[id];
    if (task == null || task.isFinalizing || task.cancelRequested) return;
    task.progress = progress.clamp(0.0, 1.0).toDouble();
    notifyListeners();
  }

  void markFinalizing(String id) {
    final task = _tasks[id];
    if (task == null || task.cancelRequested) return;
    task
      ..progress = 1
      ..isFinalizing = true;
    notifyListeners();
  }

  bool cancel(String id) {
    final task = _tasks[id];
    if (task == null || !task.canCancel) return false;
    task.cancelRequested = true;
    task.cancellationToken.cancel();
    notifyListeners();
    return true;
  }

  void complete(String id) {
    if (_tasks.remove(id) != null) notifyListeners();
  }

  Future<T> run<T>(
    Future<T> Function() task, {
    UploadCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    if (_running >= maxConcurrent) {
      final waiter = _QueueWaiter();
      _waiters.add(waiter);
      if (cancellationToken != null) {
        unawaited(cancellationToken.whenCancelled.then((_) {
          if (_waiters.remove(waiter) && !waiter.ready.isCompleted) {
            waiter.ready.completeError(const UploadCancelledException());
          }
        }));
      }
      // The active task transfers its slot to this waiter on completion.
      await waiter.ready.future;
    } else {
      _running++;
    }

    try {
      cancellationToken?.throwIfCancelled();
      return await task();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().ready.complete();
      } else {
        _running--;
      }
    }
  }
}
