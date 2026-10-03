import '../data/wallet_store.dart';
import '../domain/models.dart';

/// Keeps the existing agent.memories format, including imported legacy fields.
class AgentMemory {
  final WalletStore store;
  AgentMemory(this.store);
  static String fact(Json item) =>
      '${item['fact'] ?? item['description'] ?? ''}'.trim();
  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  List<Json> search(String query, {int limit = 12, int maxChars = 6000}) {
    final terms = <String>{};
    final normalized = _normalize(query);
    terms.addAll(
      RegExp(r'[a-z0-9]+').allMatches(normalized).map((m) => m.group(0)!),
    );
    for (var i = 0; i < normalized.length - 1; i++) {
      terms.add(normalized.substring(i, i + 2));
    }
    final items = (store.data.agent['memories'] as List? ?? [])
        .whereType<Map>()
        .map((m) => Json.from(m))
        .where((m) => fact(m).isNotEmpty)
        .toList();
    int score(Json item) {
      final value = _normalize(fact(item));
      final relevant = terms.where(value.contains).length;
      return relevant * 10 +
          switch (item['importance']) {
            'core' => 8,
            'high' => 4,
            'low' => 0,
            _ => 2,
          };
    }

    items.sort((a, b) {
      final byScore = score(b).compareTo(score(a));
      return byScore != 0
          ? byScore
          : '${b['updatedAt'] ?? b['sourceTimestamp'] ?? ''}'.compareTo(
              '${a['updatedAt'] ?? a['sourceTimestamp'] ?? ''}',
            );
    });
    final result = <Json>[], seen = <String>{};
    var length = 0;
    for (final item in items) {
      final text = fact(item);
      if (!seen.add(_normalize(text))) continue;
      if (length + text.length > maxChars) continue;
      result.add({...item, 'fact': text});
      length += text.length;
      if (result.length >= limit) break;
    }
    return result;
  }

  Future<Json> save(
    Json args, {
    String? sourceMessageId,
    bool update = false,
  }) async {
    final text = args['fact'];
    if (text is! String || text.trim().isEmpty || text.length > 2000) {
      throw const FormatException('记忆内容须为 1 至 2000 个字符');
    }
    final importance = args['importance'];
    if (importance != null &&
        !['core', 'high', 'medium', 'low'].contains(importance)) {
      throw const FormatException('记忆重要性无效');
    }
    Json? saved;
    var deduplicated = false;
    await store.changeMetadata((d) {
      final items = List<dynamic>.from(d.agent['memories'] ?? []);
      var index = update
          ? items.indexWhere((m) => m is Map && m['id'] == args['id'])
          : -1;
      if (update && (args['id'] is! String || index < 0)) {
        throw const FormatException('记忆不存在，请先查询');
      }
      final duplicate = items.indexWhere(
        (m) => m is Map && _normalize(fact(Json.from(m))) == _normalize(text),
      );
      if (!update && duplicate >= 0) {
        index = duplicate;
        deduplicated = true;
      }
      if (update && duplicate >= 0 && duplicate != index) {
        throw const FormatException('相同事实已存在，请删除重复记忆');
      }
      final old = index < 0 ? <String, dynamic>{} : Json.from(items[index]);
      saved = {
        ...old,
        'id': old['id'] ?? newId(),
        'fact': text.trim(),
        if (old.containsKey('description')) 'description': text.trim(),
        'importance': importance ?? old['importance'] ?? 'medium',
        'sourceTimestamp':
            old['sourceTimestamp'] ?? DateTime.now().millisecondsSinceEpoch,
        'updatedAt': DateTime.now().toIso8601String(),
        'sourceMessageId': ?sourceMessageId,
      };
      if (index < 0) {
        items.add(saved);
      } else {
        items[index] = saved;
      }
      d.agent['memories'] = items;
      d.extras.remove('analysisCache');
      _event(
        d,
        update
            ? '修正一条记忆'
            : deduplicated
            ? '确认已有记忆'
            : '保存一条记忆',
      );
    });
    return {'saved': true, 'id': saved!['id'], 'deduplicated': deduplicated};
  }

  Future<Json> forget(String id) async {
    await store.changeMetadata((d) {
      final items = List<dynamic>.from(d.agent['memories'] ?? []);
      if (!items.any((m) => m is Map && m['id'] == id)) {
        throw const FormatException('记忆不存在');
      }
      items.removeWhere((m) => m is Map && m['id'] == id);
      d.agent['memories'] = items;
      d.extras.remove('analysisCache');
      _event(d, '删除一条记忆');
    });
    return {'deleted': true, 'id': id};
  }

  static void _event(WalletMetadata d, String title) {
    d.agent['events'] = [
      {
        'id': newId(),
        'title': title,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      ...List<dynamic>.from(d.agent['events'] ?? []),
    ].take(300).toList();
  }
}
