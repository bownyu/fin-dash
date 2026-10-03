import '../application/capabilities.dart';
import '../application/ledger_queries.dart';
import '../application/preference_changes.dart';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/query_contracts.dart';
import 'query_recipe.dart';
import 'task_runtime.dart';
import 'prompts.dart';

class CapabilityHost {
  final WalletStore store;
  final TaskRuntime runtime;
  final String? Function() activeTask;
  final Future<Json> Function(String, Json) legacy;
  final bool Function() cancelled;
  final registry = CapabilityRegistry();
  final recipes =
      <
        String,
        ({QueryRecipe program, String taskId, String epoch, int revision})
      >{};
  CapabilityHost(
    this.store,
    this.runtime,
    this.activeTask,
    this.legacy,
    this.cancelled,
    List<Json> legacyTools,
  ) {
    for (final tool in legacyTools) {
      final f = tool['function'], name = f['name'] as String;
      registry.register(
        CapabilityDefinition(
          id: name,
          name: name,
          description: PreferenceChanges.tools.contains(name)
              ? '准备待审阅的信息变更；必须由用户在本地确认后保存'
              : f['description'],
          effect:
              name.startsWith('propose_') ||
                  name == 'revise_changes' ||
                  PreferenceChanges.tools.contains(name)
              ? CapabilityEffect.prepare
              : CapabilityEffect.read,
          inputSchema: Json.from(f['parameters']),
          execute: (args) async {
            if (store.data.settings['locked'] == true) {
              throw const ErrorEnvelope(ErrorCode.locked, '账本已锁定，请先解锁');
            }
            if (PreferenceChanges.tools.contains(name)) {
              return runtime.preparePreference(await task(), name, args);
            }
            final result = await legacy(name, args);
            if ([
              'get_financial_status',
              'query_tx',
              'get_accounts_overview',
              'detect_anomaly',
            ].contains(name)) {
              result['units'] = {
                'currency': 'CNY',
                'legacyMoneyFields': 'yuan',
                'centsFields': 'integerCents',
              };
              result['snapshot'] = {
                'ledgerEpoch': store.ledgerEpoch,
                'revision': store.ledgerRevision,
              };
            }
            return result;
          },
        ),
      );
    }
    void add(
      String id,
      String name,
      String description,
      Json schema,
      Future<Json> Function(Json) run, {
      CapabilityEffect effect = CapabilityEffect.read,
    }) {
      registry.register(
        CapabilityDefinition(
          id: id,
          name: name,
          description: description,
          effect: effect,
          inputSchema: schema,
          execute: (args) {
            if (store.data.settings['locked'] == true &&
                !['app.describe', 'capabilities.search'].contains(id)) {
              throw const ErrorEnvelope(ErrorCode.locked, '账本已锁定，请先解锁');
            }
            return run(args);
          },
        ),
      );
    }

    const text = {'type': 'string'};
    add(
      'app.describe',
      'app_describe',
      '查询实际应用机制、指标、数据字段和程序语法',
      objectSchema({}),
      (_) async => {
        'appSpecVersion': PromptAssembler.appSpecVersion,
        'capabilityVersion': CapabilityRegistry.version,
        'appSpec': PromptAssembler.appSpec,
        'datasets': LedgerQueries.datasets,
        'timezones': ['local', 'UTC'],
        'recipeLanguage': {
          'version': 1,
          'operators': RecipeOperator.values.map((v) => v.name).toList(),
          'limits': {
            'steps': 24,
            'scanRows': 50000,
            'outputRows': 200,
            'outputBytes': 65536,
          },
          'shape':
              '{languageVersion:1,name,description,parameters:{name:{type,required}},steps:[{id,op,...}],output:{from,fields}}',
          'values':
              '{literal:value} or {param:name}; predicates: {field,eq/ne/in/inRange/lt/lte/gt/gte/isNull/contains:valueNode}, {and:[predicates]} or {or:[predicates]}',
          'steps': {
            'scan': 'dataset,fields,where?',
            'filter': 'from,where',
            'calendar':
                'from,field,timezone:valueNode,components:[weekday/localHour/day/month]',
            'group':
                'from,keys,aggregates:{name:{count:* / sumCents:field / minCents:field / maxCents:field}}',
            'derive':
                'from,fields:{name:{op:add/subtract/multiply/divide,args:[value/field/expression,value/field/expression]}}',
            'compare': 'left,right,keys,field; ratio=(right-left)/left',
            'sort': 'from,by:[{field,direction:asc/desc}]',
            'take': 'from,count',
            'project': 'from,fields',
          },
        },
        'limitations': ['没有银行资金操作能力', '历史余额不支持', '未知历史时间精度不能用于精确时刻分析'],
      },
    );
    add(
      'capabilities.search',
      'capabilities_search',
      '按关键词发现能力和参数',
      objectSchema({'query': text}),
      (a) async => {'capabilities': registry.search(a['query'] ?? '')},
    );
    final query = objectSchema({
      'startInclusive': text,
      'endExclusive': text,
      'accountId': text,
      'categoryId': text,
      'type': {
        'type': 'string',
        'enum': ['expense', 'income', 'transfer'],
      },
      'cursor': text,
      'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
    });
    add(
      'ledger.query',
      'ledger_query',
      '分页读取账单，结果带范围、快照、完整性与来源',
      query,
      (a) async => (await LedgerQueries(store).queryAsync(a)).toJson(),
    );
    add(
      'ledger.aggregate',
      'ledger_aggregate',
      '整个范围整数分收支汇总，转账不计入收支',
      query,
      (a) async =>
          (await LedgerQueries(store).queryAsync(a, aggregate: true)).toJson(),
    );
    add(
      'categories.list',
      'categories_list',
      '读取分类稳定 ID 与名称',
      objectSchema({}),
      (_) async => {
        'categories': LedgerQueries(store).rows('ledger.categories').toList(),
      },
    );
    add(
      'tasks.get',
      'tasks_get',
      '读取当前任务的真实状态、问题和方案引用',
      objectSchema({}),
      (_) async => {'task': runtime.get(await task())},
    );
    add(
      'interaction.request',
      'interaction_request',
      '请求 1 至 3 个缺失字段；不会批准入账',
      objectSchema(
        {
          'title': text,
          'reason': text,
          'fields': {
            'type': 'array',
            'minItems': 1,
            'maxItems': 3,
            'items': {'type': 'object', 'additionalProperties': true},
          },
          'knownFields': {'type': 'object', 'additionalProperties': true},
        },
        ['title', 'fields'],
      ),
      (a) async => runtime.request(await task(), a),
      effect: CapabilityEffect.prepare,
    );
    add(
      'recipes.validate',
      'recipes_validate',
      '校验有类型、有预算的只读查询程序',
      objectSchema(
        {
          'recipe': {'type': 'object', 'additionalProperties': true},
        },
        ['recipe'],
      ),
      (a) async {
        final owner = await task();
        if ((runtime.get(owner)['recipeFailures'] as int? ?? 0) >= 3) {
          throw const ErrorEnvelope(
            ErrorCode.limitExceeded,
            '查询程序已修正 3 次，请调整需求后继续',
          );
        }
        late QueryRecipe program;
        try {
          program = QueryRecipe.parse(Json.from(a['recipe']));
        } catch (_) {
          await store.changeMetadata((d) {
            final t = (d.extras['tasks'] as List).firstWhere(
              (t) => t['id'] == owner,
            );
            t['recipeFailures'] = (t['recipeFailures'] as int? ?? 0) + 1;
          });
          rethrow;
        }
        if (recipes.length >= 40) {
          throw const ErrorEnvelope(ErrorCode.limitExceeded, '本次程序数量达到上限');
        }
        final id = newId();
        recipes[id] = (
          program: program,
          taskId: owner,
          epoch: store.ledgerEpoch,
          revision: store.ledgerRevision,
        );
        return {
          'ok': true,
          'recipeId': id,
          'languageVersion': 1,
          'outputSchema': program.steps.last.fields,
        };
      },
    );
    add(
      'recipes.run',
      'recipes_run',
      '在当前任务快照执行已验证程序',
      objectSchema(
        {
          'recipeId': text,
          'parameters': {'type': 'object', 'additionalProperties': true},
        },
        ['recipeId', 'parameters'],
      ),
      (a) async {
        final value = recipes[a['recipeId']];
        if (value == null || value.taskId != await task()) {
          throw const ErrorEnvelope(ErrorCode.forbidden, '程序不属于当前任务');
        }
        if (value.epoch != store.ledgerEpoch ||
            value.revision != store.ledgerRevision) {
          throw const ErrorEnvelope(ErrorCode.snapshotExpired, '账本已变化，请重新校验程序');
        }
        final result = await value.program.run(
          LedgerQueries(store),
          Json.from(a['parameters']),
          cancelled: cancelled,
        );
        final output = result.toJson();
        await store.changeMetadata((d) {
          final owner = (d.extras['tasks'] as List).firstWhere(
            (t) => t['id'] == value.taskId,
          );
          owner['result'] = output;
          owner['recipeProposal'] = {
            'recipe': value.program.source,
            'parameters': a['parameters'],
          };
        });
        return output;
      },
    );
  }
  Future<void> saveRecipe(String taskId) => store.changeMetadata((d) {
    final task = (d.extras['tasks'] as List).firstWhere(
      (t) => t['id'] == taskId,
    );
    final proposal = task['recipeProposal'];
    if (proposal == null) throw const FormatException('此任务没有可保存的分析程序');
    QueryRecipe.parse(Json.from(proposal['recipe']));
    final saved = List<Json>.from(d.extras['savedRecipes'] ?? []);
    if (saved.length >= 100) throw const FormatException('最多保存 100 个常用分析');
    if (saved.any((r) => r['taskId'] == taskId)) return;
    saved.add({
      'id': newId(),
      'taskId': taskId,
      'title': task['goal'],
      ...Json.from(proposal),
    });
    d.extras['savedRecipes'] = saved;
  });

  Future<Json> runSavedRecipe(String id) async {
    final value = (store.data.extras['savedRecipes'] as List? ?? []).firstWhere(
      (r) => r['id'] == id,
    );
    final program = QueryRecipe.parse(Json.from(value['recipe']));
    final result = await program.run(
      LedgerQueries(store),
      Json.from(value['parameters']),
    );
    return result.toJson();
  }

  String? _standaloneTask;
  Future<String> task() async {
    final current = activeTask();
    if (current != null) return current;
    return _standaloneTask ??= await runtime.start('独立能力调用');
  }
}
