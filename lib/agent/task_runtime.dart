import '../data/wallet_store.dart';
import '../application/preference_changes.dart';
import '../domain/command_context.dart';
import '../domain/models.dart';
import '../domain/history_retention.dart';
import '../domain/query_contracts.dart';

enum TaskState {
  preparing,
  needsInput,
  ready,
  applying,
  completed,
  interrupted,
  cancelled,
  failed,
}

sealed class NodeOutcome {
  const NodeOutcome();
}

class ContinueNode extends NodeOutcome {
  final String nextNode;
  const ContinueNode(this.nextNode);
}

class NeedInput extends NodeOutcome {
  final String interactionId;
  const NeedInput(this.interactionId);
}

class Ready extends NodeOutcome {
  final String planId;
  const Ready(this.planId);
}

class Complete extends NodeOutcome {
  final String resultRef;
  const Complete(this.resultRef);
}

class Interrupt extends NodeOutcome {
  final String reason;
  const Interrupt(this.reason);
}

class Fail extends NodeOutcome {
  final ErrorEnvelope error;
  const Fail(this.error);
}

/// Persistent task identity and checkpoints are independent of chat messages.
class TaskRuntime {
  final WalletStore store;
  TaskRuntime(this.store);
  List<Json> get tasks => (store.data.extras['tasks'] as List? ?? [])
      .map((v) => Json.from(v))
      .toList();
  Json get(String id) => tasks.firstWhere(
    (t) => t['id'] == id,
    orElse: () => throw const FormatException('任务不存在'),
  );

  Future<String> start(
    String goal, {
    String? taskId,
    String source = 'chat',
    String? sessionId,
  }) async {
    final id = taskId ?? newId();
    await store.changeMetadata(
      (d) => startOn(
        d,
        goal,
        id: id,
        epoch: store.ledgerEpoch,
        source: source,
        sessionId: sessionId,
      ),
    );
    return id;
  }

  static void startOn(
    WalletMetadata d,
    String goal, {
    required String id,
    required String epoch,
    String source = 'chat',
    String? sessionId,
  }) {
    final list = (d.extras['tasks'] as List? ?? []);
    final existing = list.where((t) => t['id'] == id).firstOrNull;
    if (existing != null) {
      _epoch(existing, epoch);
      if (['completed', 'cancelled'].contains(existing['state'])) {
        throw const FormatException('任务已结束，请开始新任务');
      }
      existing['state'] = TaskState.preparing.name;
    } else {
      list.add({
        'id': id,
        'goal': goal,
        'source': source,
        'sessionId': sessionId,
        'ledgerEpoch': epoch,
        'state': TaskState.preparing.name,
        'attempts': 0,
        'toolCalls': 0,
        'createdAt': DateTime.now().toIso8601String(),
      });
    }
    d.extras['tasks'] = list;
    pruneTasks(d);
  }

  final _counts = <String, Map<String, int>>{};
  void committed() {
    final current = {for (final task in tasks) task['id']: task};
    _counts.removeWhere(
      (id, _) =>
          current[id] == null ||
          current[id]!['ledgerEpoch'] != store.ledgerEpoch ||
          !['preparing', 'applying'].contains(current[id]!['state']),
    );
  }

  // A crash can lose at most the current round's counters. Limits are enforced
  // in memory and checkpointed with that round, without a commit per tool.
  void flushCounts(WalletMetadata d, String id) {
    final counts = _counts[id];
    if (counts == null) return;
    final task = (d.extras['tasks'] as List).firstWhere((t) => t['id'] == id);
    _epoch(Json.from(task), store.ledgerEpoch);
    for (final entry in counts.entries) {
      task[entry.key] = entry.value;
    }
  }

  static void _epoch(Json task, String epoch) {
    if (task['ledgerEpoch'] != epoch) {
      throw const ErrorEnvelope(
        ErrorCode.stalePlan,
        '账本已恢复，请重新准备任务',
        phase: 'task',
      );
    }
  }

  Future<void> checkpoint(String id, TaskState state, {String? resultRef}) =>
      store.changeMetadata((d) {
        flushCounts(d, id);
        final list = (d.extras['tasks'] as List? ?? []);
        final task = list.firstWhere((t) => t['id'] == id);
        _epoch(task, store.ledgerEpoch);
        if (['completed', 'cancelled'].contains(task['state'])) return;
        task['state'] = state.name;
        if (resultRef != null) task['resultRef'] = resultRef;
        d.extras['tasks'] = list;
        pruneTasks(d);
      });

