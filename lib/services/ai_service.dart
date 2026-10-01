import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../data/wallet_store.dart';
import '../domain/models.dart';

abstract class KeyVault {
  Future<String?> read(String provider);
  Future<void> write(String provider, String value);
}

class SecureKeyVault implements KeyVault {
  final FlutterSecureStorage storage = const FlutterSecureStorage();
  @override
  Future<String?> read(String provider) =>
      storage.read(key: 'findash_api_$provider');
  @override
  Future<void> write(String provider, String value) => value.isEmpty
      ? storage.delete(key: 'findash_api_$provider')
      : storage.write(key: 'findash_api_$provider', value: value);
}

const providerDefaults = <String, Json>{
  'zhipu': {
    'name': '智谱 AI',
    'baseURL': 'https://open.bigmodel.cn/api/paas/v4',
    'model': 'glm-4-plus',
  },
  'nvidia': {
    'name': 'NVIDIA NIM',
    'baseURL': 'https://integrate.api.nvidia.com/v1',
    'model': 'meta/llama-3.3-70b-instruct',
  },
  'custom': {
    'name': '自定义服务',
    'baseURL': 'https://api.openai.com/v1',
    'model': 'gpt-4.1-mini',
  },
};

class AiService {
  final WalletStore store;
  final KeyVault vault;
  final http.Client Function() createClient;
  http.Client? _client;
  int _generation = 0;
  String? error;
  String? lastPrompt;
  DateRange? lastRange;
  bool _lastPromptStored = false;
  AiService(this.store, this.vault, {http.Client Function()? clientFactory})
    : createClient = clientFactory ?? http.Client.new;
  String get provider => store.data.settings['provider'] ?? 'zhipu';
  Json get config => {
    ...providerDefaults[provider]!,
    ...Json.from(store.data.providerConfigs[provider] ?? {}),
  };
  bool get busy => store.aiStatus != null;
  void cancel() {
    _generation++;
    _client?.close();
    store.setAiStatus(null);
  }

