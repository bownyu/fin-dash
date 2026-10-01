import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../domain/models.dart';

const chatProtocol = 'chat_completions';
const responsesProtocol = 'responses';

Uri endpoint(String base, {String protocol = chatProtocol}) {
  if (![chatProtocol, responsesProtocol].contains(protocol)) {
    throw const FormatException('请选择 Responses 或 Chat Completions 协议');
  }
  final uri = Uri.tryParse(base.trim().replaceAll(RegExp(r'/+$'), ''));
  if (uri == null ||
      uri.host.isEmpty ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('服务地址不合法，请勿在 URL 中填写密钥');
  }
  if (uri.scheme == 'http' &&
      !['localhost', '127.0.0.1', '10.0.2.2', '::1'].contains(uri.host)) {
    throw const FormatException('远程服务地址须使用 HTTPS');
  }
  final path = uri.path.replaceFirst(
    RegExp(r'/(chat/completions|responses)$'),
    '',
  );
  return uri.replace(
    path:
        '$path/${protocol == responsesProtocol ? 'responses' : 'chat/completions'}',
  );
}

String redactAiError(Object error, String key) {
  var text = error is FormatException
      ? error.message.toString()
      : error.toString();
  if (key.isNotEmpty) text = text.replaceAll(key, '[已隐藏密钥]');
  return text
      .replaceAll(
        RegExp(r'Bearer\s+[^\s"<>]+', caseSensitive: false),
        'Bearer [已隐藏密钥]',
      )
      .replaceAll(RegExp(r'data:image/[^\s"]+'), '[图片数据已隐藏]');
}

/// A provider turn is separate from the persisted UI transcript and tool loop.
class AiTurn {
  String text = '', reasoning = '';
  final Map<int, Json> calls = {};
  final Map<int, Json> output = {};
  Json? usage;
  String? responseId;
  String? finishReason;
  List<Json> get toolCalls =>
      (calls.keys.toList()..sort()).map((i) => calls[i]!).toList();
  List<Json> get responseItems =>
      (output.keys.toList()..sort()).map((i) => output[i]!).toList();
  Json get chatMessage => {
    'role': 'assistant',
    'content': text.isEmpty ? null : text,
    if (reasoning.isNotEmpty) 'reasoning_content': reasoning,
    if (calls.isNotEmpty) 'tool_calls': toolCalls,
  };
}

class OpenAiTransport {
  final http.Client client;
  final Duration timeout;
  OpenAiTransport(this.client, {this.timeout = const Duration(seconds: 90)});

