import 'dart:convert';
import '../domain/models.dart';

typedef RowKey = (String, String);
typedef RowEntry = ({Object? value, String kind});
String childBucket(String parent, String key) => jsonEncode([parent, key]);
const listFields = [
  'accounts',
  'transactions',
  'categories',
  'quickEntries',
  'goals',
  'chats',
];
const mapFields = ['profile', 'settings', 'agent', 'providerConfigs', 'extras'];
const financialBuckets = {
  'accounts',
  'transactions',
  'categories',
  'quickEntries',
};

Map<RowKey, RowEntry> listRows(String bucket, List values) {
  final result = <RowKey, RowEntry>{}, used = <String>{};
  for (var i = 0; i < values.length; i++) {
    final item = values[i];
    final String? rawId = switch (item) {
      WalletAccount v => v.id,
      LedgerTx v => v.id,
      WalletCategory v => v.id,
      QuickEntry v => v.id,
      Map v =>
        (v['id'] ?? v['eventId']) is String
            ? (v['id'] ?? v['eventId']) as String
            : null,
      _ => null,
    };
    var id = rawId == null ? 'index:$i' : 'id:$rawId';
    if (!used.add(id)) {
      id = 'duplicate:$i';
      used.add(id);
    }
    result[(bucket, id)] = (value: item, kind: 'value');
  }
  return result;
}

Map<RowKey, RowEntry> walletRows(
  WalletData data, {
  bool metadata = true,
  bool financial = true,
}) {
  final result = <RowKey, RowEntry>{};
  if (financial) {
    result.addAll(listRows('accounts', data.accounts));
    result.addAll(listRows('transactions', data.transactions));
    result.addAll(listRows('categories', data.categories));
    result.addAll(listRows('quickEntries', data.quickEntries));
  }
  if (!metadata) return result;
  result.addAll(listRows('goals', data.goals));
  result.addAll(listRows('chats', data.chats));
  for (final (name, map) in metadataMaps(data)) {
    for (final entry in map.entries) {
      if (entry.value is List) {
        result[(name, entry.key)] = (value: null, kind: 'list');
        result.addAll(listRows(childBucket(name, entry.key), entry.value));
      } else {
        result[(name, entry.key)] = (value: entry.value, kind: 'value');
      }
    }
  }
  return result;
}

List<(String, Json)> metadataMaps(WalletMetadata data) => [
  ('profile', data.profile),
  ('settings', data.settings),
  ('agent', data.agent),
  ('providerConfigs', data.providerConfigs),
  ('extras', data.extras),
];

/// The UI compares shared references. Only changed values cross the isolate;
/// ordered ids contain no message bodies and let the worker preserve ranks.
class MetadataDelta {
  final upserts = <RowKey, RowEntry>{};
  final deletes = <RowKey>{};
  final orderedIds = <String, List<String>>{};
  int scanned = 0;
  MetadataDelta.between(WalletMetadata previous, WalletMetadata next) {
    void list(String bucket, List old, List fresh) {
      if (identical(old, fresh)) return;
      final before = listRows(bucket, old), after = listRows(bucket, fresh);
      scanned += before.length + after.length;
      deletes.addAll(before.keys.where((key) => !after.containsKey(key)));
      for (final entry in after.entries) {
        if (!before.containsKey(entry.key) ||
            !identical(before[entry.key]!.value, entry.value.value)) {
          upserts[entry.key] = entry.value;
        }
      }
      orderedIds[bucket] = after.keys.map((key) => key.$2).toList();
    }

    list('goals', previous.goals, next.goals);
    list('chats', previous.chats, next.chats);
    final beforeMaps = metadataMaps(previous), afterMaps = metadataMaps(next);
    for (var i = 0; i < beforeMaps.length; i++) {
      final (name, old) = beforeMaps[i];
      final fresh = afterMaps[i].$2;
      if (identical(old, fresh)) continue;
      scanned += old.length + fresh.length;
      orderedIds[name] = fresh.keys.toList();
      for (final key in {...old.keys, ...fresh.keys}) {
        final a = old[key], b = fresh[key];
        if (old.containsKey(key) && fresh.containsKey(key) && identical(a, b)) {
          continue;
        }
        if (a is List || b is List) {
          list(
            childBucket(name, key),
            a is List ? a : const [],
            b is List ? b : const [],
          );
        }
        if (!fresh.containsKey(key)) {
          deletes.add((name, key));
          continue;
        }
        if (b is List) {
          if (a is! List) upserts[(name, key)] = (value: null, kind: 'list');
        } else {
          upserts[(name, key)] = (value: b, kind: 'value');
        }
      }
    }
  }
}
