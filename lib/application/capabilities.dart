import 'dart:async';
import 'dart:convert';
import '../domain/models.dart';
import '../domain/query_contracts.dart';

enum CapabilityEffect { read, prepare, preferenceWrite, ledgerCommit, external }

class CapabilityDefinition {
  final String id, name, description;
  final CapabilityEffect effect;
  final Json inputSchema;
  final FutureOr<Json> Function(Json) execute;
  const CapabilityDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.effect,
    required this.inputSchema,
    required this.execute,
  });
  Json get tool => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': inputSchema,
    },
  };
  Json get summary => {
    'id': id,
    'name': name,
    'description': description,
    'effect': effect.name,
    'version': 1,
    'inputSchema': inputSchema,
  };
}

class CapabilityRegistry {
  static const version = '1';
  final _entries = <String, CapabilityDefinition>{};
  void register(CapabilityDefinition definition) {
    if (_entries.containsKey(definition.name)) throw StateError('重复能力名称');
    _entries[definition.name] = definition;
  }

  List<Json> get tools => _entries.values
      .where(
        (e) => ![
          CapabilityEffect.ledgerCommit,
          CapabilityEffect.external,
        ].contains(e.effect),
      )
      .map((e) => e.tool)
      .toList();
  List<Json> search(String query) => _entries.values
      .where(
        (e) => '${e.id} ${e.description}'.toLowerCase().contains(
          query.toLowerCase(),
        ),
      )
      .map((e) => e.summary)
      .take(40)
      .toList();
  Future<Json> call(String name, Json args) async {
    final definition = _entries[name];
    if (definition == null ||
        [
          CapabilityEffect.ledgerCommit,
          CapabilityEffect.external,
        ].contains(definition.effect)) {
      throw const ErrorEnvelope(ErrorCode.forbidden, '此能力不可调用');
    }
    if (utf8.encode(jsonEncode(args)).length > 131072) {
      throw const ErrorEnvelope(ErrorCode.limitExceeded, '工具参数过长');
    }
    validate(args, definition.inputSchema);
    final result = await definition.execute(args);
    if (utf8.encode(jsonEncode(result)).length > 65536) {
      throw const ErrorEnvelope(
        ErrorCode.limitExceeded,
        '结果超出 64 KiB，请缩小范围或分页查询',
      );
    }
    return result;
  }

  static void validate(dynamic value, Map schema, [int depth = 0]) {
    if (depth > 30) throw const FormatException('参数嵌套过深');
    final valid = switch (schema['type']) {
      'object' => value is Map,
      'array' => value is List,
      'integer' => value is int,
      'number' => value is num && value.isFinite,
      'string' => value is String,
      'boolean' => value is bool,
      _ => true,
    };
    if (!valid) throw const FormatException('工具参数类型错误');
    if (schema['enum'] is List && !(schema['enum'] as List).contains(value)) {
      throw const FormatException('参数值不在允许范围内');
    }
    if (value is String && value.length > (schema['maxLength'] ?? 10000)) {
      throw const FormatException('参数文本过长');
    }
    if (value is num &&
        (schema['minimum'] != null && value < schema['minimum'] ||
            schema['maximum'] != null && value > schema['maximum'])) {
      throw const FormatException('参数超出范围');
    }
    if (value is List) {
      if (value.length > (schema['maxItems'] ?? 200) ||
          value.length < (schema['minItems'] ?? 0)) {
        throw const FormatException('参数列表长度超限');
      }
      if (schema['items'] is Map) {
        for (final item in value) {
          validate(item, schema['items'], depth + 1);
        }
      }
    }
    if (value is Map) {
      final properties = schema['properties'] as Map? ?? {};
      if (schema['additionalProperties'] != true &&
          value.keys.any((k) => !properties.containsKey(k))) {
        throw const FormatException('包含未知工具参数');
      }
      if ((schema['required'] as List? ?? []).any(
        (k) => !value.containsKey(k),
      )) {
        throw const FormatException('缺少必填工具参数');
      }
      for (final e in value.entries) {
        if (properties[e.key] is Map) {
          validate(e.value, properties[e.key], depth + 1);
        }
      }
    }
  }
}

Json objectSchema(Json properties, [List<String> required = const []]) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};
