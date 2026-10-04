import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_sqlite.dart';
import 'package:fin_dash/data/storage_native.dart' as legacy;
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';

void main() {
  test('compare durable append of one transaction to 10000 records', () async {
    final root = await Directory.systemTemp.createTemp('findash-save-bench-');
    try {
      final stores = [
        WalletStore(
          legacy.LocalWalletStorage(directory: Directory('${root.path}/json')),
        ),
        WalletStore(
          LocalWalletStorage(directory: Directory('${root.path}/sqlite')),
        ),
      ];
      for (final store in stores) {
        await store.initialize();
        await store.change((d) {
          d.accounts.add(
            const WalletAccount(
              id: 'bank',
              name: '银行',
              category: 'funds',
              subType: 'bank_card',
            ),
          );
          d.settings['quickEntryAccountId'] = 'bank';
          d.transactions.addAll([
            for (var i = 0; i < 10000; i++)
              LedgerTx(
                id: '$i',
                title: '午餐',
                amount: 1000,
                date: DateTime(2026, 10, 2),
                type: TxType.expense,
                category: '餐饮',
                accountId: 'bank',
              ),
          ]);
        });
      }
      final times = <List<int>>[];
      for (final store in stores) {
        final samples = <int>[];
        for (var i = 0; i < 5; i++) {
          final watch = Stopwatch()..start();
          await store.saveTx(
            LedgerTx(
              id: 'new-$i',
              title: '晚餐',
              amount: 2000,
              date: DateTime(2026, 10, 2),
              type: TxType.expense,
              category: '餐饮',
              accountId: 'bank',
            ),
          );
          samples.add(watch.elapsedMicroseconds);
        }
        samples.sort();
        times.add(samples);
      }
      expect((stores.last.storage as LocalWalletStorage).lastChangedRows, 2);
      // ignore: avoid_print
      print(
        '10000 records durable append median: JSON=${times[0][2]}us SQLite=${times[1][2]}us; changed rows=2 (transaction and ledger revision)',
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
