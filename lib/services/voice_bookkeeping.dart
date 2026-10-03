import 'dart:convert';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/ledger_operations.dart';
import 'ai_service.dart';

class VoiceDraft {
  final String entryId;
  final Json fields;
  final String? message;
  VoiceDraft(this.entryId, Json fields, {this.message})
    : fields = Map.unmodifiable(fields);
  VoiceDraft update(Json changes) =>
      VoiceDraft(entryId, {...fields, ...changes});
  LedgerTx validate(WalletData data) =>
      LedgerOperations.prepareTransaction(data, fields, id: entryId);
  String? problem(WalletData data) {
    try {
      validate(data);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }
}

class VoiceBookkeeping {
  final WalletStore store;
  final AiService ai;
  VoiceBookkeeping(this.store, this.ai);

  /// Parsing never writes a transaction. Confirmation is a separate operation.
  Future<VoiceDraft> preview(
    String text, {
    required String entryId,
    String? accountId,
  }) async {
    _unlocked();
    if (text.trim().isEmpty) throw const FormatException('请先说出或输入记账内容');
    if (text.length > 1000) throw const FormatException('一次最多识别 1000 字，请分开记账');
    await store.changeMetadata((d) {
      final drafts = Json.from(d.extras['voiceDrafts'] ?? {});
      drafts[entryId] = {
        'entryId': entryId,
        'text': text,
        'accountId': accountId,
        'state': 'preparing',
      };
      d.extras['voiceDrafts'] = drafts;
    });
    Json input;
    try {
      input = await ai.queueVoice(entryId, text, defaultAccountId: accountId);
    } on FormatException catch (e) {
      _unlocked();
      throw FormatException('${e.message}。记账内容已保留，请重试 AI 解析');
    }
    _unlocked();
    if (input.containsKey('id')) throw const FormatException('语音入口只能新增账单');
    await store.changeMetadata((d) {
      final drafts = Json.from(d.extras['voiceDrafts'] ?? {});
      drafts[entryId] = {
        'entryId': entryId,
        'text': text,
        'fields': input,
        'state': 'ready',
      };
      d.extras['voiceDrafts'] = drafts;
    });
    return VoiceDraft(
      entryId,
      {
        for (final field in input.entries)
          if (field.key != 'question' && field.key != 'missingFields')
            field.key: field.value,
      },
      message: input['question'] is String ? input['question'] as String : null,
    );
  }

  Future<LedgerTx> confirm(VoiceDraft draft) async {
    _unlocked();
    LedgerTx? result;
    await store.change((d) {
      if (d.settings['locked'] == true) {
        throw const FormatException('账本已锁定，本次未记账');
      }
      final transaction = draft.validate(d);
      final previous = d.transactions
          .where((t) => t.id == draft.entryId)
          .firstOrNull;
      if (previous != null &&
          jsonEncode(previous.toJson()) != jsonEncode(transaction.toJson())) {
        throw const FormatException('这笔记录已经保存，请开始新的语音记账');
      }
      LedgerOperations.putTransaction(
        d,
        transaction,
        mode: TransactionWrite.idempotentInsert,
      );
      if (transaction.accountId != null) {
        d.settings['quickEntryAccountId'] = transaction.accountId;
      }
      result = previous ?? transaction;
      final drafts = Json.from(d.extras['voiceDrafts'] ?? {});
      drafts.remove(draft.entryId);
      d.extras['voiceDrafts'] = drafts;
      final receipts = List<Json>.from(d.extras['sourceReceipts'] ?? []);
      if (!receipts.any((r) => r['operationId'] == 'voice:${draft.entryId}')) {
        receipts.add({
          'id': newId(),
          'operationId': 'voice:${draft.entryId}',
          'transactionId': transaction.id,
          'status': 'applied',
        });
      }
      d.extras['sourceReceipts'] = receipts;
    });
    return result!;
  }

  void _unlocked() {
    if (store.data.settings['locked'] == true) {
      throw const FormatException('账本已锁定，请先解锁后记账');
    }
  }

  Future<void> undo(LedgerTx transaction) => store.change((d) {
    if (d.settings['locked'] == true) throw const FormatException('账本已锁定，请先解锁');
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
