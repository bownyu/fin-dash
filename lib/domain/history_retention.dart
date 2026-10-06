import 'dart:convert';
import '../agent/context_assembler.dart';
import 'models.dart';
import 'cow_json.dart';

final _proposalCache = Expando<Set<String>>();
String? blockProposalId(Map block) {
  if (block['proposalId'] is String) return block['proposalId'];
  try {
    final raw = block['result'];
    final result = raw is String ? jsonDecode(raw) : raw;
    return result is Map && result['proposalId'] is String
        ? result['proposalId']
        : null;
  } catch (_) {
    return null;
  }
}

Set<String> messageProposalIds(Json message) {
  final cached = _proposalCache[message];
  if (cached != null) return cached;
  final ids = <String>{};
  if (message['role'] == 'assistant' && message['actionId'] is String) {
    ids.add(message['actionId']);
  }
  for (final block in message['blocks'] as List? ?? []) {
    if (block['type'] != 'tool' || !'${block['name']}'.startsWith('propose_')) {
      continue;
    }
    final id = blockProposalId(block);
    if (id != null) ids.add(id);
  }
  if (message is FrozenMap) _proposalCache[message] = ids;
  return ids;
}

/// Only completed messages outside the protocol replay window are compacted.
/// Error/cancelled checkpoints retain their full payload for retry.
void compactChatHistory(WalletMetadata d, {String? sessionId}) {
  final turns = <String, int>{};
  for (var i = d.chats.length - 1; i >= 0; i--) {
    final candidate = d.chats is CowList<Json>
        ? (d.chats as CowList<Json>).peek(i)
        : d.chats[i];
    final session = '${candidate['sessionId'] ?? 'legacy'}';
    if (sessionId != null && session != sessionId) continue;
    final count = turns[session] ?? 0;
    if (candidate['role'] == 'user') {
      turns[session] = count + 1;
      continue;
    }
    if (count < ContextAssembler.replayTurns ||
        candidate['status'] != 'complete' ||
        candidate['historyCompacted'] == true) {
      continue;
    }
    final message = d.chats[i];
    message.remove('modelMessages');
    message.remove('responseItems');
    for (final block in message['blocks'] as List? ?? []) {
      if (block['type'] != 'tool') continue;
      if ('${block['name']}'.startsWith('propose_')) {
        final id = blockProposalId(block);
        if (id != null) block['proposalId'] = id;
        continue;
      }
      final raw = block['result'];
      final bytes = utf8.encode(raw is String ? raw : jsonEncode(raw));
      if (bytes.length > 8192) {
        block['result'] =
            '${utf8.decode(bytes.take(8192).toList(), allowMalformed: true)}…（已截断）';
        block['resultTruncated'] = true;
      }
    }
    message['historyCompacted'] = true;
  }
}

void pruneReceipts(WalletMetadata d) {
  final receipts = d.extras['operationReceipts'] as List?;
  if (receipts == null) return;
  final cutoff = DateTime.now().subtract(const Duration(days: 30));
  receipts.removeWhere((r) {
    final date = DateTime.tryParse('${r['createdAt']}');
    return date != null && date.isBefore(cutoff);
  });
  if (receipts.length > 1000) receipts.removeRange(0, receipts.length - 1000);
}

void _retain(List? values, int limit, bool Function(dynamic) active) {
  if (values == null) return;
  var ended = 0;
  final keep = <int>{};
  for (var i = values.length - 1; i >= 0; i--) {
    if (active(values[i]) || ended++ < limit) keep.add(i);
  }
  var index = 0;
  values.removeWhere((_) => !keep.contains(index++));
}

void pruneTasks(WalletMetadata d) => _retain(
  d.extras['tasks'] as List?,
  200,
  (task) => !['completed', 'cancelled', 'failed'].contains(task['state']),
);
void pruneActions(WalletMetadata d) {
  final actions = d.extras['agentActions'] as List?;
  _retain(actions, 500, (action) => action['status'] == 'pending');
  final pendingBatches = {
    for (final a in actions ?? [])
      if (a['status'] == 'pending') a['batchId'],
  };
  _retain(
    d.extras['agentActionBatches'] as List?,
    500,
    (batch) =>
        pendingBatches.contains(batch['id']) ||
        batch['generation'] == 'preparing',
  );
}

void pruneHistory(WalletMetadata d) {
  pruneReceipts(d);
  pruneTasks(d);
  pruneActions(d);
}