  Future<void> consume(String id, {bool modelRound = false}) async {
    final task = get(id);
    _epoch(task, store.ledgerEpoch);
    if (task['state'] != 'preparing') {
      throw const ErrorEnvelope(ErrorCode.interrupted, '任务正在等待用户或已经停止');
    }
    final counts = _counts.putIfAbsent(
      id,
      () => {
        'attempts': task['attempts'] as int? ?? 0,
        'toolCalls': task['toolCalls'] as int? ?? 0,
      },
    );
    final key = modelRound ? 'attempts' : 'toolCalls';
    final next = counts[key]! + 1;
    if (next > (modelRound ? 12 : 40)) {
      throw const ErrorEnvelope(
        ErrorCode.limitExceeded,
        '本次处理已达到上限，请在任务页选择继续',
        phase: 'task',
      );
    }
    counts[key] = next;
  }

  Future<void> continueTask(String id) => store.changeMetadata((d) {
    final tasks = (d.extras['tasks'] as List? ?? []);
    final task = tasks.firstWhere((t) => t['id'] == id);
    _epoch(task, store.ledgerEpoch);
    if (['completed', 'cancelled'].contains(task['state'])) {
      throw const FormatException('任务已结束');
    }
    task['totalAttempts'] =
        (task['totalAttempts'] as int? ?? 0) + (task['attempts'] as int? ?? 0);
    _counts.remove(id);
    task['attempts'] = 0;
    task['toolCalls'] = 0;
    task['recipeFailures'] = 0;
    task['state'] = 'preparing';
    d.extras['tasks'] = tasks;
    pruneTasks(d);
  });

  Future<Json> request(String taskId, Json input) async {
    final fields = input['fields'];
    if (fields is! List || fields.isEmpty || fields.length > 3) {
      throw const FormatException('一次补充 1 至 3 个相关字段');
    }
    final keys = <String>{};
    for (final field in fields) {
      if (field is! Map ||
          field.keys.any(
            (k) => !['key', 'type', 'label', 'required'].contains(k),
          ) ||
          ![
            'accountId',
            'transferFromId',
            'transferToId',
            'amountCents',
            'date',
            'title',
            'category',
          ].contains(field['key']) ||
          !keys.add(field['key']) ||
          !['accountChoice', 'text', 'cents', 'date'].contains(field['type'])) {
        throw const FormatException('无效的补充字段');
      }
    }
    Json? result;
    await store.changeMetadata((d) {
      final list = (d.extras['tasks'] as List? ?? []);
      final task = list.firstWhere((t) => t['id'] == taskId);
      _epoch(task, store.ledgerEpoch);
      final previous = task['interaction'] as Map?;
      result = {
        'interactionId': previous?['interactionId'] ?? newId(),
        'taskId': taskId,
        'revision': (previous?['revision'] as int? ?? 0) + 1,
        'kind': 'clarify',
        'title': input['title'],
        'reason': input['reason'] ?? '',
        'fields': fields
            .map(
              (f) => {
                ...Json.from(f),
                if (f['type'] == 'accountChoice')
                  'options': store.activeAccounts
                      .map((a) => {'value': a.id, 'label': a.name})
                      .toList(),
              },
            )
            .toList(),
        'knownFields': input['knownFields'] ?? {},
        'allowFreeText': true,
        'submitLabel': '继续准备',
        'cancelLabel': '暂不处理',
      };
      task['interaction'] = result;
      task['state'] = 'needsInput';
      d.extras['tasks'] = list;
      pruneTasks(d);
    });
    return {'ok': true, 'status': 'needsInput', 'interaction': result};
  }

