import 'dart:convert';
import '../data/wallet_store.dart';
import '../data/storage_base.dart';
import '../domain/models.dart';
import '../domain/query_contracts.dart';
import '../domain/ledger_input.dart';

/// One immutable logical snapshot per query/program. No database handle escapes.
class LedgerQueries {
  final WalletData data;
  final WalletStore? _store;
  final QuerySnapshot snapshot;
  LedgerQueries(WalletStore store)
    : _store = store,
      data = store.data,
      snapshot = QuerySnapshot(store.ledgerEpoch, store.ledgerRevision);

  LedgerQueries._(this.data, this.snapshot) : _store = null;

  Future<QueryResult<Json>> queryAsync(
    Json args, {
    bool aggregate = false,
  }) async {
    final store = _store, backend = _store?.storage;
    if (backend is! QueryWalletStorage) {
      return query(args, aggregate: aggregate);
    }
    final validated = LedgerQueries._(
      WalletData(accounts: [], transactions: [], categories: []),
      snapshot,
    ).query(args, aggregate: aggregate);
    final offset = args['cursor'] == null
        ? 0
        : jsonDecode(utf8.decode(base64Url.decode(args['cursor'])))['offset']
              as int;
    final limit = args['limit'] ?? 50;
    final result = await (backend as QueryWalletStorage).queryRecords({
      ...args,
      'startInclusive': validated.scope.range?.start.toIso8601String(),
      'endExclusive': validated.scope.range?.end.toIso8601String(),
      'offset': offset,
      'limit': limit,
      'aggregate': aggregate,
    });
    if (store!.ledgerEpoch != snapshot.ledgerEpoch ||
        store.ledgerRevision != snapshot.revision) {
      throw const ErrorEnvelope(ErrorCode.snapshotExpired, '查询期间账本已变化，请重新查询');
    }
    final count = result['transactionCount'] as int,
        page = result['transactions'] as List;
    checkedCents(result['expenseCents']);
    checkedCents(result['incomeCents']);
    final more = !aggregate && offset + page.length < count;
    return QueryResult(
      data: aggregate
          ? {
              'expenseCents': result['expenseCents'],
              'incomeCents': result['incomeCents'],
              'transactionCount': count,
            }
          : {'transactions': page.map((t) => {...Json.from(t),'currency':'CNY'}).toList()},
      scope: validated.scope,
      snapshot: snapshot,
      matchedRows: count,
      returnedRows: aggregate ? 1 : page.length,
      status: more ? 'partial' : 'complete',
      partialReason: more ? 'pagination' : null,
      nextCursor: more
          ? base64Url.encode(
              utf8.encode(
                jsonEncode({
                  'epoch': snapshot.ledgerEpoch,
                  'revision': snapshot.revision,
                  'offset': offset + page.length,
                  'filter': jsonEncode(
                    {...args}
                      ..remove('cursor')
                      ..remove('limit'),
                  ),
                }),
              ),
            )
          : null,
    );
  }

  static const transactionFields = <String, String>{
    'id': 'ID',
    'title': 'String',
    'type': 'String',
    'amountCents': 'Cents',
    'currency': 'String',
    'occurredAt': 'Instant',
    'timePrecision': 'String',
    'accountId': 'ID',
    'transferFromId': 'ID',
    'transferToId': 'ID',
    'categoryId': 'ID',
    'category': 'String',
    'sourceType': 'String',
    'sourceId': 'ID',
    'originalTransactionId': 'ID',
    'note': 'String',
  };
  static const datasets = <String, Map<String, String>>{
    'ledger.transactions': transactionFields,
    'ledger.accounts': {
      'id': 'ID',
      'name': 'String',
      'category': 'String',
      'openingBalanceCents': 'Cents',
      'balanceCents': 'Cents',
      'archived': 'Bool',
      'includeInTotal': 'Bool',
    },
    'ledger.categories': {'id': 'ID', 'name': 'String', 'type': 'String'},
    'ledger.budgets': {
      'id': 'ID',
      'period': 'String',
      'amountCents': 'Cents',
      'currency': 'String',
    },
  };
  Iterable<Json> rows(String dataset) sync* {
    switch (dataset) {
      case 'ledger.transactions':
        for (final t in data.transactions) {
          yield {
            ...t.toJson(),
            'occurredAt': t.date.toIso8601String(),
            'currency': 'CNY',
          };
        }
      case 'ledger.accounts':
        final effects = <String, int>{};
        for (final t in data.transactions) {
          for (final id in {
            t.accountId,
            t.fromId,
            t.toId,
          }.whereType<String>()) {
            effects[id] = checkedCents((effects[id] ?? 0) + t.effectOn(id));
          }
        }
        for (final a in data.accounts) {
          yield {
            'id': a.id,
            'name': a.name,
            'category': a.category,
            'openingBalanceCents': a.openingBalance,
            'balanceCents': checkedCents(
              a.openingBalance + (effects[a.id] ?? 0),
            ),
            'archived': a.archived,
            'includeInTotal': a.includeInTotal,
          };
        }
      case 'ledger.categories':
        for (final c in data.categories) {
          yield {'id': c.id, 'name': c.name, 'type': c.type.name};
        }
      case 'ledger.budgets':
        yield {
          'id': 'monthly',
          'period': 'month',
          'amountCents': data.settings['budget'] ?? 0,
          'currency': 'CNY',
        };
      default:
        throw const ErrorEnvelope(ErrorCode.forbidden, '此数据集不可访问');
    }
  }

