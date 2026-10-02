// Run explicitly: flutter test tool/benchmarks/wallet_save_benchmark_test.dart
// Desktop CPU observations only; not an Android frame-rate benchmark.
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/backup.dart';
import 'package:fin_dash/data/wallet_codec.dart';
import 'package:fin_dash/domain/models.dart';

void main() {
  test('compare 10000-record clone and encode paths', () async {
    final data = WalletData(
      transactions: [
        for (var i = 0; i < 10000; i++)
          LedgerTx(
            id: '$i',
            title: '午餐 $i',
            amount: 1250,
            date: DateTime(2026, 10, 2),
            type: TxType.expense,
            category: '餐饮',
          ),
      ],
    );
    WalletData oldClone() =>
        WalletData.fromJson(jsonDecode(jsonEncode(data.toJson())));
    oldClone();
    data.clone(); // Warm both paths.
    final oldTimes = <int>[], newTimes = <int>[];
    for (var i = 0; i < 5; i++) {
      var watch = Stopwatch()..start();
      final old = oldClone();
      oldTimes.add(watch.elapsedMicroseconds);
      watch = Stopwatch()..start();
      final copy = data.clone();
      newTimes.add(watch.elapsedMicroseconds);
      expect(copy.toJson(), old.toJson());
    }
    oldTimes.sort();
    newTimes.sort();
    final syncWatch = Stopwatch()..start();
    validateWallet(data);
    final expected = jsonEncode(data.toJson());
    final syncUs = syncWatch.elapsedMicroseconds;
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    final asyncWatch = Stopwatch()..start();
    late String encoded;
    try {
      encoded = await encodeWalletSnapshot(data);
    } finally {
      timer.cancel();
    }
    final asyncUs = asyncWatch.elapsedMicroseconds;
    expect(encoded, expected);
    // ignore: avoid_print
    print(
      '10000 records: clone median old=${oldTimes[2]}us new=${newTimes[2]}us; '
      'validate+encode sync=${syncUs}us workerWall=${asyncUs}us; UI-isolate timer ticks=$ticks',
    );
  });
}
