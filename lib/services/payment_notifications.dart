import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/ledger_operations.dart';

class PaymentAcceptance {
  final String eventId;
  final LedgerTx transaction;
  const PaymentAcceptance(this.eventId, this.transaction);
}

abstract class NotificationBridge {
  bool get supported;
  Future<dynamic> call(String method, [Json? arguments]);
}

class AndroidNotificationBridge implements NotificationBridge {
  static const _channel = MethodChannel('findash/payment_notifications');
  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  @override
  Future<dynamic> call(String method, [Json? arguments]) => _channel
      .invokeMethod(method, arguments)
      .timeout(const Duration(seconds: 15));
}

class PaymentNotifications {
  // The app lifecycle and review page use separate service instances.
  // Serialize their native peek / save / ACK and clear operations per ledger.
  static final _tails = Expando<Future<void>>();
  final WalletStore store;
  final NotificationBridge bridge;
  List? _pendingIndexRecords;
  List<LedgerTx>? _ledgerIndexTransactions;
  int _indexedTransactionCount = -1;
  Set<String> _duplicatePendingIds = {};
  Map<String, List<LedgerTx>> _ledgerBuckets = {};
  PaymentNotifications(this.store, {NotificationBridge? bridge})
    : bridge = bridge ?? AndroidNotificationBridge();
  bool get supported => bridge.supported;
  static final _recordsCache = Expando<List<Json>>();
  static final _pendingCache = Expando<List<Json>>();
  List<Json> get records {
    final raw = store.data.extras['paymentNotifications'] as List?;
    if (raw == null) return const [];
    return _recordsCache[raw] ??= List.unmodifiable(raw.cast<Json>().reversed);
  }

  List<Json> get pending => _pendingRecords(store.data);
  static List<Json> _pendingRecords(WalletData data) {
    final raw = data.extras['paymentNotifications'] as List?;
    if (raw == null) return const [];
    return _pendingCache[raw] ??= List.unmodifiable(
      raw.cast<Json>().reversed.where((r) => r['status'] == 'pending'),
    );
  }

  static int pendingCount(WalletData data) => _pendingRecords(data).length;
  static List<Json> _records(WalletData d) =>
      (d.extras['paymentNotifications'] as List? ?? []).cast<Json>();

  Future<Json> status() async => supported
      ? Json.from(await bridge.call('status') as Map)
      : {'supported': false};
  Future<void> _serial(Future<void> Function() action) {
    final work = (_tails[store] ?? Future<void>.value()).then((_) => action());
    _tails[store] = work.catchError((Object _) {});
    return work;
  }

  Future<void> setEnabled(bool enabled) => _serial(() async {
    await bridge.call('setEnabled', {'enabled': enabled});
  });

  Future<void> openSettings() async {
    await bridge.call('openSettings');
  }

  Future<void> openBatterySettings() async {
    await bridge.call('openBatterySettings');
  }

  Future<void> openAppSettings() async {
    await bridge.call('openAppSettings');
  }

  Future<void> reconnect() async {
    if (!supported) return;
    await bridge.call('reconnect');
  }

  Future<void> sync() => _serial(() async {
    if (!supported || store.loading || store.startupError != null) {
      return;
    }
    // Native pages are also bounded by IPC size; allow the full 1000-event inbox.
    for (var page = 0; page < 100; page++) {
      final batch = (await bridge.call('peek') as List)
          .map((e) => Json.from(e as Map))
          .toList();
      if (batch.isEmpty) return;
      await ingest(batch);
      // A crash before ACK safely replays the same IDs on the next launch.
      await bridge.call('ack', {
        'ids': batch.map((e) => e['eventId']).toList(),
      });
    }
  });