  QueryResult<Json> query(Json args, {bool aggregate = false}) {
    final start = args['startInclusive'], end = args['endExclusive'];
    if ((start == null) != (end == null)) {
      throw const FormatException('请同时提供起止日期');
    }
    final range = start == null
        ? null
        : DateRange(parseLedgerDate(start), parseLedgerDate(end));
    if (range != null && !range.start.isBefore(range.end)) {
      throw const FormatException('结束日期必须晚于开始日期');
    }
    final scope = QueryScope(
      range: range,
      metric: aggregate ? 'expenseGross/incomeGross' : 'recordedTransactions',
    );
    var offset = 0;
    if (args['cursor'] != null) {
      try {
        final cursor = jsonDecode(
          utf8.decode(base64Url.decode(args['cursor'])),
        );
        if (cursor['epoch'] != snapshot.ledgerEpoch ||
            cursor['revision'] != snapshot.revision ||
            cursor['filter'] !=
                jsonEncode(
                  {...args}
                    ..remove('cursor')
                    ..remove('limit'),
                )) {
          throw const ErrorEnvelope(
            ErrorCode.snapshotExpired,
            '账本或查询范围已变化，请重新查询',
          );
        }
        offset = cursor['offset'] as int;
        if (offset < 0) throw const FormatException('无效游标');
      } on ErrorEnvelope {
        rethrow;
      } catch (_) {
        throw const FormatException('无效游标');
      }
    }
    final limit = args['limit'] ?? 50;
    if (limit is! int || limit < 1 || limit > 200) {
      throw const FormatException('每页须为 1 至 200 条');
    }
    final selected =
        data.transactions
            .where(
              (t) =>
                  (range == null || range.contains(t.date)) &&
                  (args['type'] == null || t.type.name == args['type']) &&
                  (args['categoryId'] == null ||
                      t.categoryId == args['categoryId']) &&
                  (args['accountId'] == null ||
                      [
                        t.accountId,
                        t.fromId,
                        t.toId,
                      ].contains(args['accountId'])),
            )
            .toList()
          ..sort((a, b) {
            final order = b.date.compareTo(a.date);
            return order == 0 ? a.id.compareTo(b.id) : order;
          });
    var expense = 0, income = 0;
    for (final t in selected) {
      if (t.type == TxType.expense) expense = checkedCents(expense + t.amount);
      if (t.type == TxType.income) income = checkedCents(income + t.amount);
    }
    final page = aggregate
        ? <Json>[]
        : selected
              .skip(offset)
              .take(limit)
              .map((t) => {...t.toJson(), 'currency': 'CNY'})
              .toList();
    final more = !aggregate && offset + page.length < selected.length;
    return QueryResult(
      data: aggregate
          ? {
              'expenseCents': expense,
              'incomeCents': income,
              'transactionCount': selected.length,
            }
          : {'transactions': page},
      scope: scope,
      snapshot: snapshot,
      matchedRows: selected.length,
      returnedRows: aggregate ? 1 : page.length,
      status: more ? 'partial' : 'complete',
      partialReason: more ? 'pagination' : null,
      nextCursor: more
          ? base64Url.encode(
              utf8.encode(
                jsonEncode({
                  'epoch': snapshot.ledgerEpoch,
                  'revision': snapshot.revision,
                  'offset': offset + page.length,
                  'filter': jsonEncode(
                    {...args}
                      ..remove('cursor')
                      ..remove('limit'),
                  ),
                }),
              ),
            )
          : null,
    );
  }
}
