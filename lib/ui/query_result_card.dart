import 'package:flutter/material.dart';
import '../domain/models.dart';
import 'design.dart';

/// All numbers come from a validated QueryResult, never from model HTML/JS.
class QueryResultCard extends StatelessWidget {
  final Json result;
  const QueryResultCard({super.key, required this.result});
  @override
  Widget build(BuildContext context) {
    final visible = AppScope.storeOf(context).data.settings['visible'] != false;
    final data = result['data'];
    final rows = data is List
        ? data.whereType<Map>().toList()
        : data is Map && data['transactions'] is List
        ? (data['transactions'] as List).whereType<Map>().toList()
        : <Map>[];
    final metrics = data is Map && data['transactions'] == null
        ? data
        : <String, dynamic>{};
    String display(String key, dynamic value) => value == null
        ? '—'
        : key.endsWith('Cents') && value is int
        ? (visible ? money(value) : '••••')
        : '$value';
    final labels = {
      'expenseCents': '支出',
      'incomeCents': '收入',
      'transactionCount': '账单数',
      'amountCents': '金额',
      'title': '用途',
      'category': '分类',
      'date': '日期',
      'type': '类型',
    };
    final columns = rows.isEmpty
        ? <String>[]
        : rows.first.keys
              .cast<String>()
              .where(
                (k) => ![
                  'id',
                  'icon',
                  'sourceId',
                  'accountId',
                  'transferFromId',
                  'transferToId',
                  'categoryId',
                  'originalTransactionId',
                ].contains(k),
              )
              .take(6)
              .toList();
    final scope = result['scope'] ?? {}, coverage = result['coverage'] ?? {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('查询结果', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(
              '${scope['currency'] ?? 'CNY'} · ${scope['startInclusive'] ?? '全部已记录数据'}${scope['endExclusive'] == null ? '' : ' 至 ${scope['endExclusive']}（不含）'}',
            ),
            if (coverage['status'] == 'partial')
              const Text('当前仅显示部分明细，不能用此页计算全部总额。'),
            for (final e in metrics.entries)
              Text('${labels[e.key] ?? e.key}：${display(e.key, e.value)}'),
            if (rows.isNotEmpty)
              SizedBox(
                height: rows.length < 5 ? (rows.length + 1) * 46.0 : 240,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: columns.length * 140.0,
                    child: ListView.builder(
                      itemCount: rows.length + 1,
                      itemBuilder: (context, index) => Row(
                        children: [
                          for (final key in columns)
                            SizedBox(
                              width: 140,
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  index == 0
                                      ? labels[key] ?? key
                                      : display(key, rows[index - 1][key]),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (rows.isEmpty && metrics.isEmpty) const Text('该范围没有匹配记录。'),
            for (final text in result['limitations'] as List? ?? [])
              Text('$text', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
