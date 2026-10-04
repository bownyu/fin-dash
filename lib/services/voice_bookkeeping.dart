import 'dart:convert';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/ledger_operations.dart';
import '../domain/text_terms.dart';
import 'ai_service.dart';

/// Reply keys that describe the draft instead of belonging to the bill.
const _replyMetadata = {'question', 'missingFields', 'assumed', 'entryId'};

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
    if (message != null) 'question': message,
  };

  factory VoiceDraft.fromJson(Json raw, {String transcript = ''}) => VoiceDraft(
    raw['entryId'] as String,
    Json.from(raw['fields'] as Map),
    transcript: transcript,
    message: raw['question'] as String?,
    assumed: {...(raw['assumed'] as List? ?? const []).whereType<String>()},
  );
}

/// One utterance can contain several independently editable bills.
class VoiceBatch {
  final String entryId;
  final List<VoiceDraft> entries;
  final String transcript;
  VoiceBatch(this.entryId, List<VoiceDraft> entries, {this.transcript = ''})
    : entries = List.unmodifiable(entries) {
    if (entries.isEmpty ||
        entries.length > 20 ||
        entries.map((e) => e.entryId).toSet().length != entries.length) {
      throw const FormatException('账单列表无效，请重试 AI 解析');
    }
  }

  VoiceBatch update(VoiceDraft draft) => VoiceBatch(entryId, [
    for (final e in entries) e.entryId == draft.entryId ? draft : e,
  ], transcript: transcript);

  String? problem(WalletData data) {
    for (var i = 0; i < entries.length; i++) {
      final problem = entries[i].problem(data);
      if (problem != null) {
        return entries.length == 1 ? problem : '第${i + 1}笔：$problem';
      }
    }
    return null;
  }

  Json current({String? selectedEntryId}) => entries.length == 1
      ? entries.single.fields
      : {
          'entries': [
            for (final e in entries) {'entryId': e.entryId, ...e.fields},
          ],
          'selectedEntryId': selectedEntryId ?? entries.first.entryId,
        };

  // Preserve the existing single-bill widget contract.
  Json toJson() => entries.length == 1
      ? entries.single.toJson()
      : {
          'entryId': entryId,
          'entries': entries.map((e) => e.toJson()).toList(),
        };