  Future<void> ingest(
    List<Json> events, {
    bool ignore = false,
  }) => store.change((d) {
    final records = _records(d);
    final ids = records.map((e) => e['eventId']).toSet();
    var pending = records.where((r) => r['status'] == 'pending').length;
    final byAmount = <(String, int), List<int>>{};
    for (final record in records) {
      if (record['amountCents'] is int) {
        (byAmount[(
                  record['sourcePackage'] as String,
                  record['amountCents'] as int,
                )] ??=
                [])
            .add(record['postedAt'] as int);
      }
    }
    for (final e in events) {
      if (e['eventId'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(e['eventId']) ||
          ![
            'com.tencent.mm',
            'com.eg.android.AlipayGphone',
          ].contains(e['sourcePackage']) ||
          e['postedAt'] is! int ||
          e['postedAt'] <= 0 ||
          e['postedAt'] > 8640000000000000 ||
          e['text'] is! String ||
          (e['text'] as String).length > 4096 ||
          e['title'] is! String ||
          (e['title'] as String).length > 200 ||
          ![
            'expense',
            'income',
            'transfer',
            'repayment',
            'refund',
            'unknown',
          ].contains(e['kind']) ||
          (e['amountCents'] != null &&
              (e['amountCents'] is! int ||
                  e['amountCents'] <= 0 ||
                  e['amountCents'] > 999999999999))) {
        throw const FormatException('通知数据不完整，已保留原生收件箱供重试');
      }
      if (!ids.add(e['eventId'])) continue;
      if (!ignore && pending >= 2000) {
        throw const FormatException('待确认通知已达 2000 条，请先处理');
      }
      final possibleDuplicate =
          e['amountCents'] != null &&
          (byAmount[(e['sourcePackage'] as String, e['amountCents'] as int)] ??
                  const <int>[])
              .any((time) => (time - (e['postedAt'] as int)).abs() <= 120000);
      records.add({
        'eventId': e['eventId'],
        'sourcePackage': e['sourcePackage'],
        'notificationKey': e['notificationKey'],
        'postedAt': e['postedAt'],
        'title': ignore ? '' : e['title'],
        'text': ignore ? '' : e['text'],
        'amountCents': e['amountCents'],
        'kind': e['kind'],
        'merchant': e['merchant'] is String ? e['merchant'] : '',
        'reviewReason': e['reviewReason'] is String
            ? e['reviewReason']
            : '请核对交易信息',
        'ruleVersion': e['ruleVersion'],
        'status': ignore ? 'ignored' : 'pending',
        'cleared': ignore,
        'possibleDuplicate': possibleDuplicate,
      });
      if (!ignore) pending++;
      if (e['amountCents'] is int) {
        (byAmount[(e['sourcePackage'] as String, e['amountCents'] as int)] ??=
                [])
            .add(e['postedAt'] as int);
      }
    }
    _compactProcessed(records);
    d.extras['paymentNotifications'] = records;
  });

  // Keep durable IDs, amounts and refund links; bound retained notification text.
  static void _compactProcessed(List<Json> records) {
    var recent = 0;
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 30))
        .millisecondsSinceEpoch;
    for (var i = records.length - 1; i >= 0; i--) {
      final record = records[i];
      if (record['status'] == 'pending') continue;
      if (++recent <= 500 && (record['postedAt'] as int? ?? 0) >= cutoff) {
        continue;
      }
      if (record['text'] != '' || record['title'] != '') {
        record['text'] = '';
        record['title'] = '';
        record['cleared'] = true;
      }
    }
  }

  Future<void> accept(
    String eventId,
    LedgerTx tx, {
    bool duplicateReviewed = false,
    String? refundOf,
  }) => store.change((d) {
    final records = _records(d);
    _apply(
      d,
      records,
      eventId,
      tx,
      duplicateReviewed: duplicateReviewed,
      refundOf: refundOf,
    );
    d.extras['paymentNotifications'] = records;
  });

  /// Batch confirmation is one durable ledger write, revalidated at commit time.
  Future<int> acceptMany(List<PaymentAcceptance> items) async {
    if (items.isEmpty) throw const FormatException('请先选择待确认记录');
    if (items.map((i) => i.eventId).toSet().length != items.length) {
      throw const FormatException('同一条通知不能重复选择');
    }
    var count = 0;
    await store.change((d) {
      final records = _records(d);
      final byId = {for (final record in records) record['eventId']: record};
      final transactions = <LedgerTx>[];
      final txIds = d.transactions.map((t) => t.id).toSet();
      final checked = <PaymentAcceptance>[];
      for (final item in items) {
        final record = byId[item.eventId];
        if (record == null) throw const FormatException('通知记录不存在，请刷新后重试');
        if (record['status'] == 'applied') continue;
        final problem = batchProblem(record, data: d);
        if (problem != null) throw FormatException('$problem，请逐笔核对');
        if (item.transaction.amount != record['amountCents'] ||
            item.transaction.type.name != record['kind'] ||
            item.transaction.date.millisecondsSinceEpoch !=
                record['postedAt'] ||
            item.transaction.title.trim() !=
                (record['merchant'] as String).trim()) {
          throw const FormatException('批量账单与原通知不一致，请逐笔核对');
        }
        checked.add(item);
      }
      // Every candidate is checked before any transaction in this batch is added.
      for (final item in checked) {
        _apply(
          d,
          records,
          item.eventId,
          item.transaction,
          duplicateReviewed: true,
          record: byId[item.eventId],
          transactionIds: txIds,
          deferredTransactions: transactions,
        );
        count++;
      }
      LedgerOperations.appendTransactions(d, transactions);
      _compactProcessed(records);
      d.extras['paymentNotifications'] = records;
    });
    return count;
  }

  bool needsDuplicateReview(
    Json record, {
    LedgerTx? transaction,
    WalletData? data,
  }) {
    final ledger = data ?? store.data;
    final amount = transaction?.amount ?? record['amountCents'];
    final date =
        transaction?.date ??
        DateTime.fromMillisecondsSinceEpoch(record['postedAt']);
    final rawRecords = ledger.extras['paymentNotifications'] as List?;
    if (!identical(_pendingIndexRecords, rawRecords)) {
      _pendingIndexRecords = rawRecords;
      _duplicatePendingIds = {};
      final groups = <int, List<Json>>{};
      for (final r in _records(ledger).where((r) => r['status'] == 'pending')) {
        if (r['possibleDuplicate'] == true) {
          _duplicatePendingIds.add(r['eventId']);
        }
        if (r['amountCents'] is int) (groups[r['amountCents']] ??= []).add(r);
      }
      for (final group in groups.values) {
        group.sort((a, b) => (a['postedAt'] as int).compareTo(b['postedAt']));
        for (var i = 1; i < group.length; i++) {
          if ((group[i]['postedAt'] as int) -
                  (group[i - 1]['postedAt'] as int) <=
              120000) {
            _duplicatePendingIds.addAll([
              group[i]['eventId'],
              group[i - 1]['eventId'],
            ]);
          }
        }
      }
    }
    if (!identical(_ledgerIndexTransactions, ledger.transactions) ||
        _indexedTransactionCount != ledger.transactions.length) {
      _ledgerIndexTransactions = ledger.transactions;
      _indexedTransactionCount = ledger.transactions.length;
      _ledgerBuckets = {};
      for (final tx in ledger.transactions) {
        final key = '${tx.amount}|${tx.date.millisecondsSinceEpoch ~/ 120000}';
        (_ledgerBuckets[key] ??= []).add(tx);
      }
    }
    if (_duplicatePendingIds.contains(record['eventId'])) return true;
    final time = date.millisecondsSinceEpoch ~/ 120000;
    for (var i = time - 1; i <= time + 1; i++) {
      if ((_ledgerBuckets['$amount|$i'] ?? const <LedgerTx>[]).any(
        (t) => t.date.difference(date).inMilliseconds.abs() <= 120000,
      )) {
        return true;
      }
    }
    return false;
  }

  String? batchProblem(Json record, {WalletData? data}) {
    if (record['status'] != 'pending') return '这条通知已处理';
    if (!['expense', 'income'].contains(record['kind'])) {
      return record['kind'] == 'refund' ? '退款需要核对原账单' : '交易类型需要核对';
    }
    if (record['amountCents'] is! int || record['amountCents'] <= 0) {
      return '金额需要补全';
    }
    if (record['merchant'] is! String ||
        (record['merchant'] as String).trim().isEmpty) {
      return '用途需要补全';
    }
    if (needsDuplicateReview(record, data: data)) return '可能存在重复记录';
    return null;
  }

  void _apply(
    WalletData d,
    List<Json> records,
    String eventId,
    LedgerTx tx, {
    bool duplicateReviewed = false,
    String? refundOf,
    Json? record,
    Set<String>? transactionIds,
    List<LedgerTx>? deferredTransactions,
  }) {
    if (d.settings['locked'] == true) throw const FormatException('账本已锁定，请先解锁');
    record ??= records.firstWhere(
      (r) => r['eventId'] == eventId,
      orElse: () => throw const FormatException('通知记录不存在'),
    );
    if (record['status'] == 'applied') return;
    if (record['status'] != 'pending') throw const FormatException('通知已处理');
    if (record['kind'] == 'refund') {
      final original = d.transactions
          .where((t) => t.id == refundOf && t.type == TxType.expense)
          .firstOrNull;
      if (original == null || tx.type != TxType.income) {
        throw const FormatException('退款需人工关联原支出并核对实际到账，不会自动计入收入');
      }
      final refunded = records
          .where((r) => r['status'] == 'applied' && r['refundOf'] == refundOf)
          .fold<int>(0, (sum, r) {
            final previous = d.transactions
                .where((t) => t.id == r['transactionId'])
                .firstOrNull;
            return sum + (previous?.amount ?? 0);
          });
      if (tx.date.isBefore(original.date) ||
          tx.amount <= 0 ||
          tx.amount + refunded > original.amount) {
        throw const FormatException('退款时间不能早于原交易，累计退款不能超过原支出');
      }
      if (!d.categories.any((c) => c.type == TxType.income && c.name == '退款')) {
        d.categories.add(
          WalletCategory(
            newId(),
            '退款',
            'currency_exchange',
            '#58C5AB',
            TxType.income,
          ),
        );
      }
      tx = LedgerTx.fromJson({
        ...tx.toJson(),
        'category': '退款',
        'icon': 'currency_exchange',
      });
    }
    if (!duplicateReviewed &&
        needsDuplicateReview(record, transaction: tx, data: d)) {
      throw const FormatException('存在金额和时间相近的记录，请确认不是重复账单');
    }
    if (transactionIds != null
        ? !transactionIds.add(tx.id)
        : d.transactions.any((t) => t.id == tx.id)) {
      throw const FormatException('账单 ID 已存在');
    }
    if (tx.type == TxType.transfer && tx.fromId == tx.toId) {
      throw const FormatException('转入转出账户不能相同');
    }
    for (final id
        in tx.type == TxType.transfer ? [tx.fromId, tx.toId] : [tx.accountId]) {
      if (!d.accounts.any((a) => a.id == id && !a.archived)) {
        throw const FormatException('请选择有效账户');
      }
    }
    tx = LedgerTx.fromJson({
      ...tx.toJson(),
      'sourceType': 'notification',
      'sourceId': eventId,
      if (record['kind'] == 'refund') 'originalTransactionId': refundOf,
    });
    if (deferredTransactions != null) {
      deferredTransactions.add(tx);
    } else {
      LedgerOperations.putTransaction(d, tx, mode: TransactionWrite.insert);
    }
    record['status'] = 'applied';
    record['transactionId'] = tx.id;
    if (record['kind'] == 'refund') record['refundOf'] = refundOf;
    record['processedAt'] = DateTime.now().toIso8601String();
    d.extras.remove('analysisCache');
  }

  Set<String> get reminderSeen =>
      ((store.data.extras['paymentReminderSeen'] as List?) ?? [])
          .whereType<String>()
          .toSet();
  Future<void> markReminderSeen(Set<String> ids) => store.change((d) {
    final pendingIds = _records(
      d,
    ).where((r) => r['status'] == 'pending').map((r) => r['eventId']).toSet();
    final previous = ((d.extras['paymentReminderSeen'] as List?) ?? [])
        .whereType<String>();
    d.extras['paymentReminderSeen'] = {
      ...previous,
      ...ids,
    }.where(pendingIds.contains).toList();
  });

  Future<void> dismiss(String eventId) => store.change((d) {
    final records = _records(d);
    final record = records.firstWhere((r) => r['eventId'] == eventId);
    if (record['status'] != 'pending') return;
    record['status'] = 'ignored';
    record['processedAt'] = DateTime.now().toIso8601String();
    d.extras['paymentNotifications'] = records;
  });

  Future<void> restoreIgnored(String eventId) => store.change((d) {
    final records = _records(d);
    final record = records.where((r) => r['eventId'] == eventId).firstOrNull;
    if (record == null ||
        record['status'] != 'ignored' ||
        record['cleared'] == true) {
      throw const FormatException('这条通知不能恢复，请手动核对账单');
    }
    record['status'] = 'pending';
    record.remove('processedAt');
    d.extras['paymentNotifications'] = records;
    final seen = List<String>.from(d.extras['paymentReminderSeen'] ?? []);
    seen.remove(eventId);
    d.extras['paymentReminderSeen'] = seen;
  });

  Future<void> clearIgnored() => store.change((d) {
    final records = _records(d);
    for (final record in records.where((r) => r['status'] == 'ignored')) {
      record['text'] = '';
      record['title'] = '';
      record['cleared'] = true;
    }
    d.extras['paymentNotifications'] = records;
  });

  Future<void> clearPending() => _serial(() async {
    if (supported) {
      await bridge.call('setEnabled', {'enabled': false});
      // Clearing also works when the review queue is full. Preserve IDs before ACK.
      for (var page = 0; page < 100; page++) {
        final batch = (await bridge.call('peek') as List)
            .map((e) => Json.from(e as Map))
            .toList();
        if (batch.isEmpty) break;
        await ingest(batch, ignore: true);
        await bridge.call('ack', {
          'ids': batch.map((e) => e['eventId']).toList(),
        });
      }
      await bridge.call('clear');
    }
    await store.change((d) {
      final records = _records(d);
      for (final r in records.where((r) => r['status'] == 'pending')) {
        r['status'] = 'ignored';
        r['cleared'] = true;
        r['text'] = '';
        r['title'] = '';
      }
      d.extras['paymentNotifications'] = records;
    });
  });
}
