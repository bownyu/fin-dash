import 'dart:convert';
import 'package:flutter/services.dart';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import 'ai_service.dart';
import 'voice_bookkeeping.dart';

/// App and desktop widget share one engine, one store, and the same write queue.
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
        final bookkeeping = VoiceBookkeeping(store, ai);
        if (request['operation'] == 'undo') {
          final transaction = LedgerTx.fromJson(
            Json.from(jsonDecode(request['transaction'])),
          );
          await bookkeeping.undo(transaction);
          return {'success': true, 'message': '已撤销这笔账单', 'undone': true};
        }
        final preferred = store.data.settings['quickEntryAccountId'];
        final accounts = store.activeAccounts;
        final accountId = accounts.any((a) => a.id == preferred)
            ? preferred as String
            : accounts.length == 1
            ? accounts.single.id
            : null;
        final tx = await bookkeeping.record(
          '${request['text']}',
          entryId: request['entryId'] as String,
          accountId: accountId,
        );
        final account = tx.type == TxType.transfer
            ? '${store.account(tx.fromId)?.name} → ${store.account(tx.toId)?.name}'
            : store.account(tx.accountId)?.name;
        return {
          'success': true,
          'message':
              '已记：${tx.title} · ${tx.type.label} ${money(tx.amount)}\n$account',
          'transaction': tx.toJson(),
        };
      } catch (e) {
        return {
          'success': false,
          'message': e is FormatException ? e.message : '账单未保存，请重试',
          'needsClarification': e is VoiceClarification,
        };
      }
    });
  }
}
