import 'dart:async';
import 'dart:isolate';
import '../domain/query_contracts.dart';

/// Computation owns its isolate, so cancelling never interrupts a ledger commit.
Future<R> executeRecipe<P, R>(
  FutureOr<R> Function(P) operation,
  P payload, {
  bool Function()? cancelled,
}) async {
  if (cancelled?.call() == true) {
    throw const ErrorEnvelope(ErrorCode.cancelled, '查询已停止');
  }
  final result = Completer<R>(),
      replies = ReceivePort(),
      errors = ReceivePort();
  Isolate? worker;
  Timer? cancelTimer;
  replies.listen((message) {
    if (result.isCompleted) return;
    if (message == null) {
      result.completeError(StateError('分析计算已退出'));
      return;
    }
    final (value, error, stack) = message as (dynamic, Object?, StackTrace?);
    if (error == null) {
      result.complete(value as R);
    } else {
      result.completeError(error, stack);
    }
  });
  errors.listen((error) {
    if (!result.isCompleted) result.completeError(StateError('分析计算失败：$error'));
  });
  try {
    worker = await Isolate.spawn(
      _compute,
      (replies.sendPort, operation, payload),
      onError: errors.sendPort,
      onExit: replies.sendPort,
      debugName: 'ledger-recipe',
    );
    if (cancelled != null) {
      cancelTimer = Timer.periodic(const Duration(milliseconds: 30), (_) {
        if (!result.isCompleted && cancelled()) {
          result.completeError(
            const ErrorEnvelope(ErrorCode.cancelled, '查询已停止'),
          );
          worker?.kill(priority: Isolate.immediate);
        }
      });
    }
    return await result.future;
  } finally {
    cancelTimer?.cancel();
    worker?.kill(priority: Isolate.immediate);
    replies.close();
    errors.close();
  }
}

void _compute((SendPort, Function, dynamic) request) async {
  final (reply, operation, payload) = request;
  try {
    reply.send((await Function.apply(operation, [payload]), null, null));
  } catch (error, stack) {
    reply.send((null, error, stack));
  }
}
