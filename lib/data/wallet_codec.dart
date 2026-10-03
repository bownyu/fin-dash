import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import 'backup.dart';

// Small saves avoid isolate startup/copy overhead. Large payloads move the
// validation, date formatting, map allocation and JSON work off the UI isolate.
const walletBackgroundRecordThreshold = 500;
const walletBackgroundByteThreshold = 256 * 1024;

bool _largeWallet(WalletData data) =>
    data.transactions.length +
            data.chats.length +
            data.goals.length +
            data.accounts.length +
            data.quickEntries.length >=
        walletBackgroundRecordThreshold ||
    _largeJson([
      data.profile,
      data.settings,
      data.extras,
      data.chats,
      data.goals,
      data.agent,
      data.providerConfigs,
    ]);

// Stop early without serializing simply to decide whether to serialize remotely.
bool _largeJson(Object? value) {
  var remaining = walletBackgroundByteThreshold;
  bool visit(Object? node) {
    remaining -= node is String ? node.length : 16;
    if (remaining <= 0) return true;
    if (node is Map) {
      for (final value in node.values) {
        if (visit(value)) return true;
      }
    } else if (node is List) {
      for (final value in node) {
        if (visit(value)) return true;
      }
    }
    return false;
  }

  return visit(value);
}

String _encode(WalletData data) {
  validateWallet(data);
  return jsonEncode(data.toJson());
}

Future<String> encodeWalletSnapshot(WalletData data) async => _largeWallet(data)
    ? await compute(_encode, data, debugLabel: 'wallet-encode')
    : _encode(data);

WalletData _decode(String raw) {
  final data = WalletData.fromJson(jsonDecode(raw));
  validateWallet(data);
  return data;
}

Future<WalletData> decodeWalletSnapshot(String raw) async =>
    raw.length >= walletBackgroundByteThreshold
    ? await compute(_decode, raw, debugLabel: 'wallet-decode')
    : _decode(raw);
