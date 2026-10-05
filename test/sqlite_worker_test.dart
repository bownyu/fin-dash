import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/sqlite_worker.dart';

String _echo(String value) => value;
String _error(String value) => throw FormatException(value);
String _exit(String value) => Isolate.exit();
void main() {
  test(
    'worker preserves errors and recovers after an unexpected exit',
    () async {
      final worker = SqliteWorker.shared;
      expect(await worker.run(_echo, 'ready'), 'ready');
      await expectLater(worker.run(_error, 'bad row'), throwsFormatException);
      await expectLater(worker.run(_exit, ''), throwsStateError);
      expect(await worker.run(_echo, 'restarted'), 'restarted');
    },
  );
}
