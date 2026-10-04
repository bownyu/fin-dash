import 'dart:convert';
import 'package:flutter/services.dart';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import 'ai_service.dart';
import 'voice_bookkeeping.dart';

/// The widget shares the app's store and write queue, with a separate preview.
class VoiceWidgetRuntime {
  static const channel = MethodChannel('findash/voice_widget');
  static void install(
    WalletStore store,
    AiService ai,
    void Function() showApp,
  ) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'showApp') {
        showApp();
        return null;
      }
      if (call.method != 'record') throw MissingPluginException();
      final request = Json.from(call.arguments as Map);
      try {
        if (store.loading || store.startupError != null) {
          throw const FormatException('账本尚未就绪，请稍后重试');
        }
        if (store.data.settings['locked'] == true) {
          throw const FormatException('账本已锁定，请先解锁后使用语音记账');
        }
        final service = VoiceBookkeeping(store, ai);
        if (request['operation'] == 'undo') {
          final raw = Json.from(jsonDecode(request['transaction']));
          final transactions = raw['transactions'] is List
              ? (raw['transactions'] as List)
                    .map((e) => LedgerTx.fromJson(Json.from(e as Map)))
                    .toList()
              : [LedgerTx.fromJson(raw)];
          await service.undoBatch(transactions);
          return {
            'success': true,
            'message': transactions.length == 1
                ? '已撤销这笔账单'
                : '已撤销这${transactions.length}笔账单',
            'undone': true,
          };
        }
        final stored = request['draft'] is String
            ? _draft(request['draft'] as String, '${request['previous'] ?? ''}')
            : null;
        VoiceBatch batch;
        if (request['operation'] == 'confirm' ||
            request['operation'] == 'account') {
          var draft = stored!.entries.first;
          if (request['operation'] == 'confirm') {
            if (!_widgetReviewable(stored)) {
              throw const FormatException('请在 App 任务页逐笔核对这些账单后保存');
            }
            final transactions = await service.confirmBatch(stored);
            return {
              'success': true,
              'message': transactions.length == 1
                  ? '已保存 · 点麦克风再记一笔'
                  : '已保存${transactions.length}笔 · 点麦克风再记',
              'summary': transactions.length == 1
                  ? _summary(store, transactions.single.toJson())
                  : _batchSummary(store, stored, saved: true),
              'transaction': transactions.length == 1
                  ? transactions.single.toJson()
                  : {
                      'transactions': transactions
                          .map((e) => e.toJson())
                          .toList(),
                    },
            };
          }
          if (!_widgetReviewable(stored)) {
            throw const FormatException('请在 App 任务页逐笔修改这些账单');
          }
          final accounts = store.activeAccounts;
          if (accounts.isEmpty) throw const FormatException('请先在 App 添加账户');
          final transfer = draft.fields['type'] == 'transfer';
          if (transfer &&
              ![
                'transferFromId',
                'transferToId',
              ].contains(request['accountField'])) {
            final pairs = [
              for (final from in accounts)
                for (final to in accounts)
                  if (from.id != to.id) (from.id, to.id),
            ];
            if (pairs.isEmpty) {
              throw const FormatException('转账需要两个不同账户，请先在 App 添加账户');
            }
            final index = pairs.indexWhere(
              (pair) =>
                  pair.$1 == draft.fields['transferFromId'] &&
                  pair.$2 == draft.fields['transferToId'],
            );
            final next = pairs[(index + 1) % pairs.length];
            draft = draft.update({
              'transferFromId': next.$1,
              'transferToId': next.$2,
            });
          } else {
            final field = draft.fields['type'] == 'transfer'
                ? ([
                        'transferFromId',
                        'transferToId',
                      ].contains(request['accountField'])
                      ? request['accountField'] as String
                      : draft.fields['transferFromId'] == null
                      ? 'transferFromId'
                      : 'transferToId')
                : 'accountId';
            final opposite = field == 'transferFromId'
                ? draft.fields['transferToId']
                : field == 'transferToId'
                ? draft.fields['transferFromId']
                : null;
            final choices = accounts.where((a) => a.id != opposite).toList();
            if (choices.isEmpty) {
              throw const FormatException('转账需要两个不同的可用账户，请先在 App 添加账户');
            }
            final index = choices.indexWhere(
              (a) => a.id == draft.fields[field],
            );
            draft = draft.update({
              field: choices[(index + 1) % choices.length].id,
            });
          }
          batch = stored.entries.length == 1
              ? stored.update(draft)
              : VoiceBatch(stored.entryId, [
                  for (final e in stored.entries)
                    e.update({'accountId': draft.fields['accountId']}),
                ], transcript: stored.transcript);
        } else {
          final preferred = store.data.settings['quickEntryAccountId'];
          final accounts = store.activeAccounts;
          final accountId = accounts.any((a) => a.id == preferred)
              ? preferred as String
              : accounts.length == 1
              ? accounts.single.id
              : null;
          // With a stored draft the new words correct it instead of starting over.
          batch = await service.previewBatch(
            request['text'] as String,
            entryId: stored?.entryId ?? request['entryId'] as String,
            accountId: accountId,
            base: stored,
          );
        }
        final draft = batch.entries.first;
        final problem = batch.problem(store.data);
        final reviewable = _widgetReviewable(batch);
        final incomplete = batch.entries
            .where((e) => e.problem(store.data) != null)
            .firstOrNull;
        final missing = incomplete?.missing(store.data) ?? const <String>[];
        return {
          'success': true,
          'canConfirm': problem == null && reviewable,
          'needsClarification': problem != null || !reviewable,
          'message': !reviewable
              ? '请在 App 任务页逐笔核对这${batch.entries.length}笔账单'
              : problem == null
              ? batch.entries.length > 1
                    ? '点摘要统一换账户 · 确认保存${batch.entries.length}笔'
                    : draft.fields['type'] == 'transfer'
                    ? '点摘要换组合 · 可分别换转出／转入'
                    : '点账单换账户 · 右侧确认'
              : missing.contains('accountId')
              ? '点账单选择付款账户'
              : missing.contains('amountCents')
              ? '缺少金额 · 点麦克风补充'
              : '请补充信息：$problem',
          'summary': _batchSummary(store, batch),
          'draft': batch.toJson(),
          if (batch.transcript.isNotEmpty) 'text': batch.transcript,
          'hasAccounts': store.activeAccounts.isNotEmpty,
        };
      } catch (e) {
        return {
          'success': false,
          'message': e is FormatException ? e.message : '操作未完成，内容已保留，请重试',
        };
      }
    });
  }

  static VoiceBatch _draft(String encoded, String transcript) {
    final raw = Json.from(jsonDecode(encoded));
    return VoiceBatch.fromJson(raw, transcript: transcript);
  }

  // The widget has two detail lines. Larger/mixed transfer batches need the app.
  static bool _widgetReviewable(VoiceBatch batch) =>
      batch.entries.length == 1 ||
      (batch.entries.length == 2 &&
          batch.entries.every((e) => e.fields['type'] != 'transfer'));

  static String _batchSummary(
    WalletStore store,
    VoiceBatch batch, {
    bool saved = false,
  }) {
    if (batch.entries.length == 1) {
      return _summary(store, batch.entries.single.fields);
    }
    return '${saved ? '已保存' : '待确认'} ${batch.entries.length} 笔\n${batch.entries.map((e) {
      final fields = e.fields;
      final amount = fields['amountCents'] is int
          ? store.data.settings['visible'] == false
                ? '¥ ••••••'
                : money(fields['amountCents'])
          : '金额待补充';
      return '${fields['title'] ?? '用途待补充'} $amount · ${store.account(fields['accountId'])?.name ?? '账户待选'}';
    }).join('\n')}';
  }

  static String _summary(WalletStore store, Json fields) {
    final type = TxType.values
        .where((t) => t.name == fields['type'])
        .firstOrNull;
    final amount = fields['amountCents'] is int
        ? store.data.settings['visible'] == false
              ? '¥ ••••••'
              : money(fields['amountCents'])
        : '金额待补充';
    final account = type == TxType.transfer
        ? '${store.account(fields['transferFromId'])?.name ?? '转出待选'} → ${store.account(fields['transferToId'])?.name ?? '转入待选'}'
        : store.account(fields['accountId'])?.name ?? '账户待选';
    return '${type?.label ?? '类型待选'} $amount · ${fields['title'] ?? '用途待补充'}\n$account · ${fields['category'] ?? '分类待选'}';
  }
}
