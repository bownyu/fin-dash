import 'dart:async';
import '../data/wallet_store.dart';

/// Small cancellable wait queue. Waiting never enters WalletStore's write tail.
class ModelQueue {
  final WalletStore store;
  final waiting = <String, Completer<void>>{};
  ModelQueue(this.store);
  Future<T> run<T>(String id, Future<T> Function() action) async {
    if (waiting.length >= 3 || waiting.containsKey(id)) {
      throw const FormatException('已有 3 条语音排队，文字草稿已保留');
    }
    final cancel = Completer<void>();
    waiting[id] = cancel;
    try {
      while (store.aiStatus != null || waiting.keys.first != id) {
        final ready = Completer<void>();
        void wake() {
          if (!ready.isCompleted) ready.complete();
        }

        store.runtimeUpdates.addListener(wake);
        try {
          await Future.any([ready.future, cancel.future]);
        } finally {
          store.runtimeUpdates.removeListener(wake);
        }
        if (cancel.isCompleted) throw const FormatException('本次解析已停止，文字草稿已保留');
      }
      if (cancel.isCompleted) throw const FormatException('本次解析已停止，文字草稿已保留');
      return await action();
    } finally {
      waiting.remove(id);
      store.refreshRuntime();
    }
  }

  void cancel(String id) {
    final value = waiting[id];
    if (value != null && !value.isCompleted) value.complete();
  }
}
