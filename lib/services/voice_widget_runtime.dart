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
          final tx = LedgerTx.fromJson(
            Json.from(jsonDecode(request['transaction'])),
          );
          await service.undo(tx);
          return {'success': true, 'message': '已撤销这笔账单', 'undone': true};
        }
        VoiceDraft draft;
        if (request['operation'] == 'confirm' ||
            request['operation'] == 'account') {
          final raw = Json.from(jsonDecode(request['draft'] as String));
          draft = VoiceDraft(
            raw['entryId'] as String,
            Json.from(raw['fields'] as Map),
          );
          if (request['operation'] == 'confirm') {
            final tx = await service.confirm(draft);
            return {
              'success': true,
              'message': '已保存 · 点麦克风再记一笔',
              'summary': _summary(store, tx.toJson()),
              'transaction': tx.toJson(),
            };
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
        } else {
          final preferred = store.data.settings['quickEntryAccountId'];
          final accounts = store.activeAccounts;
          final accountId = accounts.any((a) => a.id == preferred)
              ? preferred as String
              : accounts.length == 1
              ? accounts.single.id
              : null;
          draft = await service.preview(
            request['text'] as String,
            entryId: request['entryId'] as String,
            accountId: accountId,
          );
        }
        final problem = draft.problem(store.data);
        final accountMissing =
            draft.fields['type'] != 'transfer' &&
            !store.activeAccounts.any((a) => a.id == draft.fields['accountId']);
        return {
          'success': true,
          'canConfirm': problem == null,
          'needsClarification': problem != null,
          'message': problem == null
              ? draft.fields['type'] == 'transfer'
                    ? '点摘要换组合 · 可分别换转出／转入'
                    : '点账单换账户 · 右侧确认'
              : accountMissing
              ? '点账单选择付款账户'
              : draft.fields['amountCents'] == null
              ? '缺少金额 · 点麦克风补充'
              : '请补充信息：$problem',
          'summary': _summary(store, draft.fields),
          'draft': {'entryId': draft.entryId, 'fields': draft.fields},
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