  Future<AiTurn> generate({
    required Uri uri,
    required String key,
    required Json settings,
    required List<Json> messages,
    required List<Json> input,
    required String instructions,
    required List<Json> tools,
    required void Function(String type, Json data) onEvent,
  }) async {
    final responses = settings['protocol'] == responsesProtocol;
    final streaming = settings['stream'] != false;
    final effort = settings['reasoningEffort'];
    final body = <String, dynamic>{
      'model': settings['model'],
      'stream': streaming,
      if (responses) ...{
        'instructions': instructions,
        'input': input,
        'store': false,
        if (settings['reasoningSummary'] == true ||
            effort != null && effort != 'default')
          'reasoning': {
            if (effort != null && effort != 'default') 'effort': effort,
            if (settings['reasoningSummary'] == true) 'summary': 'auto',
          },
        'include': ['reasoning.encrypted_content'],
      } else ...{
        'messages': messages,
        if (effort != null && effort != 'default') 'reasoning_effort': effort,
      },
      if (settings['toolsEnabled'] != false)
        'tools': responses
            ? tools
                  .map(
                    (t) => {
                      'type': 'function',
                      ...Json.from(t['function']),
                      'strict': false,
                    },
                  )
                  .toList()
            : tools,
    };
    final request = http.Request('POST', uri)
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Accept': streaming
            ? 'text/event-stream, application/json'
            : 'application/json',
        'Authorization': 'Bearer $key',
      })
      ..body = jsonEncode(body);
    String? requestId;
    final turn = AiTurn();
    try {
      final response = await client.send(request).timeout(timeout);
      requestId =
          response.headers['x-request-id'] ??
          response.headers['request-id'] ??
          response.headers['x-amzn-requestid'];
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final raw = await _readBody(response.stream);
        final hint = switch (response.statusCode) {
          401 => 'API 密钥无效或已过期',
          403 => '模型访问权限不足',
          429 => '请求限流或额度不足',
          404 => '接口路径或模型不存在，请核对协议和地址',
          400 || 415 || 422 => '请求参数不兼容，请核对协议、模型、图片与工具调用能力',
          _ => 'AI 服务请求失败',
        };
        throw FormatException(
          'HTTP ${response.statusCode} $hint\n${_errorText(raw)}',
        );
      }
      if (!(response.headers['content-type'] ?? '').contains(
        'text/event-stream',
      )) {
        final raw = await _readBody(response.stream);
        final decoded = _decode(raw);
        _full(decoded, turn, responses, onEvent);
        return turn;
      }
      var terminal = false, stopStream = false;
      final data = <String>[];
      String? eventName;
      void dispatch() {
        if (data.isEmpty) {
          eventName = null;
          return;
        }
        final raw = data.join('\n');
        data.clear();
        if (raw.trim() == '[DONE]') {
          terminal = true;
          stopStream = true;
          return;
        }
        final event = _decode(raw);
        event['type'] ??= eventName;
        eventName = null;
        if (event['error'] != null || event['type'] == 'error') {
          throw FormatException(_errorText(jsonEncode(event)));
        }
        if (responses) {
          terminal = _responseEvent(event, turn, onEvent) || terminal;
          stopStream = terminal;
        } else {
          terminal = _chatEvent(event, turn, onEvent) || terminal;
        }
      }

      await for (final line
          in response.stream
              .timeout(timeout)
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.isEmpty) {
          dispatch();
          if (stopStream) break;
        } else if (line.startsWith('data:')) {
          data.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
        } else if (line.startsWith('event:')) {
          eventName = line.substring(6).trim();
        }
      }
      dispatch();
      if (!terminal) throw const FormatException('流式连接提前断开，未收到完成事件；已保留部分输出');
      return turn;
    } catch (e) {
      final detail = e is TimeoutException
          ? '连接或流式读取超时（${timeout.inSeconds} 秒）'
          : redactAiError(e, key);
      throw FormatException(
        redactAiError(
          '$detail\n接口：$uri\n模型：${settings['model']}\n协议：${responses ? 'Responses' : 'Chat Completions'}${requestId == null ? '' : '\n请求 ID：$requestId'}',
          key,
        ),
      );
    }
  }

  Future<String> _readBody(Stream<List<int>> stream) async {
    final buffer = StringBuffer();
    await for (final chunk in stream.timeout(timeout).transform(utf8.decoder)) {
      buffer.write(chunk);
      if (buffer.length > 4 * 1024 * 1024) {
        throw const FormatException('服务响应超过 4 MB');
      }
    }
    return buffer.toString();
  }

  static Json _decode(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is Map) return Json.from(value);
    } catch (_) {
      /* Report the offending payload, without swallowing failure. */
    }
    throw FormatException(
      '服务返回的不是有效 JSON：${raw.substring(0, raw.length.clamp(0, 1000))}',
    );
  }

  static String _errorText(String raw) {
    try {
      final body = jsonDecode(raw);
      final value = body is Map ? body['error'] ?? body : body;
      if (value is Map) {
        return [
          for (final field in ['message', 'type', 'code', 'param'])
            if (value[field] != null) '$field: ${value[field]}',
          if (!value.containsKey('message')) jsonEncode(value),
        ].join('\n');
      }
    } catch (_) {
      /* Some gateways return HTML/plain text. */
    }
    return raw.substring(0, raw.length.clamp(0, 8000));
  }

  static String _content(dynamic value) {
    if (value is String) return value;
    if (value is List) {
      return value
          .whereType<Map>()
          .map((p) => p['text'] ?? p['refusal'] ?? '')
          .join();
    }
    return '';
  }

  static void _delta(
    AiTurn turn,
    String type,
    String delta,
    void Function(String, Json) emit,
  ) {
    if (delta.isEmpty) return;
    if (type == 'text') {
      turn.text += delta;
    } else {
      turn.reasoning += delta;
    }
    emit(type, {'delta': delta});
  }

  static void _full(
    Json body,
    AiTurn turn,
    bool responses,
    void Function(String, Json) emit,
  ) {
    if (body['error'] != null) {
      throw FormatException(_errorText(jsonEncode(body)));
    }
    if (responses) {
      _checkResponse(body);
      turn.responseId = body['id'];
      final output = body['output'];
      if (output is! List) {
        throw const FormatException('Responses 响应缺少 output，请核对接口协议');
      }
      for (var i = 0; i < output.length; i++) {
        _item(Json.from(output[i]), i, turn, emit, emitContent: true);
      }
    } else {
      final choices = body['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const FormatException('Chat Completions 响应缺少 choices，请核对接口协议');
      }
      final choice = choices.first;
      final message = Json.from(choice['message']);
      _delta(
        turn,
        'text',
        _content(message['content']) + _content(message['refusal']),
        emit,
      );
      _delta(
        turn,
        'reasoning',
        _content(message['reasoning_content'] ?? message['reasoning']),
        emit,
      );
      final calls = message['tool_calls'] as List? ?? [];
      for (var i = 0; i < calls.length; i++) {
        turn.calls[i] = Json.from(calls[i]);
        emit('tool_call', {'index': i, ...turn.calls[i]!});
      }
      _finish(choice['finish_reason']);
    }
    if (body['usage'] is Map) turn.usage = Json.from(body['usage']);
  }

  static bool _chatEvent(
    Json event,
    AiTurn turn,
    void Function(String, Json) emit,
  ) {
    if (event['usage'] is Map) turn.usage = Json.from(event['usage']);
    final choices = event['choices'] as List? ?? [];
    if (choices.isEmpty) return false;
    final choice = choices.first;
    final delta = Json.from(choice['delta'] ?? {});
    _delta(
      turn,
      'reasoning',
      _content(delta['reasoning_content'] ?? delta['reasoning']),
      emit,
    );
    _delta(
      turn,
      'text',
      _content(delta['content']) + _content(delta['refusal']),
      emit,
    );
    for (final raw in delta['tool_calls'] as List? ?? []) {
      final index = raw['index'] as int? ?? 0;
      final call = turn.calls.putIfAbsent(
        index,
        () => {
          'id': '',
          'type': 'function',
          'function': {'name': '', 'arguments': ''},
        },
      );
      if (raw['id'] != null) call['id'] = raw['id'];
      final function = raw['function'] as Map? ?? {};
      for (final field in ['name', 'arguments']) {
        if (function[field] != null) {
          call['function'][field] += function[field].toString();
        }
      }
      emit('tool_call', {'index': index, ...call});
    }
    final finish = choice['finish_reason'];
    if (finish == null) return false;
    _finish(finish);
    turn.finishReason = finish;
    return true;
  }

  static void _finish(dynamic reason) {
    if (reason == 'length' || reason == 'content_filter') {
      throw FormatException('模型未完成输出：finish_reason=$reason');
    }
  }

  static void _checkResponse(Json response) {
    if (response['status'] == 'failed' ||
        response['status'] == 'incomplete' ||
        response['status'] == 'cancelled') {
      throw FormatException(
        'Responses ${response['status']}：${_errorText(jsonEncode(response['error'] ?? response['incomplete_details'] ?? response))}',
      );
    }
  }

  static bool _responseEvent(
    Json event,
    AiTurn turn,
    void Function(String, Json) emit,
  ) {
    final type = event['type'];
    final index = event['output_index'] as int? ?? 0;
    switch (type) {
      case 'response.output_text.delta':
      case 'response.refusal.delta':
        _delta(turn, 'text', _content(event['delta']), emit);
      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_text.delta':
        _delta(turn, 'reasoning', _content(event['delta']), emit);
      case 'response.output_item.added':
        final item = Json.from(event['item']);
        turn.output[index] = item;
        if (item['type'] == 'function_call') _item(item, index, turn, emit);
      case 'response.function_call_arguments.delta':
        final call = turn.calls.putIfAbsent(
          index,
          () => {
            'id': '',
            'type': 'function',
            'function': {'name': '', 'arguments': ''},
          },
        );
        call['function']['arguments'] += _content(event['delta']);
        emit('tool_call', {'index': index, ...call});
      case 'response.function_call_arguments.done':
        final call = turn.calls[index];
        if (call != null) {
          call['function']['arguments'] =
              event['arguments'] ?? call['function']['arguments'];
          emit('tool_call', {'index': index, ...call});
        }
      case 'response.output_item.done':
        _item(Json.from(event['item']), index, turn, emit);
      case 'response.completed':
        final response = Json.from(event['response']);
        _checkResponse(response);
        turn.responseId = response['id'];
        if (response['usage'] is Map) turn.usage = Json.from(response['usage']);
        final output = response['output'] as List? ?? [];
        for (var i = 0; i < output.length; i++) {
          _item(Json.from(output[i]), i, turn, emit);
        }
        // Some compatible gateways only send the final response object.
        if (turn.text.isEmpty) {
          for (final item in turn.responseItems.where(
            (i) => i['type'] == 'message',
          )) {
            _delta(turn, 'text', _content(item['content']), emit);
          }
        }
        if (turn.reasoning.isEmpty) {
          for (final item in turn.responseItems.where(
            (i) => i['type'] == 'reasoning',
          )) {
            _delta(turn, 'reasoning', _content(item['summary']), emit);
          }
        }
        return true;
      case 'response.failed':
      case 'response.incomplete':
      case 'response.cancelled':
        final response = Json.from(event['response'] ?? {});
        throw FormatException(
          '$type：${_errorText(jsonEncode(response['error'] ?? response['incomplete_details'] ?? response))}',
        );
    }
    return false;
  }

  static void _item(
    Json item,
    int index,
    AiTurn turn,
    void Function(String, Json) emit, {
    bool emitContent = false,
  }) {
    turn.output[index] = item;
    if (item['type'] == 'function_call') {
      turn.calls[index] = {
        'id': item['call_id'] ?? item['id'],
        'type': 'function',
        'function': {
          'name': item['name'] ?? '',
          'arguments': item['arguments'] ?? '',
        },
      };
      emit('tool_call', {'index': index, ...turn.calls[index]!});
    } else if (emitContent && item['type'] == 'message') {
      _delta(turn, 'text', _content(item['content']), emit);
    } else if (emitContent && item['type'] == 'reasoning') {
      _delta(turn, 'reasoning', _content(item['summary']), emit);
    }
  }
}
