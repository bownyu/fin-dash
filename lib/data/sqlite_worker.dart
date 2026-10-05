import 'dart:async';
import 'dart:isolate';

/// One sequential worker per isolate group client. Requests carry only deltas;
/// databases are closed after each operation so temporary files remain removable.
class SqliteWorker {
  static final shared = SqliteWorker();
  Isolate? _isolate;
  ReceivePort? _responses, _errors, _exits;
  Future<SendPort>? _starting;
  final _pending = <int, Completer<dynamic>>{};
  int _nextId = 0, _generation = 0;

  Future<SendPort> _start() => _starting ??= _spawn();
  Future<SendPort> _spawn() async {
    final generation = ++_generation;
    final ready = Completer<SendPort>();
    final responses = _responses = ReceivePort();
    final errors = _errors = ReceivePort();
    final exits = _exits = ReceivePort();
    void failed(Object error, [StackTrace? stack]) {
      if (generation != _generation) return;
      if (!ready.isCompleted) ready.completeError(error, stack);
      _fail(error, stack);
    }

    responses.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      final (id, value, error, stack) =
          message as (int, dynamic, Object?, StackTrace?);
      final pending = _pending.remove(id);
      if (pending == null) return;
      if (error != null) {
        pending.completeError(error, stack);
      } else {
        pending.complete(value);
      }
    });
    errors.listen(
      (message) =>
          failed(StateError('存储 worker 异常：${(message as List).first}')),
    );
    exits.listen((_) => failed(StateError('存储 worker 已退出，请重试')));
    try {
      _isolate = await Isolate.spawn(
        _serve,
        responses.sendPort,
        onError: errors.sendPort,
        onExit: exits.sendPort,
        debugName: 'wallet-sqlite',
      );
    } catch (error, stack) {
      failed(error, stack);
    }
    return ready.future;
  }

  void _fail(Object error, [StackTrace? stack]) {
    _generation++;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _starting = null;
    _responses?.close();
    _errors?.close();
    _exits?.close();
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      request.completeError(error, stack);
    }
  }

  Future<R> run<T, R>(FutureOr<R> Function(T) operation, T payload) async {
    final port = await _start().timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        final error = TimeoutException('存储 worker 启动超时');
        _fail(error);
        throw error;
      },
    );
    final id = _nextId++;
    final result = Completer<dynamic>();
    _pending[id] = result;
    try {
      port.send((id, operation, payload));
    } catch (error, stack) {
      _pending.remove(id);
      result.completeError(error, stack);
    }
    return (await result.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            final error = TimeoutException('存储请求超时，请重试');
            _fail(error);
            throw error;
          },
        ))
        as R;
  }
}

void _serve(SendPort responses) {
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  Future<void> tail = Future.value();
  requests.listen((message) {
    tail = tail.then((_) async {
      final (id, operation, payload) = message as (int, Function, dynamic);
      try {
        final result = await Function.apply(operation, [payload]);
        responses.send((id, result, null, null));
      } catch (error, stack) {
        responses.send((id, null, error, stack));
      }
    });
  });
}
