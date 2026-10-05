import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/history_retention.dart';
import '../domain/agent_action_summary.dart';
import '../data/backup.dart';
import '../domain/ledger_operations.dart';
import '../domain/review_contracts.dart';

class AgentBatchReview {
  final Json batch;
  final List<Json> items;
  final Map<String, String> problems;
  final String token;
  const AgentBatchReview(this.batch, this.items, this.problems, this.token);
  List<Json> get pending =>
      items.where((a) => a['status'] == 'pending').toList();
  Map<String, Set<String>> get dependencies {
    final accounts = {
      for (final a in pending.where(
        (a) => a['kind'] == 'account' && a['before']['value'] == null,
      ))
        a['targetId']: a['id'] as String,
    };
    return {
      for (final a in pending.where((a) => a['kind'] == 'transaction'))
        a['id'] as String: {
          for (final field in ['accountId', 'transferFromId', 'transferToId'])
            if (accounts.containsKey(a['desired'][field]))
              accounts[a['desired'][field]]!,
        },
    };
  }

  Set<String> get suggested {
    final ids = pending
        .where(
          (a) => a['needsReview'] != true && !problems.containsKey(a['id']),
        )
        .map((a) => a['id'] as String)
        .toSet();
    final required = dependencies;
    ids.removeWhere((id) => !(required[id] ?? {}).every(ids.contains));
    return ids;
  }
}

/// Only the local review UI calls apply/undo. Neither is exposed as an AI tool.
class AgentActions {
  final WalletStore store;
  WalletData? _reviewData;
  final Map<String, AgentBatchReview> _reviewCache = {};
  Map<String, Json>? _reviewBatches;
  List<Json>? _cachedItems, _cachedBatches;
  void _checkCache() {
    if (identical(_reviewData, store.data)) return;
    _reviewData = store.data;
    _reviewCache.clear();
    _reviewBatches = null;
    _cachedItems = _cachedBatches = null;
  }

  AgentActions(this.store);

  List<Json> get items {
    _checkCache();
    return _cachedItems ??= List.unmodifiable(_items(store.data).reversed);
  }

  static List<Json> _items(WalletMetadata d) =>
      (d.extras['agentActions'] as List? ?? [])
          .map((e) => Json.from(e as Map))
          .toList();

  Future<Json> propose(
    String kind,
    Json input, {
    String? batchId,
    String? title,
    String? sessionId,
    String? sourceMessageId,
    String? sourceUserMessageId,
  }) async {
    if (batchId != null) {
      return proposeMany(
        [
          {'kind': kind, 'input': input},
        ],
        batchId: batchId,
        title: title ?? '账本变更方案',
        sessionId: sessionId ?? 'legacy',
        sourceMessageId: sourceMessageId,
        sourceUserMessageId: sourceUserMessageId,
      );
    }
    final args = Json.from(jsonDecode(jsonEncode(input)));
    Json? result;
    await store.change((d) {
      if (!['account', 'transaction', 'budget'].contains(kind)) {
        throw const FormatException('不支持的操作类型');
      }
      final actions = _items(d);
      for (final a in actions) {
        if (a['status'] == 'pending' &&
            a['kind'] == kind &&
            _same(a['input'], args)) {
          result = a;
          return;
        }
      }
      if (actions.where((a) => a['status'] == 'pending').length >= 2000) {
        throw const FormatException('待确认操作已达 2000 项，请先处理');
      }
      final id = args['id'] == null ? newId() : _text(args['id'], 'ID');
      final before = _state(d, kind, id);
      final after = _desired(d, kind, id, args);
      final trial = d.clone();
      _write(trial, kind, id, after);
      validateWallet(trial);
      final action = <String, dynamic>{
        'id': newId(),
        'kind': kind,
        'targetId': id,
        'input': args,
        'before': before,
        'desired': after,
        'status': 'pending',
        'createdAt': DateTime.now().toIso8601String(),
        'summary': args['reason'] is String ? args['reason'] : '请核对以下变更',
        'sessionId': d.extras['activeChatSessionId'] ?? 'legacy',
      };
      action['displaySummary'] = agentActionSummary(
        action,
        (id) => d.accounts.where((a) => a.id == id).firstOrNull?.name ?? id,
      );
      actions.add(action);
      d.extras['agentActions'] = actions;
      pruneActions(d);
      result = action;
    });
    return {
      'proposalId': result!['id'],
      'status': result!['status'],
      'requiresUserConfirmation': true,
      'preview': result!['desired'],
    };
  }

  static List<Json> _batches(WalletMetadata d) =>
      (d.extras['agentActionBatches'] as List? ?? [])
          .map((e) => Json.from(e as Map))
          .toList();

  /// Older proposals are grouped by their original reply without a write on read.
  List<Json> get batches {
    _checkCache();
    return _cachedBatches ??= List.unmodifiable(
      _allBatches(store.data).reversed,
    );
  }

