import '../domain/models.dart';

/// Preserve legacy local dates; similarity never proves provenance.
WalletData migrateWallet(WalletData previous, {bool restored = false}) {
  final next = previous.clone();
  if (restored) next.extras['ledgerEpoch'] = newId();
  next.extras.putIfAbsent('ledgerEpoch', newId);
  final categories = <(TxType, String), List<WalletCategory>>{};
  for (final c in next.categories) {
    (categories[(c.type, c.name)] ??= []).add(c);
  }
  next.transactions = next.transactions.map((t) {
    if (t.categoryId != null) return t;
    final matches = categories[(t.type, t.category)] ?? [];
    return matches.length == 1
        ? LedgerTx.fromJson({...t.toJson(), 'categoryId': matches.single.id})
        : t;
  }).toList();
  for (final b in next.extras['agentActionBatches'] as List? ?? []) {
    b.putIfAbsent('taskId', newId);
    b.putIfAbsent(
      'ledgerEpoch',
      () => previous.extras['ledgerEpoch'] ?? next.extras['ledgerEpoch'],
    );
  }
  final tasks = (next.extras['tasks'] as List? ?? [])
      .map((t) => Json.from(t))
      .toList();
  for (final b in next.extras['agentActionBatches'] as List? ?? []) {
    if (tasks.any((t) => t['id'] == b['taskId'])) continue;
    final pending = (next.extras['agentActions'] as List? ?? []).any(
      (a) => a['batchId'] == b['id'] && a['status'] == 'pending',
    );
    tasks.add({
      'id': b['taskId'],
      'goal': b['title'],
      'planId': b['id'],
      'sessionId': b['sessionId'],
      'ledgerEpoch': b['ledgerEpoch'],
      'createdAt': b['createdAt'],
      'state': b['closed'] == true
          ? 'cancelled'
          : pending
          ? 'interrupted'
          : 'completed',
    });
  }
  next.extras['tasks'] = tasks;
  next.extras['dataModelVersion'] = 2;
  return next;
}
