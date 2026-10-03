import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_sqlite.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/data/backup.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/application/ledger_queries.dart';
import 'package:fin_dash/services/ai_service.dart';
import '../../test/helpers.dart';

void main() {
  for (final count in [1000, 10000, 100000]) {
    test('$count synthetic records', () async {
      final dir = await Directory.systemTemp.createTemp(
        'findash-ai-benchmark-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final backend = LocalWalletStorage(directory: dir),
          store = WalletStore(backend);
      await store.initialize();
      final clock = Stopwatch()..start();
      await store.restore(
        ImportPreview(
          WalletData(
            accounts: [bank, cash, credit],
            transactions: [
              for (var i = 0; i < count; i++)
                tx(
                  id: 'row-$i',
                  amount: 100 + i % 10000,
                  date: DateTime(2026, 1, 1).add(Duration(minutes: i)),
                  type: i % 10 == 0
                      ? TxType.transfer
                      : i % 9 == 0
                      ? TxType.income
                      : TxType.expense,
                  from: i % 10 == 0 ? 'bank' : null,
                  to: i % 10 == 0 ? 'cash' : null,
                ),
            ],
          ),
          [],
          false,
        ),
      );
      final importMs = clock.elapsedMilliseconds;
      clock.reset();
      final reopened = WalletStore(LocalWalletStorage(directory: dir));
      await reopened.initialize();
      final startupMs = clock.elapsedMilliseconds;
      clock.reset();
      await AiService(store, TestVault()).newConversation();
      final chatMs = clock.elapsedMilliseconds,
          chatRows = backend.lastScannedRows;
      clock.reset();
      await store.saveTx(tx(id: 'one-new'));
      final saveMs = clock.elapsedMilliseconds,
          saveRows = backend.lastScannedRows;
      clock.reset();
      final result = await LedgerQueries(store).queryAsync({}, aggregate: true);
      final queryMs = clock.elapsedMilliseconds;
      expect(result.data['transactionCount'], count + 1);
      final bytes = await File('${dir.path}/findash_ledger.sqlite').length();
      // ignore: avoid_print
      print(
        jsonEncode({
          'mode': 'Flutter test / Windows / synthetic',
          'rows': count,
          'importMs': importMs,
          'startupMs': startupMs,
          'chatMs': chatMs,
          'chatScannedRows': chatRows,
          'saveMs': saveMs,
          'saveScannedRows': saveRows,
          'aggregateMs': queryMs,
          'databaseBytes': bytes,
          'rssBytes': ProcessInfo.currentRss,
          'maxRssBytes': ProcessInfo.maxRss,
        }),
      );
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