  static List<Json> _allBatches(WalletData d) {
    final result = _batches(d);
    final owners = <String, Json>{};
    for (final message in d.chats) {
      if (message['role'] != 'assistant' ||
          message['isActionFeedback'] == true) {
        continue;
      }
      for (final id in messageProposalIds(message)) {
        owners.putIfAbsent(id, () => message);
      }
    }
    final legacy = <String, Json>{};
    for (final a in _items(d)) {
      if (a['batchId'] != null) continue;
      final owner = owners[a['id']];
      final session = a['sessionId'] ?? 'legacy';
      final id = 'legacy:$session:${owner?['id'] ?? a['id']}';
      final b = legacy.putIfAbsent(
        id,
        () => {
          'id': id,
          'sessionId': session,
          'sourceMessageId': owner?['id'],
          'title': '历史账本变更方案',
          'revision': 0,
          'generation':
              owner != null &&
                  ['error', 'cancelled', 'streaming'].contains(owner['status'])
              ? 'interrupted'
              : 'ready',
          'createdAt': a['createdAt'],
          'legacyIds': <String>[],
        },
      );
      (b['legacyIds'] as List).add(a['id']);
    }
    for (final b in legacy.values) {
      final applied = _items(d)
          .where(
            (a) =>
                (b['legacyIds'] as List).contains(a['id']) &&
                a['status'] == 'applied',
          )
          .toList();
      if (applied.isNotEmpty) {
        b['receipts'] = [
          {
            'id': '${b['id']}:applied',
            'actionIds': applied.map((a) => a['id']).toList(),
            'status': 'applied',
            'createdAt': b['createdAt'],
          },
        ];
      }
    }
    result.addAll(legacy.values);
    return result;
  }

  static Json _batch(WalletData d, String id) => _allBatches(d).firstWhere(
    (b) => b['id'] == id,
    orElse: () => throw const FormatException('方案不存在'),
  );

  static List<Json> _inBatch(WalletData d, Json batch) => _items(d)
      .where(
        (a) =>
            a['batchId'] == batch['id'] ||
            (batch['legacyIds'] as List? ?? []).contains(a['id']),
      )
      .toList();

