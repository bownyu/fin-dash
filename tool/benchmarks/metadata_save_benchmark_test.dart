import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';

// Isolate storage work from the UI-side prepare/publish cost.
class _Sink implements MetadataWalletStorage {
  @override
  Future<WalletData?> loadSnapshot() async => null;
  @override
  Future<String?> load() async => null;
  @override
  Future<void> save(String data) async {}
  @override
  Future<void> commitSnapshot(WalletData previous, WalletData next) async {}
  @override
  Future<void> commitMetadata(WalletData previous, WalletData next) async {}
  @override
  Future<void> replaceSnapshot(WalletData next) async {}
}

void main() {
  test('UI metadata append with 2000 tool-heavy messages', () async {
    final store = WalletStore(_Sink());
    await store.initialize();
    await store.changeMetadata((d) {
      d.chats.addAll([
        for (var i = 0; i < 2000; i++)
          {
            'id': '$i',
            'role': 'assistant',
            'blocks': [
              for (var j = 0; j < 3; j++)
                {'type': 'tool', 'result': List.filled(8192, 'x').join()},
            ],
          },
      ]);
    });
    final samples = <int>[];
    for (var i = 0; i < 7; i++) {
      final watch = Stopwatch()..start();
      await store.changeMetadata(
        (d) => d.chats.add({'id': 'new-$i', 'role': 'user', 'content': '你好'}),
      );
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    // ignore: avoid_print
    print('UI metadata append median=${samples[3]}us (2000 x 3 x 8KB)');
    expect(store.data.chats.length, 2007);
  });
}