  Future<Json> respond(
    String taskId,
    String interactionId,
    int revision,
    Json values,
  ) async {
    Json? answer;
    await store.changeMetadata((d) {
      final list = (d.extras['tasks'] as List? ?? []);
      final task = list.firstWhere((t) => t['id'] == taskId);
      _epoch(task, store.ledgerEpoch);
      final interaction = task['interaction'];
      if (task['state'] != 'needsInput' ||
          interaction?['interactionId'] != interactionId ||
          interaction?['revision'] != revision) {
        throw const ErrorEnvelope(
          ErrorCode.staleInteraction,
          '问题已更新，请保留输入并重新查看',
        );
      }
      final allowed = (interaction['fields'] as List)
          .map((f) => f['key'])
          .toSet();
      if (values.keys.any((key) => !allowed.contains(key))) {
        throw const FormatException('包含未请求的字段');
      }
      for (final field in interaction['fields']) {
        final value = values[field['key']];
        if (field['required'] != false &&
            (value == null || '$value'.trim().isEmpty)) {
          throw const FormatException('请补全必填字段');
        }
        if (value != null &&
            field['type'] == 'accountChoice' &&
            !store.activeAccounts.any((a) => a.id == value)) {
          throw const FormatException('请选择有效账户');
        }
      }
      answer = {...Json.from(interaction['knownFields'] ?? {}), ...values};
      task['answers'] = answer;
      task['interaction'] = null;
      task['state'] = 'preparing';
      d.extras['tasks'] = list;
      pruneTasks(d);
    });
    return answer!;
  }

  Future<Json> preparePreference(String taskId, String tool, Json args) async {
    final trial = store.data.cloneMetadata();
    PreferenceChanges.apply(trial, tool, args);
    Json? request;
    await store.changeMetadata((d) {
      final task = (d.extras['tasks'] as List).firstWhere(
        (t) => t['id'] == taskId,
      );
      _epoch(Json.from(task), store.ledgerEpoch);
      request = {
        'id': newId(),
        'tool': tool,
        'args': args,
        'beforeHash': digest(PreferenceChanges.state(d, tool)),
        'before': PreferenceChanges.state(d, tool),
        'summary': PreferenceChanges.summary(d, tool, args),
      };
      task['preferenceReview'] = request;
      task['state'] = 'ready';
    });
    return {
      'status': 'prepared',
      'requiresUserConfirmation': true,
      'taskId': taskId,
      'reviewId': request!['id'],
    };
  }

  Future<void> applyPreference(
    String taskId,
    String reviewId,
  ) => store.changeMetadata((d) {
    final task = (d.extras['tasks'] as List).firstWhere(
      (t) => t['id'] == taskId,
    );
    _epoch(Json.from(task), store.ledgerEpoch);
    final review = task['preferenceReview'];
    if (review?['id'] != reviewId) throw const FormatException('方案已更新，请重新审阅');
    if (review['receipt'] != null) return;
    if (task['state'] != 'ready' ||
        digest(PreferenceChanges.state(d, review['tool'])) !=
            review['beforeHash']) {
      throw const FormatException('相关信息已变化，请重新准备');
    }
    PreferenceChanges.apply(d, review['tool'], Json.from(review['args']));
    review['afterHash'] = digest(PreferenceChanges.state(d, review['tool']));
    review['receipt'] = {
      'id': newId(),
      'operationId': reviewId,
      'status': 'applied',
      'createdAt': DateTime.now().toIso8601String(),
    };
    task['state'] = 'completed';
    pruneTasks(d);
  });

  Future<void> undoPreference(String taskId, String reviewId) =>
      store.changeMetadata((d) {
        final task = (d.extras['tasks'] as List).firstWhere(
          (t) => t['id'] == taskId,
        );
        _epoch(Json.from(task), store.ledgerEpoch);
        final review = task['preferenceReview'];
        if (review?['id'] != reviewId ||
            review['receipt']?['status'] != 'applied') {
          throw const FormatException('没有可撤销的回执');
        }
        if (digest(PreferenceChanges.state(d, review['tool'])) !=
            review['afterHash']) {
          throw const FormatException('信息后来有修改，不能直接撤销');
        }
        final before = review['before'];
        if (before['agent'] != null) d.agent = Json.from(before['agent']);
        if (before['goals'] != null) {
          d.goals = (before['goals'] as List).map((g) => Json.from(g)).toList();
        }
        review['receipt']['status'] = 'undone';
      });

  Future<void> recover() async {
    if (!tasks.any((t) => ['preparing', 'applying'].contains(t['state']))) {
      return;
    }
    await store.changeMetadata((d) {
      for (final task in d.extras['tasks'] as List? ?? []) {
        if (['preparing', 'applying'].contains(task['state'])) {
          task['state'] = 'interrupted';
        }
      }
    });
  }
}