  static String _token(Json batch, List<Json> actions) => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            _ordered({
              'revision': batch['revision'],
              'ledgerEpoch': batch['ledgerEpoch'],
              'generation': batch['generation'],
              'items': actions
                  .map(
                    (a) => {
                      'id': a['id'],
                      'status': a['status'],
                      'before': a['before'],
                      'desired': a['desired'],
                      'input': a['input'],
                      'needsReview': a['needsReview'],
                      'reviewNote': a['reviewNote'],
                    },
                  )
                  .toList(),
            }),
          ),
        ),
      )
      .toString();

  AgentBatchReview review(String id) {
    _checkCache();
    if (_reviewCache.containsKey(id)) return _reviewCache[id]!;
    final d = store.data;
    // One scan of the chat history per committed snapshot, not one per batch.
    // Reversed so the first batch with an id wins, as with firstWhere.
    _reviewBatches ??= {for (final b in batches.reversed) b['id']: b};
    final b = _reviewBatches![id] ?? (throw const FormatException('方案不存在'));
    final entries = _inBatch(d, b);
    final problems = <String, String>{};
    // Settled batches never touch the draft, so skip copying the wallet.
    late final draft = d.clone();
    for (final a in entries.where(
      (a) => a['status'] == 'pending' && a['kind'] == 'account',
    )) {
      _write(draft, 'account', a['targetId'], Json.from(a['desired']));
    }
    for (final a in entries.where((a) => a['status'] == 'pending')) {
      if (!_same(a['before'], _state(d, a['kind'], a['targetId']))) {
        problems[a['id']] = '相关数据已变化，请重新核对或排除这一项';
        continue;
      }
      try {
        final desired = _desired(
          a['kind'] == 'account' ? d : draft,
          a['kind'],
          a['targetId'],
          Json.from(a['input']),
        );
        if (!_same(desired, a['desired'])) {
          problems[a['id']] = '实际变更与原方案不同，请重新核对';
        }
      } on FormatException catch (e) {
        problems[a['id']] = e.message;
      }
    }
    return _reviewCache[id] = AgentBatchReview(
      b,
      entries,
      problems,
      _token(b, entries),
    );
  }

  static Json _materialize(WalletData d, String id) {
    final b = _batch(d, id);
    if (b.containsKey('legacyIds')) {
      final actions = _items(d);
      for (final a in actions) {
        if ((b['legacyIds'] as List).contains(a['id'])) a['batchId'] = id;
      }
      d.extras['agentActions'] = actions;
      pruneActions(d);
      b.remove('legacyIds');
      final list = _batches(d)..add(b);
      d.extras['agentActionBatches'] = list;
      pruneActions(d);
    }
    return b;
  }

  static void _saveBatch(WalletMetadata d, Json b) {
    final list = _batches(d);
    final index = list.indexWhere((x) => x['id'] == b['id']);
    if (index < 0) {
      list.add(b);
    } else {
      list[index] = b;
    }
    d.extras['agentActionBatches'] = list;
    pruneActions(d);
    final tasks = (d.extras['tasks'] as List? ?? [])
        .map((t) => Json.from(t))
        .toList();
    final taskId = b['taskId'] ??= newId();
    final task =
        tasks.where((t) => t['id'] == taskId).firstOrNull ??
        <String, dynamic>{
          'id': taskId,
          'goal': b['title'],
          'sessionId': b['sessionId'],
          'ledgerEpoch': b['ledgerEpoch'] ?? d.extras['ledgerEpoch'],
          'createdAt': b['createdAt'],
        };
    if (!tasks.contains(task)) tasks.add(task);
    task['planId'] = b['id'];
    final pending = _items(
      d,
    ).any((a) => a['batchId'] == b['id'] && a['status'] == 'pending');
    task['state'] = task['interaction'] != null && b['closed'] != true
        ? 'needsInput'
        : b['closed'] == true
        ? 'cancelled'
        : !pending && (b['receipts'] as List? ?? []).isNotEmpty
        ? 'completed'
        : b['generation'] == 'preparing'
        ? 'preparing'
        : b['generation'] == 'interrupted'
        ? 'interrupted'
        : 'ready';
    d.extras['tasks'] = tasks;
  }

  /// One tool call may prepare many changes; no approval is exposed to the model.
  Future<Json> proposeMany(
    List<Json> changes, {
    required String batchId,
    required String title,
    required String sessionId,
    String? sourceMessageId,
    String? sourceUserMessageId,
  }) async {
    if (changes.isEmpty || changes.length > 200) {
      throw const FormatException('每次请准备 1 至 200 项变更');
    }
    Json? output;
    await store.change((d) {
      if (batchId.startsWith('legacy:') &&
          _allBatches(
            d,
          ).any((b) => b['id'] == batchId && b.containsKey('legacyIds'))) {
        _materialize(d, batchId);
      }
      final batches = _batches(d);
      final b =
          batches.where((x) => x['id'] == batchId).firstOrNull ??
          <String, dynamic>{
            'id': batchId,
            'taskId':
                (d.extras['tasks'] as List? ?? []).any(
                  (t) => t['id'] == batchId,
                )
                ? batchId
                : newId(),
            'ledgerEpoch': d.extras['ledgerEpoch'],
            'title': title.substring(0, title.length > 80 ? 80 : title.length),
            'sessionId': sessionId,
            'sourceMessageId': sourceMessageId ?? batchId,
            'sourceUserMessageId': sourceUserMessageId,
            'revision': 0,
            'generation': 'preparing',
            'createdAt': DateTime.now().toIso8601String(),
          };
      if (b['sessionId'] != sessionId) {
        throw const FormatException('不能修改其他对话的方案');
      }
      if (b['closed'] == true || (b['receipts'] as List? ?? []).isNotEmpty) {
        throw const FormatException('此方案已有执行结果，请在新任务中准备剩余变更');
      }
      final actions = _items(d);
      final draft = d.clone();
      final refs = <String, String>{};
      for (final a in actions.where(
        (a) => a['batchId'] == batchId && a['status'] == 'pending',
      )) {
        if (a['localKey'] is String) refs[a['localKey']] = a['targetId'];
        if (a['kind'] == 'account') {
          _write(draft, 'account', a['targetId'], Json.from(a['desired']));
        }
      }
      final added = <Json>[];
      final ordered = [
        ...changes.where((c) => c['kind'] == 'account'),
        ...changes.where((c) => c['kind'] != 'account'),
      ];
      for (final change in ordered) {
        final kind = change['kind'];
        if (!['account', 'transaction', 'budget'].contains(kind) ||
            change['input'] is! Map) {
          throw const FormatException('变更须包含有效类型和内容');
        }
        final args = Json.from(jsonDecode(jsonEncode(change['input'])));
        if (args.containsKey('needsReview') && args['needsReview'] is! bool) {
          throw const FormatException('待核对标记必须为布尔值');
        }
        if (args.containsKey('reviewNote')) {
          _text(args['reviewNote'], '核对说明', empty: true);
        }
        final localKey = change['key'];
        if (localKey != null &&
            (localKey is! String ||
                localKey.isEmpty ||
                args['id'] != null ||
                kind == 'budget')) {
          throw const FormatException('任务内引用名称仅用于新增账户或账单');
        }
        for (final field in ['accountId', 'transferFromId', 'transferToId']) {
          if (args[field] is String &&
              (args[field] as String).startsWith('@')) {
            args[field] =
                refs[(args[field] as String).substring(1)] ??
                (throw const FormatException('账单引用的账户尚未准备，请先准备账户'));
          }
        }
        final target = kind == 'budget'
            ? 'budget'
            : args['id'] == null
            ? (localKey == null ? newId() : refs[localKey] ?? newId())
            : _text(args['id'], 'ID');
        final existing = actions
            .where(
              (a) =>
                  a['batchId'] == batchId &&
                  a['status'] == 'pending' &&
                  a['kind'] == kind &&
                  a['targetId'] == target,
            )
            .firstOrNull;
        if (existing != null) {
          final merged = {...Json.from(existing['input']), ...args};
          args.clear();
          args.addAll(merged);
        }
        final before = _state(d, kind, target);
        final desired = _desired(
          kind == 'account' ? d : draft,
          kind,
          target,
          args,
        );
        // New-record retries deduplicate by actual content, not the wording of a reason.
        final duplicate =
            existing ??
            actions
                .where(
                  (a) =>
                      a['batchId'] == batchId &&
                      a['status'] == 'pending' &&
                      a['kind'] == kind &&
                      _same(
                        {...Json.from(a['desired'])}..remove('id'),
                        {...desired}..remove('id'),
                      ) &&
                      args['id'] == null &&
                      localKey == null &&
                      kind != 'budget',
                )
                .firstOrNull;
        final a =
            duplicate ??
            <String, dynamic>{
              'id': newId(),
              'createdAt': DateTime.now().toIso8601String(),
            };
        final actualTarget = duplicate?['targetId'] ?? target;
        if (localKey != null &&
            refs.containsKey(localKey) &&
            duplicate == null) {
          throw const FormatException('任务内引用名称不能用于不同类型的记录');
        }
        if (actualTarget != target) desired['id'] = actualTarget;
        a.addAll({
          'kind': kind,
          'targetId': actualTarget,
          'input': args,
          'before': duplicate?['before'] ?? before,
          'desired': desired,
          'status': 'pending',
          'batchId': batchId,
          'sessionId': sessionId,
          'needsReview': args['needsReview'] == true,
          'reviewNote': args['reviewNote'] is String ? args['reviewNote'] : '',
          'summary': args['reason'] is String ? args['reason'] : '请核对以下变更',
          'localKey': ?localKey,
        });
        a['displaySummary'] = agentActionSummary(
          a,
          (id) =>
              draft.accounts.where((x) => x.id == id).firstOrNull?.name ?? id,
        );
        if (duplicate == null) actions.add(a);
        if (localKey != null) refs[localKey] = actualTarget;
        _write(draft, kind, actualTarget, desired);
        added.add(a);
      }
      if (actions.where((a) => a['status'] == 'pending').length > 2000) {
        throw const FormatException('待确认操作已达 2000 项，请先处理');
      }
      validateWallet(draft);
      b['revision'] = (b['revision'] as int) + 1;
      b['generation'] = 'preparing';
      if (sourceMessageId != null) b['sourceMessageId'] = sourceMessageId;
      if (sourceUserMessageId != null) {
        b['sourceUserMessageId'] = sourceUserMessageId;
      }
      d.extras['agentActions'] = actions;
      pruneActions(d);
      _saveBatch(d, b);
      output = {
        'batchId': batchId,
        'revision': b['revision'],
        'proposalIds': added.map((a) => a['id']).toSet().toList(),
        if (added.length == 1) 'proposalId': added.single['id'],
        'status': 'pending',
        'requiresUserConfirmation': true,
        'preparedCount': actions
            .where((a) => a['batchId'] == batchId && a['status'] == 'pending')
            .length,
      };
    });
    return output!;
  }

  Future<void> setGeneration(String id, String state) =>
      setGenerations({id}, state);
  Future<void> setGenerations(Set<String> ids, String state) async {
    if (!batches.any((b) => ids.contains(b['id']) && b['generation'] != state))
      return;
    await store.changeMetadata((d) {
      for (final b in _batches(d).where((b) => ids.contains(b['id']))) {
        if (b['generation'] == state) continue;
        b['generation'] = state;
        b['revision'] = (b['revision'] as int) + 1;
        _saveBatch(d, b);
      }
    });
  }

  static void syncRun(WalletMetadata d, Json run) {
    final ids = {run['id'], run['taskId'], ...run['batchIds'] as List? ?? []};
    final errors = (run['blocks'] as List? ?? [])
        .where(
          (block) =>
              block['type'] == 'tool' &&
              ('${block['name']}'.startsWith('propose_') ||
                  block['name'] == 'revise_changes') &&
              block['status'] == 'error' &&
              (block['round'] as int? ?? 0) >=
                  (run['attemptStartRound'] as int? ?? 0),
        )
        .length;
    final state = switch (run['status']) {
      'complete' => errors == 0 ? 'ready' : 'interrupted',
      'streaming' => 'preparing',
      _ => 'interrupted',
    };
    for (final b in _batches(d).where((b) => ids.contains(b['id']))) {
      b['preparationErrors'] = errors;
      if (b['generation'] != state) {
        b['generation'] = state;
        b['revision'] = (b['revision'] as int) + 1;
      }
      _saveBatch(d, b);
    }
  }

  Future<void> recoverInterrupted() async {
    if (store.startupError != null ||
        !_batches(store.data).any((b) => b['generation'] == 'preparing')) {
      return;
    }
    await store.change((d) {
      final batches = _batches(d);
      for (final b in batches.where((b) => b['generation'] == 'preparing')) {
        b['generation'] = 'interrupted';
        b['revision'] = (b['revision'] as int) + 1;
        if (b['sourceUserMessageId'] != null &&
            !d.chats.any((m) => m['id'] == b['sourceMessageId'])) {
          d.chats.add({
            'id': b['sourceMessageId'],
            'role': 'assistant',
            'sessionId': b['sessionId'],
            'sourceUserMessageId': b['sourceUserMessageId'],
            'status': 'cancelled',
            'content': '准备已中断，已保留方案，可以继续准备或审阅已准备部分。',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'blocks': <Json>[],
            'batchIds': [b['id']],
          });
        }
      }
      d.extras['agentActionBatches'] = batches;
      for (final m in d.chats.where((m) => m['status'] == 'streaming')) {
        m['status'] = 'cancelled';
      }
    });
  }

  static void _checkReview(WalletData d, Json b, String token) {
    if (b['ledgerEpoch'] != null &&
        b['ledgerEpoch'] != d.extras['ledgerEpoch']) {
      throw const FormatException('账本已恢复，此方案已失效，请重新准备');
    }
    if (_token(b, _inBatch(d, b)) != token) {
      throw const FormatException('方案已更新，请重新查看并确认当前内容');
    }
  }

  Json refreshedProposal(String id) {
    final a = Json.from(_find(_items(store.data), id));
    final draft = store.data.clone();
    for (final dependency in _items(store.data).where(
      (x) =>
          x['batchId'] == a['batchId'] &&
          x['status'] == 'pending' &&
          x['kind'] == 'account' &&
          x['id'] != id,
    )) {
      _write(
        draft,
        'account',
        dependency['targetId'],
        Json.from(dependency['desired']),
      );
    }
    a['before'] = _state(store.data, a['kind'], a['targetId']);
    a['desired'] = _desired(
      a['kind'] == 'account' ? store.data : draft,
      a['kind'],
      a['targetId'],
      Json.from(a['input']),
    );
    return a;
  }

  Future<void> editProposal(
    String batchId,
    String id,
    String token,
    Json patch, {
    bool rebase = false,
    Json? expectedBefore,
  }) => store.change((d) {
    final b = _materialize(d, batchId);
    _checkReview(d, b, token);
    final actions = _items(d), a = _find(actions, id);
    if (a['batchId'] != batchId || a['status'] != 'pending') {
      throw const FormatException('此项已处理');
    }
    if (patch.containsKey('id')) throw const FormatException('不能更换提案的目标记录');
    final args = {...Json.from(a['input']), ...patch, 'needsReview': false};
    if (rebase &&
        (expectedBefore == null ||
            !_same(expectedBefore, _state(d, a['kind'], a['targetId'])))) {
      throw const FormatException('账本再次变化，请重新核对此项');
    }
    final draft = d.clone();
    for (final dependency in actions.where(
      (x) =>
          x['batchId'] == batchId &&
          x['status'] == 'pending' &&
          x['kind'] == 'account' &&
          x['id'] != id,
    )) {
      _write(
        draft,
        'account',
        dependency['targetId'],
        Json.from(dependency['desired']),
      );
    }
    if (!rebase && !_same(a['before'], _state(d, a['kind'], a['targetId']))) {
      throw const FormatException('账本已变化，请先重新核对此项');
    }
    final desired = _desired(
      a['kind'] == 'account' ? d : draft,
      a['kind'],
      a['targetId'],
      args,
    );
    _write(draft, a['kind'], a['targetId'], desired);
    validateWallet(draft);
    a.addAll({
      'input': args,
      'desired': desired,
      'needsReview': false,
      if (rebase) 'before': _state(d, a['kind'], a['targetId']),
    });
    a['displaySummary'] = agentActionSummary(
      a,
      (id) => draft.accounts.where((x) => x.id == id).firstOrNull?.name ?? id,
    );
    d.extras['agentActions'] = actions;
    pruneActions(d);
    b['revision'] = (b['revision'] as int) + 1;
    _saveBatch(d, b);
  });

  Future<int> applyBatch(
    String id,
    String token,
    Set<String> selected, {
    bool allowPartial = false,
  }) async {
    final reviewed = review(id);
    final grant = AuthorizationGrant(
      taskId: reviewed.batch['taskId'] ?? id,
      planId: id,
      planDigest: token,
      planRevision: reviewed.batch['revision'] as int,
      ledgerEpoch: store.ledgerEpoch,
      selectedItemIds: selected,
      userEventId: newId(),
    );
    final selection = grant.selectedItemIds;
    var count = 0;
    await store.change((d) {
      LedgerOperations.ensureUnlocked(d);
      if (grant.ledgerEpoch != store.ledgerEpoch) {
        throw const FormatException('账本已恢复，请重新审阅');
      }
      final b = _materialize(d, id);
      if (b['ledgerEpoch'] != null && b['ledgerEpoch'] != store.ledgerEpoch) {
        throw const FormatException('账本已恢复，此方案已失效');
      }
      for (final receipt in b['receipts'] as List? ?? []) {
        if (receipt['status'] == 'applied' &&
            receipt['token'] == token &&
            _same(
              (receipt['actionIds'] as List).toList()..sort(),
              selection.toList()..sort(),
            )) {
          count = (receipt['actionIds'] as List).length;
          return;
        }
      }
      _checkReview(d, b, token);
      if (b['generation'] == 'preparing') {
        throw const FormatException('方案仍在准备，请稍后确认');
      }
      if (b['generation'] == 'interrupted' && !allowPartial) {
        throw const FormatException('方案尚未完整，请继续准备或明确选择只执行已准备部分');
      }
      if (selection.isEmpty) throw const FormatException('请先选择要执行的项目');
      final actions = _items(d);
      final chosen = actions.where((a) => selection.contains(a['id'])).toList();
      if (chosen.length != selection.length ||
          chosen.any((a) => a['batchId'] != id || a['status'] != 'pending')) {
        throw const FormatException('选择范围已变化，请重新审阅');
      }
      final targets = <String>{};
      for (final a in chosen) {
        if (!targets.add('${a['kind']}:${a['targetId']}')) {
          throw const FormatException('同一记录有重复变更，请合并后确认');
        }
        if (!_same(a['before'], _state(d, a['kind'], a['targetId']))) {
          throw FormatException(
            '${a['displaySummary']}：相关数据已变化，请重新核对或排除，此次未执行任何变更',
          );
        }
      }
      final ordered = [
        ...chosen.where((a) => a['kind'] == 'account'),
        ...chosen.where((a) => a['kind'] != 'account'),
      ];
      final original = d.clone();
      for (final a in ordered) {
        final desired = _desired(
          a['kind'] == 'account' ? original : d,
          a['kind'],
          a['targetId'],
          Json.from(a['input']),
        );
        if (!_same(desired, a['desired'])) {
          throw const FormatException('变更与审阅内容不一致，请重新核对');
        }
        _write(d, a['kind'], a['targetId'], desired);
      }
      validateWallet(d);
      final receiptId = newId(), now = DateTime.now().toIso8601String();
      for (final a in chosen) {
        a.addAll({
          'status': 'applied',
          'appliedAt': now,
          'receiptId': receiptId,
          'after': _state(d, a['kind'], a['targetId']),
        });
      }
      (b['receipts'] ??= <Json>[]).add({
        'id': receiptId,
        ...grant.toReceiptFields(),
        'token': token,
        'actionIds': ordered.map((a) => a['id']).toList(),
        'status': 'applied',
        'createdAt': now,
      });
      b['revision'] = (b['revision'] as int) + 1;
      d.extras['agentActions'] = actions;
      pruneActions(d);
      _saveBatch(d, b);
      count = chosen.length;
      final remaining = actions
          .where((a) => a['batchId'] == id && a['status'] == 'pending')
          .length;
      _batchFeedback(
        d,
        b,
        '确认选中 $count 项',
        '已执行并保存到账本 $count 项${remaining > 0 ? '，剩余 $remaining 项待处理' : ''}',
        receiptId,
      );
    });
    return count;
  }

  Future<void> rejectBatch(String id, String token, {Set<String>? selected}) =>
      store.change((d) {
        final b = _materialize(d, id);
        _checkReview(d, b, token);
        final actions = _items(d);
        var count = 0;
        for (final a in actions.where(
          (a) =>
              a['batchId'] == id &&
              a['status'] == 'pending' &&
              (selected == null || selected.contains(a['id'])),
        )) {
          a['status'] = 'rejected';
          count++;
        }
        if (count == 0) throw const FormatException('没有可排除的项目');
        d.extras['agentActions'] = actions;
        pruneActions(d);
        b['revision'] = (b['revision'] as int) + 1;
        if (selected == null) b['closed'] = true;
        _saveBatch(d, b);
        if (selected == null) {
          _batchFeedback(d, b, '取消方案', '已拒绝 $count 项，本次变更未写入账本');
        }
      });

  Future<void> undoBatch(String id, String receiptId) => store.change((d) {
    LedgerOperations.ensureUnlocked(d);
    final b = _materialize(d, id);
    if (b['ledgerEpoch'] != null && b['ledgerEpoch'] != store.ledgerEpoch) {
      throw const FormatException('账本已恢复，旧回执不能撤销当前账本');
    }
    final receipts = (b['receipts'] as List? ?? [])
        .map((e) => Json.from(e))
        .toList();
    final receipt = receipts.firstWhere(
      (r) => r['id'] == receiptId,
      orElse: () => throw const FormatException('执行记录不存在'),
    );
    if (receipt['status'] == 'undone') return;
    final actions = _items(d);
    final chosen = (receipt['actionIds'] as List)
        .map((id) => _find(actions, id))
        .toList();
    for (final a in chosen) {
      if (a['status'] != 'applied' ||
          !_same(a['after'], _state(d, a['kind'], a['targetId']))) {
        throw FormatException('${a['displaySummary']}：执行后又有变化，此次未撤销任何项目');
      }
      if (a['kind'] == 'account' &&
          a['before']['value'] == null &&
          d.quickEntries.any(
            (q) => [q.accountId, q.fromId, q.toId].contains(a['targetId']),
          )) {
        throw const FormatException('新增账户已有快捷交易关联，不能撤销本批次');
      }
    }
    for (final a in chosen.reversed) {
      final before = Json.from(a['before']);
      _write(
        d,
        a['kind'],
        a['targetId'],
        before['value'] == null
            ? null
            : a['kind'] == 'budget'
            ? {'amountCents': before['value']}
            : Json.from(before['value']),
      );
      a['status'] = 'undone';
      a['undoneAt'] = DateTime.now().toIso8601String();
    }
    validateWallet(d);
    receipt['status'] = 'undone';
    b['receipts'] = receipts;
    b['revision'] = (b['revision'] as int) + 1;
    d.extras['agentActions'] = actions;
    pruneActions(d);
    _saveBatch(d, b);
    _batchFeedback(
      d,
      b,
      '撤销本批次 ${chosen.length} 项',
      '已撤销，相关数据已恢复 ${chosen.length} 项',
      receiptId,
    );
  });

  static void _batchFeedback(
    WalletData d,
    Json b,
    String decision,
    String result, [
    String? receiptId,
  ]) {
    final now = DateTime.now();
    d.chats.removeWhere(
      (m) => localDate(
        m['timestamp'],
      ).isBefore(now.subtract(const Duration(days: 365))),
    );
    for (final (role, content) in [
      ('user', '$decision：${b['title']}'),
      ('assistant', '$result。'),
    ]) {
      d.chats.add({
        'id': newId(),
        'role': role,
        'content': content,
        'timestamp': now.millisecondsSinceEpoch,
        'status': 'complete',
        'batchId': b['id'],
        'receiptId': receiptId,
        'isActionFeedback': true,
        'sessionId': b['sessionId'],
      });
    }
  }

  Future<void> apply(String id) => store.change((d) {
    LedgerOperations.ensureUnlocked(d);
    final actions = _items(d);
    final a = _find(actions, id);
    if (a['status'] == 'applied') return;
    if (a['status'] != 'pending') throw const FormatException('此提案已处理');
    final kind = a['kind'] as String, target = a['targetId'] as String;
    if (!_same(a['before'], _state(d, kind, target))) {
      throw const FormatException('相关数据已变化，请拒绝此提案并重新生成');
    }
    final desired = _desired(d, kind, target, Json.from(a['input']));
    _write(d, kind, target, desired);
    a['status'] = 'applied';
    a['appliedAt'] = DateTime.now().toIso8601String();
    a['after'] = _state(d, kind, target);
    d.extras['agentActions'] = actions;
    pruneActions(d);
    _feedback(d, a, '确认执行', '已执行并保存到账本');
  });

  Future<void> reject(String id) => store.change((d) {
    final actions = _items(d);
    final a = _find(actions, id);
    if (a['status'] == 'rejected') return;
    if (a['status'] != 'pending') throw const FormatException('只能拒绝待确认操作');
    a['status'] = 'rejected';
    d.extras['agentActions'] = actions;
    pruneActions(d);
    _feedback(d, a, '拒绝', '已拒绝，本次变更未写入账本');
  });

  Future<void> undo(String id) => store.change((d) {
    LedgerOperations.ensureUnlocked(d);
    final actions = _items(d);
    final a = _find(actions, id);
    if (a['status'] == 'undone') return;
    if (a['status'] != 'applied') throw const FormatException('只能撤销已执行操作');
    final kind = a['kind'] as String, target = a['targetId'] as String;
    if (!_same(a['after'], _state(d, kind, target))) {
      throw const FormatException('执行后数据又有变化，不能直接撤销');
    }
    final before = Json.from(a['before']);
    if (kind == 'account' &&
        before['value'] == null &&
        d.quickEntries.any(
          (q) => [q.accountId, q.fromId, q.toId].contains(target),
        )) {
      throw const FormatException('账户已有快捷交易关联，不能撤销创建');
    }
    _write(
      d,
      kind,
      target,
      before['value'] == null
          ? null
          : kind == 'budget'
          ? {'amountCents': before['value']}
          : Json.from(before['value']),
    );
    a['status'] = 'undone';
    a['undoneAt'] = DateTime.now().toIso8601String();
    d.extras['agentActions'] = actions;
    pruneActions(d);
    _feedback(d, a, '撤销', '已撤销，相关数据已恢复');
  });

  // Save the decision, result, and ledger change together so a failed write
  // never leaves a success message or an unrecorded user decision.
  static void _feedback(
    WalletData d,
    Json action,
    String decision,
    String result,
  ) {
    final summary =
        action['displaySummary'] as String? ??
        agentActionSummary(
          action,
          (id) => d.accounts.where((a) => a.id == id).firstOrNull?.name ?? id,
        );
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 365));
    d.chats.removeWhere((m) => localDate(m['timestamp']).isBefore(cutoff));
    for (final (role, content) in [
      ('user', '$decision：$summary'),
      ('assistant', '$result。'),
    ]) {
      d.chats.add({
        'id': newId(),
        'role': role,
        'content': content,
        'timestamp': now.millisecondsSinceEpoch,
        'status': 'complete',
        'actionId': action['id'],
        'actionStatus': action['status'],
        'isActionFeedback': true,
        'sessionId': action['sessionId'] ?? 'legacy',
      });
    }
  }

  static LedgerTx prepareTransaction(
    WalletData data,
    Json input, {
    String? id,
  }) {
    if (input.containsKey('id')) throw const FormatException('语音入口只能新增账单');
    return LedgerOperations.prepareTransaction(data, input, id: id ?? newId());
  }

  static Json _find(List<Json> items, String id) => items.firstWhere(
    (a) => a['id'] == id,
    orElse: () => throw const FormatException('提案不存在'),
  );

  static Json _state(WalletData d, String kind, String id) => switch (kind) {
    'account' => {
      'value': d.accounts.where((a) => a.id == id).firstOrNull?.toJson(),
      'transactions': d.transactions
          .where((t) => [t.accountId, t.fromId, t.toId].contains(id))
          .map((t) => t.toJson())
          .toList(),
    },
    'transaction' => {
      'value': d.transactions.where((t) => t.id == id).firstOrNull?.toJson(),
    },
    'budget' => {'value': d.settings['budget'] ?? 0},
    _ => throw const FormatException('无效操作'),
  };

  static Json _desired(WalletData d, String kind, String id, Json args) {
    if (kind == 'budget') {
      return {'amountCents': _money(args['amountCents'], '预算')};
    }
    if (kind == 'account') {
      final old = d.accounts.where((a) => a.id == id).firstOrNull;
      if (args['id'] != null && old == null) {
        throw const FormatException('账户不存在');
      }
      const fields = [
        'name',
        'category',
        'subType',
        'note',
        'creditLimitCents',
        'billingDay',
        'repaymentDay',
        'includeInTotal',
        'archived',
        'countBillingDayInPrevious',
      ];
      final raw = <String, dynamic>{
        ...?old?.toJson(),
        'id': id,
        for (final k in fields)
          if (args.containsKey(k)) k: args[k],
      };
      raw['name'] = _text(raw['name'], '账户名称');
      final category = raw['category'];
      if (!accountGroups.containsKey(category)) {
        throw const FormatException('账户类型无效');
      }
      if (!(accountPresets[category] ?? []).any(
        (p) => p.$1 == raw['subType'],
      )) {
        throw const FormatException('账户子类型与类型不匹配');
      }
      raw['note'] = raw['note'] == null
          ? ''
          : _text(raw['note'], '备注', empty: true);
      for (final k in [
        'includeInTotal',
        'archived',
        'countBillingDayInPrevious',
      ]) {
        if (raw.containsKey(k) && raw[k] is! bool) {
          throw FormatException('$k 必须为布尔值');
        }
      }
      raw['creditLimitCents'] = _money(raw['creditLimitCents'] ?? 0, '信用额度');
      for (final k in ['billingDay', 'repaymentDay']) {
        if (raw[k] != null && (raw[k] is! int || raw[k] < 1 || raw[k] > 31)) {
          throw const FormatException('账单日与还款日为 1 至 31，短月按月末计算');
        }
      }
      if (args.containsKey('currentBalanceCents')) {
        final current = _money(
          args['currentBalanceCents'],
          '当前余额',
          signed: true,
        );
        final delta = d.transactions.fold<int>(
          0,
          (sum, t) => sum + t.effectOn(id),
        );
        raw['openingBalance'] = current - delta;
      }
      return WalletAccount.fromJson(raw).toJson();
    }
    return LedgerOperations.prepareTransaction(d, args, id: id).toJson();
  }

  static void _write(WalletData d, String kind, String id, Json? value) {
    switch (kind) {
      case 'account':
        d.accounts.removeWhere((a) => a.id == id);
        if (value != null) d.accounts.add(WalletAccount.fromJson(value));
      case 'transaction':
        d.transactions.removeWhere((t) => t.id == id);
        if (value != null) d.transactions.add(LedgerTx.fromJson(value));
      case 'budget':
        d.settings['budget'] = value?['amountCents'] ?? 0;
    }
  }

  static int _money(dynamic v, String label, {bool signed = false}) {
    if (v is! int || v.abs() > 999999999999 || (!signed && v < 0)) {
      throw FormatException('$label 必须为有效的整数分');
    }
    return v;
  }

  static String _text(dynamic v, String label, {bool empty = false}) {
    if (v is! String || (!empty && v.trim().isEmpty) || v.length > 2000) {
      throw FormatException('$label 无效或过长');
    }
    return v.trim();
  }

  static bool _same(dynamic a, dynamic b) =>
      jsonEncode(_ordered(a)) == jsonEncode(_ordered(b));
  static dynamic _ordered(dynamic v) {
    if (v is Map) {
      return {
        for (final k in v.keys.cast<String>().toList()..sort())
          k: _ordered(v[k]),
      };
    }
    if (v is List) return v.map(_ordered).toList();
    return v;
  }
}
