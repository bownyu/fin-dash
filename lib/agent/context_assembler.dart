import 'dart:convert';
import '../domain/models.dart';

abstract final class ContextAssembler {
  static const replayTurns = 15;
  static List<Json> recentTurns(
    Iterable<Json> messages, {
    int byteBudget = 60000,
    int maxTurns = replayTurns,
  }) {
    final turns = <List<Json>>[];
    for (final m in messages) {
      if (m['role'] == 'user') turns.add([]);
      if (turns.isNotEmpty) turns.last.add(m);
    }
    final selected = <List<Json>>[];
    var bytes = 0;
    for (final turn in turns.reversed) {
      final size = utf8.encode(jsonEncode(turn)).length;
      if (bytes + size > byteBudget || selected.length >= maxTurns) {
        if (selected.isEmpty) {
          throw const FormatException('本轮内容超出上下文预算，请缩短输入或开始新对话');
        }
        break;
      }
      selected.add(turn);
      bytes += size;
    }
    return selected.reversed.expand((t) => t).toList();
  }
}
