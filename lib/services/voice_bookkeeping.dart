import 'dart:convert';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import 'agent_actions.dart';
import 'ai_service.dart';

class VoiceClarification extends FormatException {
  const VoiceClarification(super.message);
}

class VoiceBookkeeping {
  final WalletStore store;
  final AiService ai;
  VoiceBookkeeping(this.store, this.ai);

  Future<LedgerTx> record(
    String text, {
    required String entryId,
    String? accountId,
  }) async {
    if (store.data.settings['locked'] == true) {
      throw const FormatException('账本已锁定，请先解锁后记账');
    }
    final existing = store.data.transactions
        .where((t) => t.id == entryId)
        .firstOrNull;
    if (existing != null) return existing;
    final input = await ai.interpretVoice(text, defaultAccountId: accountId);
    if (input['question'] is String &&
        (input['question'] as String).trim().isNotEmpty) {
      throw VoiceClarification(input['question']);
    }
    LedgerTx? result;
    await store.change((d) {
      if (d.settings['locked'] == true) {
        throw const FormatException('账本已锁定，本次未记账');
      }
      final transaction = AgentActions.prepareTransaction(
        d,
        input,
        id: entryId,
      );
      final previous = d.transactions.where((t) => t.id == entryId).firstOrNull;
      if (previous != null &&
          jsonEncode(previous.toJson()) != jsonEncode(transaction.toJson())) {
        throw const FormatException('这笔记录已经保存，请开始新的语音记账');
      }
      if (previous == null) d.transactions.add(transaction);
      if (transaction.accountId != null) {
        d.settings['quickEntryAccountId'] = transaction.accountId;
      }
      result = transaction;
    });
    return result!;
  }

  Future<void> undo(LedgerTx transaction) => store.change((d) {
    final current = d.transactions
        .where((t) => t.id == transaction.id)
        .firstOrNull;
    if (current == null) return;
    if (jsonEncode(current.toJson()) != jsonEncode(transaction.toJson())) {
      throw const FormatException('这笔账单后来有修改，请到账单页面处理');
    }
    d.transactions.removeWhere((t) => t.id == transaction.id);
  });
}