  Future<void> send(
    String prompt, {
    DateRange? analysisRange,
    bool retry = false,
  }) async {
    if (busy || prompt.trim().isEmpty) return;
    final generation = ++_generation;
    http.Client? requestClient;
    if (!retry) _lastPromptStored = false;
    lastPrompt = prompt;
    lastRange = analysisRange;
    error = null;
    store.setAiStatus('连接顾问…');
    try {
      final key = await vault.read(provider);
      if (generation != _generation) return;
      if (key == null || key.isEmpty) {
        throw const FormatException('请先在“我的 → AI 设置”中填写 API 密钥');
      }
      if (!retry) {
        await store.change(
          (d) => d.chats.add({
            'id': newId(),
            'role': 'user',
            'content': prompt.trim(),
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }),
        );
      }
      final settings = config;
      _lastPromptStored = true;
      if (generation != _generation) return;
      final uri = endpoint(settings['baseURL']);
      final authorization = provider == 'zhipu' && key.split('.').length == 2
          ? zhipuToken(key)
          : key;
      final date = dayKey(DateTime.now());
      final conversation = store.data.chats
          .where((m) => dayKey(localDate(m['timestamp'])) == date)
          .toList();
      final cacheKey = analysisRange == null
          ? null
          : sha256
                .convert(
                  utf8.encode(
                    jsonEncode({
                      'tx': store.data.transactions
                          .map((t) => t.toJson())
                          .toList(),
                      'accounts': store.data.accounts
                          .map((a) => a.toJson())
                          .toList(),
                      'agent': store.data.agent,
                      'goals': store.data.goals,
                      'range': [
                        analysisRange.start.toIso8601String(),
                        analysisRange.end.toIso8601String(),
                      ],
                      'model': settings['model'],
                      'provider': provider,
                    }),
                  ),
                )
                .toString();
      if (cacheKey != null &&
          store.data.extras['analysisCache'] is Map &&
          store.data.extras['analysisCache'][cacheKey] != null) {
        await _appendReply(
          store.data.extras['analysisCache'][cacheKey],
          report: true,
        );
        return;
      }
      final messages = <Json>[
        {'role': 'system', 'content': _systemPrompt(analysisRange)},
        ...conversation
            .skip(conversation.length > 30 ? conversation.length - 30 : 0)
            .map((m) => {'role': m['role'], 'content': m['content']}),
      ];
      requestClient = createClient();
      _client = requestClient;
      for (var round = 0; round < 6; round++) {
        if (generation != _generation) return;
        store.setAiStatus(round == 0 ? '正在思考…' : '整理分析结果…');
        store.log('request', '${settings['model']} · 第 ${round + 1} 轮');
        final response = await requestClient
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $authorization',
              },
              body: jsonEncode({
                'model': settings['model'],
                'messages': messages,
                'temperature': .5,
                'stream': false,
                'tools': toolDefinitions,
              }),
            )
            .timeout(const Duration(seconds: 60));
        if (generation != _generation) return;
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw FormatException(switch (response.statusCode) {
            401 => 'API 密钥无效或已过期',
            403 => '模型访问权限不足',
            429 => '请求过于频繁或额度不足，请稍后重试',
            _ => 'AI 服务暂不可用（${response.statusCode}）',
          });
        }
        final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
        if (body['choices'] is! List || (body['choices'] as List).isEmpty) {
          throw const FormatException('模型没有返回有效响应');
        }
        final message = Json.from(body['choices'][0]['message']);
        final calls = message['tool_calls'] as List? ?? [];
        if (calls.isEmpty) {
          final content = (message['content'] ?? '').toString().trim();
          if (content.isEmpty) throw const FormatException('模型返回了空内容，请重试或更换模型');
          await _appendReply(content, report: analysisRange != null);
          if (cacheKey != null) {
            await store.change(
              (d) => d.extras['analysisCache'] = {cacheKey: content},
            );
          }
          store.log('response', '顾问回复已保存');
          return;
        }
        messages.add({
          'role': 'assistant',
          'content': message['content'],
          'tool_calls': calls,
        });
        for (final raw in calls) {
          if (generation != _generation) return;
          final call = Json.from(raw);
          final function = Json.from(call['function']);
          final name = '${function['name']}';
          store.setAiStatus(toolLabels[name] ?? '查询数据…');
          Json result;
          try {
            final args = Json.from(jsonDecode(function['arguments'] ?? '{}'));
            result = await executeTool(name, args);
          } catch (e) {
            result = {
              'error': e is FormatException ? e.message : '参数不合法，操作未完成',
            };
          }
          store.log(
            'tool',
            '$name · ${result.containsKey('error') ? '未完成' : '已完成'}',
          );
          messages.add({
            'role': 'tool',
            'tool_call_id': call['id'],
            'content': jsonEncode(result),
          });
        }
      }
      throw const FormatException('本次分析步骤过多，请缩小问题范围后重试');
    } on TimeoutException {
      if (generation == _generation) error = '连接超时，请检查网络后重试';
    } catch (e) {
      if (generation == _generation) {
        error = e is FormatException ? e.message : '请求失败，请检查网络和服务地址后重试';
      }
    } finally {
      requestClient?.close();
      if (generation == _generation) {
        if (error != null) store.log('error', error!);
        store.setAiStatus(null);
      }
    }
  }

  Future<void> _appendReply(String content, {bool report = false}) =>
      store.change((d) {
        final cutoff = DateTime.now().subtract(const Duration(days: 365));
        d.chats.removeWhere((m) => localDate(m['timestamp']).isBefore(cutoff));
        d.chats.add({
          'id': newId(),
          'role': 'assistant',
          'content': content,
          'isReport': report,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      });
  Future<void> retryLast() async {
    if (lastPrompt != null) {
      await send(
        lastPrompt!,
        analysisRange: lastRange,
        retry: _lastPromptStored,
      );
    }
  }

  String _systemPrompt(DateRange? range) =>
      '''你是${store.data.agent['name']}，一个中文个人财务助手。
当前本地时间：${DateTime.now().toIso8601String()}。语气：${store.data.agent['tone']}。
原则：仅用工具提供的真实数据进行分析；不编造账单或操作；转账不计入收支；不推荐具体投资产品；不透露 API 密钥；不擅自变更账单。
用户画像：${jsonEncode({'name': store.data.profile['name'], 'description': store.data.agent['description'], 'tags': store.data.agent['tags'], 'insights': store.data.agent['insights'], 'preferences': store.data.agent['preferences'], 'focusAreas': store.data.agent['focusAreas']})}
用户自定义指引：${store.data.agent['customPrompt'] ?? ''}
${range == null ? '' : '此次分析限定范围：${range.start.toIso8601String()}（含）至 ${range.end.toIso8601String()}（不含）。请按范围查询，不使用今日数据代替历史数据。'}
初次交流可逐步了解用户目标。只有用户明确告知的新信息才保存为认知或记忆，不将推测当事实。每次称“已记住”必须实际调用保存工具成功。
回答简洁、具体，金额保留两位小数。给出数据观察和可执行建议。''';

  Future<Json> executeTool(String name, Json args) async {
    final now = DateTime.now();
    switch (name) {
      case 'get_financial_status':
        return {
          'netWorth': store.netWorth / 100,
          'assets': store.assets / 100,
          'liabilities': store.liabilities / 100,
          for (final p in Period.values)
            p.name: {
              'income':
                  store.total(
                    TxType.income,
                    range: DateRange.forPeriod(p, now),
                  ) /
                  100,
              'expense':
                  store.total(
                    TxType.expense,
                    range: DateRange.forPeriod(p, now),
                  ) /
                  100,
              'count': store.query(range: DateRange.forPeriod(p, now)).length,
            },
        };
      case 'query_tx':
        final start = args['start_date'] == null
            ? DateTime(now.year, now.month)
            : localDate(args['start_date']);
        final end = args['end_date'] == null
            ? now.add(const Duration(seconds: 1))
            : localDate(args['end_date']);
        if (!end.isAfter(start)) throw const FormatException('结束时间必须晚于开始时间');
        final type = args['type'] == null
            ? null
            : TxType.values.byName(args['type']);
        final txs = store.query(
          range: DateRange(start, end),
          type: type,
          category: args['category'],
        );
        return {
          'startInclusive': start.toIso8601String(),
          'endExclusive': end.toIso8601String(),
          'count': txs.length,
          'income': store.total(TxType.income, transactions: txs) / 100,
          'expense': store.total(TxType.expense, transactions: txs) / 100,
          'transactions': txs
              .take(200)
              .map(
                (t) => {
                  'title': t.title,
                  'type': t.type.name,
                  'category': t.category,
                  'amount': t.amount / 100,
                  'date': t.date.toIso8601String(),
                  'account': store.account(t.accountId)?.name,
                  'from': store.account(t.fromId)?.name,
                  'to': store.account(t.toId)?.name,
                  'note': t.note,
                },
              )
              .toList(),
          'truncated': txs.length > 200,
        };
      case 'get_accounts_overview':
        return {
          'assets': store.assets / 100,
          'liabilities': store.liabilities / 100,
          'netWorth': store.netWorth / 100,
          'accounts': store.data.accounts
              .map(
                (a) => {
                  'name': a.name,
                  'category': a.category,
                  'balance': store.balance(a) / 100,
                  'creditLimit': a.creditLimit / 100,
                  'includeInTotal': a.includeInTotal,
                  'archived': a.archived,
                },
              )
              .toList(),
        };
      case 'get_user_profile':
        return {
          'name': store.data.profile['name'],
          'cognition': store.data.agent,
          'goals': store.data.goals,
        };
      case 'get_self_model':
        return {
          'name': store.data.agent['name'],
          'role': '个人财务助手',
          'tone': store.data.agent['tone'],
          'principles': ['使用真实账本', '尊重隐私', '不改写交易', '不编造能力', '事实与推测分开'],
          'preferences': store.data.agent['preferences'],
        };
      case 'get_chat_history':
        final groups = <String, List<Json>>{};
        for (final m in store.data.chats) {
          groups
              .putIfAbsent(dayKey(localDate(m['timestamp'])), () => [])
              .add(m);
        }
        if (args['date'] != null) {
          return {'date': args['date'], 'messages': groups[args['date']] ?? []};
        }
        return {
          'sessions': (groups.keys.toList()..sort((a, b) => b.compareTo(a)))
              .take(7)
              .map(
                (day) => {
                  'date': day,
                  'messageCount': groups[day]!.length,
                  'topics': groups[day]!
                      .where((m) => m['role'] == 'user')
                      .map((m) => m['content'])
                      .take(5)
                      .toList(),
                },
              )
              .toList(),
        };
      case 'detect_anomaly':
        final txs = store.query(
          type: TxType.expense,
          range: DateRange(
            now.subtract(const Duration(days: 30)),
            now.add(const Duration(seconds: 1)),
          ),
        );
        final amounts = txs.map((t) => t.amount).toList()..sort();
        if (amounts.length < 5) {
          return {'message': '样本不足，需要至少 5 笔支出', 'anomalies': []};
        }
        final threshold = amounts[amounts.length ~/ 2] * 3;
        return {
          'rule': '近30天支出中位数的3倍以上（仅提示，不代表错误）',
          'threshold': threshold / 100,
          'anomalies': txs
              .where((t) => t.amount > threshold)
              .map(
                (t) => {
                  'title': t.title,
                  'amount': t.amount / 100,
                  'date': t.date.toIso8601String(),
                },
              )
              .toList(),
        };
      case 'update_user_cognition':
        await store.change((d) {
          for (final field in ['tags', 'insights']) {
            final current = List<String>.from(d.agent[field] ?? []);
            for (final item in args['add_$field'] as List? ?? []) {
              if (item is String &&
                  item.trim().isNotEmpty &&
                  !current.contains(item.trim())) {
                current.add(item.trim());
              }
            }
            final removed = args['remove_$field'] as List? ?? [];
            current.removeWhere((s) => removed.contains(s));
            d.agent[field] = current;
          }
          if (args['description'] is String) {
            d.agent['description'] = args['description'];
          }
          _event(d, '更新用户认知');
        });
        return {'saved': true};
      case 'learn_behavior':
        if (args['preference'] is! String ||
            '${args['preference']}'.trim().isEmpty) {
          throw const FormatException('偏好不能为空');
        }
        await store.change((d) {
          final p = List<dynamic>.from(d.agent['preferences'] ?? []);
          if (!p.contains(args['preference'])) p.add(args['preference']);
          d.agent['preferences'] = p;
          _event(d, '学习交互偏好');
        });
        return {'saved': true};
      case 'add_memory':
        if (args['fact'] is! String || '${args['fact']}'.trim().isEmpty) {
          throw const FormatException('记忆内容不能为空');
        }
        await store.change((d) {
          final memories = List<dynamic>.from(d.agent['memories'] ?? []);
          memories.add({
            'id': newId(),
            'fact': args['fact'],
            'importance': args['importance'] ?? 'medium',
            'sourceTimestamp': now.millisecondsSinceEpoch,
          });
          d.agent['memories'] = memories;
          _event(d, '保存一条记忆');
        });
        return {'saved': true};
      case 'update_plan':
        if (args['description'] is! String ||
            '${args['description']}'.trim().isEmpty) {
          throw const FormatException('目标描述不能为空');
        }
        final status = args['status'] ?? 'active';
        if (!['active', 'completed', 'paused', 'abandoned'].contains(status)) {
          throw const FormatException('目标状态无效');
        }
        await store.change((d) {
          final i = d.goals.indexWhere((g) => g['id'] == args['id']);
          final goal = {
            'id': args['id'] ?? newId(),
            'description': args['description'],
            'status': status,
            'updatedAt': now.toIso8601String(),
          };
          if (i < 0) {
            d.goals.add(goal);
          } else {
            d.goals[i] = {...d.goals[i], ...goal};
          }
          _event(d, '更新财务目标');
        });
        return {'saved': true};
      default:
        return {'error': '不支持此工具，未执行任何操作'};
    }
  }

  void _event(WalletData d, String title) {
    final events = List<dynamic>.from(d.agent['events'] ?? []);
    events.insert(0, {
      'id': newId(),
      'title': title,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    d.agent['events'] = events.take(300).toList();
  }
}

Uri endpoint(String base) {
  final uri = Uri.tryParse(base.trim().replaceAll(RegExp(r'/+$'), ''));
  if (uri == null ||
      uri.host.isEmpty ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('服务地址不合法');
  }
  if (uri.scheme == 'http' &&
      !['localhost', '127.0.0.1', '10.0.2.2'].contains(uri.host)) {
    throw const FormatException('远程服务地址须使用 HTTPS');
  }
  return uri.path.endsWith('/chat/completions')
      ? uri
      : Uri.parse('$uri/chat/completions');
}

String zhipuToken(String key) {
  final parts = key.split('.');
  final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(dynamic data) =>
      base64UrlEncode(utf8.encode(jsonEncode(data))).replaceAll('=', '');
  final message =
      '${encode({'alg': 'HS256', 'sign_type': 'SIGN'})}.${encode({'api_key': parts[0], 'exp': seconds + 3600, 'timestamp': seconds})}';
  final signature = Hmac(
    sha256,
    utf8.encode(parts[1]),
  ).convert(utf8.encode(message));
  return '$message.${base64UrlEncode(signature.bytes).replaceAll('=', '')}';
}

const toolLabels = {
  'get_financial_status': '汇总收支…',
  'query_tx': '查询账单…',
  'get_accounts_overview': '读取账户…',
  'get_user_profile': '读取目标与画像…',
  'get_self_model': '读取顾问设置…',
  'get_chat_history': '查询历史对话…',
  'detect_anomaly': '检测异常支出…',
  'update_user_cognition': '保存用户认知…',
  'learn_behavior': '保存交互偏好…',
  'add_memory': '保存记忆…',
  'update_plan': '更新目标…',
};
Json _tool(
  String name,
  String description,
  Json properties, [
  List<String> required = const [],
]) => {
  'type': 'function',
  'function': {
    'name': name,
    'description': description,
    'parameters': {
      'type': 'object',
      'properties': properties,
      'required': required,
    },
  },
};
final toolDefinitions = <Json>[
  _tool('get_financial_status', '查询当前净资产与日周月年收支，转账不计入收支', {}),
  _tool('query_tx', '查询日期范围内账单与完整汇总，最多返回200条明细。end_date不含边界', {
    'start_date': {'type': 'string'},
    'end_date': {'type': 'string'},
    'type': {
      'type': 'string',
      'enum': ['expense', 'income', 'transfer'],
    },
    'category': {'type': 'string'},
  }),
  _tool('get_accounts_overview', '查询所有账户余额与计入总资产状态', {}),
  _tool('get_user_profile', '查询用户画像、目标和记忆', {}),
  _tool('get_self_model', '查询顾问身份、原则与偏好', {}),
  _tool('get_chat_history', '查询历史对话；提供date返回该日详情', {
    'date': {'type': 'string'},
  }),
  _tool('detect_anomaly', '根据实际支出检测大额异常', {}),
  _tool('update_user_cognition', '保存用户明确告知的信息；可添加或删除标签洞察', {
    'description': {'type': 'string'},
    for (final key in [
      'add_tags',
      'remove_tags',
      'add_insights',
      'remove_insights',
    ])
      key: {
        'type': 'array',
        'items': {'type': 'string'},
      },
  }),
  _tool(
    'learn_behavior',
    '保存用户明确告知的交互偏好',
    {
      'preference': {'type': 'string'},
    },
    ['preference'],
  ),
  _tool(
    'add_memory',
    '保存用户明确告知的事实',
    {
      'fact': {'type': 'string'},
      'importance': {
        'type': 'string',
        'enum': ['core', 'high', 'medium', 'low'],
      },
    },
    ['fact'],
  ),
  _tool(
    'update_plan',
    '创建或修改用户确认的财务目标',
    {
      'id': {'type': 'string'},
      'description': {'type': 'string'},
      'status': {
        'type': 'string',
        'enum': ['active', 'completed', 'paused', 'abandoned'],
      },
    },
    ['description'],
  ),
];
