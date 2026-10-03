import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'models.dart';

/// Created by the application for a local user action, never decoded from tools.
class CommandContext {
  final String operationId, ledgerEpoch, source, payloadHash;
  final Map<String, String?> expectedRecords;
  CommandContext({
    required this.operationId,
    required this.ledgerEpoch,
    required this.source,
    required Json payload,
    Map<String, String?> expectedRecords = const {},
  }) : payloadHash = digest(payload),
       expectedRecords = Map.unmodifiable(expectedRecords);
}

String digest(Object? value) {
  Object? ordered(Object? item) {
    if (item is Map) {
      final keys = item.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: ordered(item[key])};
    }
    if (item is List) return item.map(ordered).toList();
    return item;
  }

  return sha256.convert(utf8.encode(jsonEncode(ordered(value)))).toString();
}

/// Structural JSON equality for change detection. Unlike [digest] it never
/// encodes or hashes, and shared strings/subtrees compare by identity first.
bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !jsonEquals(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

enum WalletDomain { ledger, tasks, conversations, preferences, memory, sources }
