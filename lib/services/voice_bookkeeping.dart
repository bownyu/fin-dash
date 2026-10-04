import 'dart:convert';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/ledger_operations.dart';
import '../domain/text_terms.dart';
import 'ai_service.dart';

/// Reply keys that describe the draft instead of belonging to the bill.
const _replyMetadata = {'question', 'missingFields', 'assumed'};

class VoiceDraft {
  final String entryId;
  final Json fields;
  final String? message;

  /// Everything said for this bill, including later spoken corrections.
  final String transcript;

  /// Fields the AI inferred rather than heard. Editing a field confirms it.
  final Set<String> assumed;
  VoiceDraft(
    this.entryId,
    Json fields, {
    this.message,
    this.transcript = '',
    Set<String> assumed = const {},
  }) : fields = Map.unmodifiable(fields),
       assumed = Set.unmodifiable(assumed);
  VoiceDraft update(Json changes) => VoiceDraft(
    entryId,
    {...fields, ...changes},
    transcript: transcript,
    assumed: assumed.difference(changes.keys.toSet()),
  );
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

  /// Required fields that are empty or unusable, in the order to fix them.
  List<String> missing(WalletData data) {
    bool usable(Object? id) =>
        data.accounts.any((a) => a.id == id && !a.archived);
    final type = fields['type'];
    final amount = fields['amountCents'];
    return [
      if (!TxType.values.any((t) => t.name == type)) 'type',
      if (amount is! int || amount <= 0) 'amountCents',
      if ('${fields['title'] ?? ''}'.trim().isEmpty) 'title',
      if (type == TxType.transfer.name) ...[
        if (!usable(fields['transferFromId'])) 'transferFromId',
        if (!usable(fields['transferToId']) ||
            fields['transferToId'] == fields['transferFromId'])
          'transferToId',
      ] else ...[
        if (!usable(fields['accountId'])) 'accountId',
        if (!data.categories.any(
          (c) => c.type.name == type && c.name == fields['category'],
        ))
          'category',
      ],
    ];
  }

  Json toJson() => {
    'entryId': entryId,
    'fields': fields,
    'assumed': assumed.toList(),
  };
}

class VoiceBookkeeping {
  final WalletStore store;
  final AiService ai;
  VoiceBookkeeping(this.store, this.ai);

  /// How a spoken correction joins earlier words; the app and widget share it.
  static String supplement(String previous, String addition) =>
      previous.trim().isEmpty
      ? addition.trim()
      : '${previous.trim()}；补充：${addition.trim()}';

  /// Earlier bills whose titles share words with [text]. Confirmed bills
  /// already hold the user's corrections, so misheard merchants can be fixed
  /// without extra storage. Amounts and notes never leave the device here.
  static List<Json> similarBills(
    WalletData data,
    String text, {
    int limit = 5,
  }) {
    final spoken = searchTerms(text);
    if (spoken.isEmpty) return const [];
    final active = {
      for (final a in data.accounts)
        if (!a.archived) a.id,
    };
    final matches = <(int, LedgerTx)>[];
    for (final tx in data.transactions) {
      final hits = searchTerms(tx.title).where(spoken.contains).length;
      if (hits > 0) matches.add((hits, tx));
    }
    matches.sort((a, b) {
      final byHits = b.$1.compareTo(a.$1);
      return byHits != 0 ? byHits : b.$2.date.compareTo(a.$2.date);
    });
    String? account(String? id) => active.contains(id) ? id : null;
    final result = <Json>[], seen = <String>{};
    for (final (_, tx) in matches) {
      final hint = <String, dynamic>{
        'title': tx.title,
        'type': tx.type.name,
        'category': tx.category,
        if (tx.type == TxType.transfer) ...{
          'transferFromId': account(tx.fromId),
          'transferToId': account(tx.toId),
        } else
          'accountId': account(tx.accountId),
      };
      if (!seen.add(jsonEncode(hint))) continue;
      result.add(hint);
      if (result.length >= limit) break;
    }
    return result;
  }

  /// Parsing never writes a transaction. Confirmation is a separate operation.
  /// With [base], [text] is a spoken correction to that draft.
  Future<VoiceDraft> preview(
    String text, {
    required String entryId,
    String? accountId,
    VoiceDraft? base,
  }) async {
    _unlocked();
    if (text.trim().isEmpty) throw const FormatException('请先说出或输入记账内容');
    if (text.length > 1000) throw const FormatException('一次最多识别 1000 字，请分开记账');
    final transcript = base == null ? text : supplement(base.transcript, text);
    await store.changeMetadata((d) {
      final drafts = Json.from(d.extras['voiceDrafts'] ?? {});
      drafts[entryId] = {
        'entryId': entryId,
        'text': transcript,
        'accountId': accountId,
        'state': 'preparing',
      };
      d.extras['voiceDrafts'] = drafts;
    });
    Json input;
    try {
      input = await ai.queueVoice(
        entryId,
        text,
        defaultAccountId: accountId,
        current: base?.fields,
        history: similarBills(store.data, transcript),
      );
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
        'text': transcript,
        'fields': input,
        'state': 'ready',
      };
      d.extras['voiceDrafts'] = drafts;
    });
    final fields = {
      for (final field in input.entries)
        if (!_replyMetadata.contains(field.key)) field.key: field.value,
    };
    final reported = input['assumed'] is List ? input['assumed'] as List : [];
    return VoiceDraft(
      entryId,
      fields,
      message: input['question'] is String ? input['question'] as String : null,
      transcript: transcript,
      // A field the user already settled stays settled unless this reply moved it.
      assumed: {
        for (final key in reported.whereType<String>())
          if (fields[key] != null &&
              (base == null ||
                  base.assumed.contains(key) ||
                  base.fields[key] != fields[key]))
            key,
      },
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
