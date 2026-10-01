import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_native.dart';

void main() {
  test(
    'native writes persist and recover the previous verified snapshot',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'findash-storage-test-',
      );
      try {
        final storage = LocalWalletStorage(directory: dir);
        expect(await storage.load(), null);
        await storage.save('first');
        await storage.save('second');
        expect(await storage.load(), 'second');
        await File('${dir.path}/findash_ledger.json').writeAsString('{}');
        expect(await storage.load(), 'first');
        await storage.save('recovered');
        expect(await storage.load(), 'recovered');
        expect(
          await File('${dir.path}/findash_ledger.json.bak').readAsString(),
          seal('first'),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'corrupt primary and backup refuse to silently reset the ledger',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'findash-storage-test-',
      );
      try {
        await File('${dir.path}/findash_ledger.json').writeAsString('{}');
        await expectLater(
          LocalWalletStorage(directory: dir).load(),
          throwsFormatException,
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