  factory VoiceBatch.fromJson(Json raw, {String transcript = ''}) => VoiceBatch(
    raw['entryId'] as String,
    raw['entries'] is List
        ? (raw['entries'] as List)
              .map(
                (e) => VoiceDraft.fromJson(
                  Json.from(e as Map),
                  transcript: transcript,
                ),
              )
              .toList()
        : [VoiceDraft.fromJson(raw, transcript: transcript)],
    transcript: transcript,
  );
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
    final batch = await previewBatch(
      text,
      entryId: entryId,
      accountId: accountId,
      base: base == null
          ? null
          : VoiceBatch(base.entryId, [base], transcript: base.transcript),
    );
    if (batch.entries.length != 1) {
      throw const FormatException('识别出多笔账单，请使用多笔预览核对');
    }
    return batch.entries.single;
  }

  Future<VoiceBatch> previewBatch(
    String text, {
    required String entryId,
    String? accountId,
    VoiceBatch? base,
    String? selectedEntryId,
  }) async {
    _unlocked();
    if (text.trim().isEmpty) throw const FormatException('请先说出或输入记账内容');
    if (text.length > 1000) throw const FormatException('一次最多识别 1000 字，请分开记账');
    final transcript = base == null ? text : supplement(base.transcript, text);
    await store.changeMetadata((d) {
      final drafts = Json.from(d.extras['voiceDrafts'] ?? {});
      drafts[entryId] = {
        ...Json.from(drafts[entryId] ?? {}),
        'entryId': entryId,
        'text': transcript,
        'accountId': accountId,
        'state': 'preparing',
        if (base != null) 'draft': base.toJson(),
      };
      d.extras['voiceDrafts'] = drafts;
    });
    Json input;
    try {
      input = await ai.queueVoice(
        entryId,
        text,
        defaultAccountId: accountId,
        current: base?.current(selectedEntryId: selectedEntryId),
        history: similarBills(store.data, transcript),
      );
    } on FormatException catch (e) {
      _unlocked();
      throw FormatException('${e.message}。记账内容已保留，请重试 AI 解析');
    }
    _unlocked();
    if (input.containsKey('id')) throw const FormatException('语音入口只能新增账单');
    final rawEntries = input.containsKey('entries')
        ? input['entries']
        : [input];
    if (rawEntries is! List ||
        rawEntries.isEmpty ||
        rawEntries.length > 20 ||
        rawEntries.any((e) => e is! Map)) {
      throw const FormatException('模型返回的账单列表无效，内容已保留，请重试 AI 解析');
    }
    if (base != null && rawEntries.length != base.entries.length) {
      throw const FormatException('修改结果遗漏或改变了账单数量，原草稿已保留，请重试');
    }
    final entries = <VoiceDraft>[];
    for (var i = 0; i < rawEntries.length; i++) {
      final raw = Json.from(rawEntries[i] as Map);
      if (raw.containsKey('id')) throw const FormatException('语音入口只能新增账单');
      final previous = base == null
          ? null
          : raw['entryId'] == null
          ? base.entries[i]
          : base.entries.where((e) => e.entryId == raw['entryId']).firstOrNull;
      if (base != null && previous == null) {
        throw const FormatException('修改结果的账单标识无效，原草稿已保留，请重试');
      }
      final fields = <String, dynamic>{
        ...?previous?.fields,
        for (final field in raw.entries)
          if (!_replyMetadata.contains(field.key)) field.key: field.value,
      };
      // Accept integer-valued JSON numbers/strings without guessing yuan units.
      final amount = fields['amountCents'];
      final number =
          amount is String && RegExp(r'^\d+(?:\.0+)?$').hasMatch(amount)
          ? num.tryParse(amount)
          : amount;
      if (number is num && number.isFinite && number % 1 == 0) {
        fields['amountCents'] = number.toInt();
      }
      final reported = raw['assumed'] is List
          ? raw['assumed'] as List
          : previous?.assumed.toList() ?? [];
      entries.add(
        VoiceDraft(
          previous?.entryId ?? (i == 0 ? entryId : '$entryId:${i + 1}'),
          fields,
          message: raw['question'] is String ? raw['question'] as String : null,
          transcript: transcript,
          assumed: {
            for (final key in reported.whereType<String>())
              if (fields[key] != null &&
                  (previous == null ||
                      previous.assumed.contains(key) ||
                      previous.fields[key] != fields[key]))
                key,
          },
        ),
      );
    }
    if (base != null) {
      entries.sort(
        (a, b) => base.entries
            .indexWhere((e) => e.entryId == a.entryId)
            .compareTo(base.entries.indexWhere((e) => e.entryId == b.entryId)),
      );
    }
    final batch = VoiceBatch(entryId, entries, transcript: transcript);
    await store.changeMetadata((d) {
      final drafts = Json.from(d.extras['voiceDrafts'] ?? {});
      drafts[entryId] = {
        'entryId': entryId,
        'text': transcript,
        'fields': input,
        'draft': batch.toJson(),
        'state': 'ready',
      };
      d.extras['voiceDrafts'] = drafts;
    });
    return batch;
  }

  Future<LedgerTx> confirm(VoiceDraft draft) async =>
      (await confirmBatch(VoiceBatch(draft.entryId, [draft]))).single;

  Future<List<LedgerTx>> confirmBatch(VoiceBatch batch) async {
    _unlocked();
    final result = <LedgerTx>[];
    await store.change((d) {
      if (d.settings['locked'] == true) {
        throw const FormatException('账本已锁定，本次未记账');
      }
      // Validate every bill before applying any of them in the same transaction.
      final transactions = batch.entries.map((e) => e.validate(d)).toList();
      for (final transaction in transactions) {
        final previous = d.transactions
            .where((t) => t.id == transaction.id)
            .firstOrNull;
        if (previous != null &&
            !LedgerOperations.sameTransaction(previous, transaction)) {
          throw const FormatException('这笔记录已经保存，请开始新的语音记账');
        }
      }
      final drafts = Json.from(d.extras['voiceDrafts'] ?? {});
      drafts.remove(batch.entryId);
      d.extras['voiceDrafts'] = drafts;
      final receipts = List<Json>.from(d.extras['sourceReceipts'] ?? []);
      for (final transaction in transactions) {
        result.add(
          LedgerOperations.putTransaction(
            d,
            transaction,
            mode: TransactionWrite.idempotentInsert,
          ),
        );
        if (transaction.accountId != null) {
          d.settings['quickEntryAccountId'] = transaction.accountId;
        }
        if (!receipts.any(
          (r) => r['operationId'] == 'voice:${transaction.id}',
        )) {
          receipts.add({
            'id': newId(),
            'operationId': 'voice:${transaction.id}',
            'transactionId': transaction.id,
            'status': 'applied',
          });
        }
      }
      d.extras['sourceReceipts'] = receipts;
    });
    return result;
  }

  void _unlocked() {
    if (store.data.settings['locked'] == true) {
      throw const FormatException('账本已锁定，请先解锁后记账');
    }
  }

  Future<void> undo(LedgerTx transaction) => undoBatch([transaction]);

  Future<void> undoBatch(List<LedgerTx> transactions) => store.change((d) {
    if (d.settings['locked'] == true) throw const FormatException('账本已锁定，请先解锁');
    for (final transaction in transactions) {
      final current = d.transactions
          .where((t) => t.id == transaction.id)
          .firstOrNull;
      if (current != null &&
          !LedgerOperations.sameTransaction(current, transaction)) {
        throw const FormatException('这笔账单后来有修改，请到账单页面处理');
      }
    }
    final ids = transactions.map((t) => t.id).toSet();
    d.transactions.removeWhere((t) => ids.contains(t.id));
  });
}
