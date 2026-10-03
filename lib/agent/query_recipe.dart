import 'dart:convert';
import '../application/ledger_queries.dart';
import '../domain/models.dart';
import '../domain/ledger_input.dart';
import '../domain/query_contracts.dart';

enum RecipeOperator {
  scan,
  filter,
  calendar,
  group,
  derive,
  compare,
  sort,
  take,
  project,
}

class RecipeStep {
  final String id;
  final RecipeOperator op;
  final Json args;
  final Map<String, String> fields;
  const RecipeStep(this.id, this.op, this.args, this.fields);
}

class QueryRecipe {
  final Json source;
  final List<RecipeStep> steps;
  const QueryRecipe._(this.source, this.steps);
  static Never invalid(String text) =>
      throw ErrorEnvelope(ErrorCode.invalidInput, text, phase: 'recipe');
  static void keys(Map input, Iterable<String> allowed) {
    if (input.keys.any((k) => !allowed.contains(k))) invalid('查询程序包含未知字段');
  }

  factory QueryRecipe.parse(Json input) {
    if (utf8.encode(jsonEncode(input)).length > 65536) invalid('查询程序过长');
    keys(input, [
      'languageVersion',
      'name',
      'description',
      'parameters',
      'steps',
      'output',
    ]);
    if (input['languageVersion'] != 1 ||
        input['parameters'] is! Map ||
        input['output'] is! Map ||
        input['steps'] is! List ||
        (input['steps'] as List).isEmpty ||
        (input['steps'] as List).length > 24) {
      invalid('查询程序版本或结构无效');
    }
    final params = Json.from(input['parameters']);
    if (params.length > 16) invalid('参数过多');
    for (final p in params.values) {
      if (p is! Map) invalid('参数声明无效');
      keys(p, ['type', 'required']);
      if (![
        'String',
        'Bool',
        'ID',
        'Int',
        'Cents',
        'Instant',
        'LocalDate',
        'TimeRange',
        'Array<ID>',
        'Array<String>',
      ].contains(p['type'])) {
        invalid('不支持的参数类型');
      }
    }
    final steps = <RecipeStep>[];
    Map<String, String> fields(dynamic ref) =>
        steps.where((s) => s.id == ref).firstOrNull?.fields ??
        (invalid('步骤只能引用已经存在的输出'));
    void field(dynamic name, Map<String, String> available) {
      if (!available.containsKey(name)) invalid('查询字段不存在：$name');
    }

    void value(dynamic v) {
      if (v is! Map ||
          v.length != 1 ||
          !(v.containsKey('literal') || v.containsKey('param'))) {
        invalid('值必须是 literal 或 param');
      }
      if (v.containsKey('param') && !params.containsKey(v['param'])) {
        invalid('参数未声明');
      }
      if (v['literal'] is List && (v['literal'] as List).length > 200) {
        invalid('筛选列表过长');
      }
    }

    void predicate(dynamic p, Map<String, String> available, [int depth = 0]) {
      if (depth > 8 || p is! Map) invalid('筛选条件过深或无效');
      if (p.containsKey('and') || p.containsKey('or')) {
        if (p.length != 1 ||
            p.values.single is! List ||
            (p.values.single as List).length > 30) {
          invalid('逻辑条件无效');
        }
        for (final child in p.values.single) {
          predicate(child, available, depth + 1);
        }
      } else {
        if (p.length != 2 || !p.containsKey('field')) invalid('筛选条件无效');
        field(p['field'], available);
        final op = p.keys.firstWhere((k) => k != 'field');
        if (![
          'eq',
          'ne',
          'in',
          'inRange',
          'lt',
          'lte',
          'gt',
          'gte',
          'isNull',
          'contains',
        ].contains(op)) {
          invalid('筛选算子不支持');
        }
        value(p[op]);
        final type = available[p['field']]!, node = p[op] as Map;
        bool scalar(dynamic v, String expected) =>
            v == null && ['eq', 'ne'].contains(op) ||
            (['Int', 'Cents'].contains(expected)
                ? v is int
                : expected == 'Bool'
                ? v is bool
                : v is String);
        final expected = op == 'isNull'
            ? 'Bool'
            : op == 'inRange'
            ? 'TimeRange'
            : type;
        if (op == 'contains' && type != 'String') invalid('contains 只接受文本字段');
        if (op == 'inRange' && type != 'Instant') invalid('inRange 只接受时间字段');
        if (node.containsKey('literal')) {
          final v = node['literal'];
          if (op == 'in') {
            if (v is! List || !v.every((item) => scalar(item, type))) {
              invalid('in 列表元素与字段类型不匹配');
            }
          } else if (op == 'inRange') {
            if (v is! Map || v.length != 2) invalid('时间范围格式无效');
            final start = parseLedgerDate(v['startInclusive']),
                end = parseLedgerDate(v['endExclusive']);
            if (!start.isBefore(end)) invalid('时间范围无效');
          } else if (!scalar(v, expected)) {
            invalid('筛选值与字段类型不匹配');
          }
        } else {
          final declared = params[node['param']]['type'];
          final compatible = op == 'in'
              ? declared == 'Array<$type>' ||
                    type == 'ID' && declared == 'Array<String>'
              : declared == expected || type == 'ID' && declared == 'String';
          if (!compatible) invalid('参数类型与字段不匹配');
        }
      }
    }

    void arithmetic(
      dynamic expr,
      Map<String, String> available, [
      int depth = 0,
    ]) {
      if (depth > 8 || expr is! Map) invalid('算术表达式无效');
      if (expr.containsKey('field')) {
        if (expr.length != 1) invalid('字段引用无效');
        field(expr['field'], available);
        if (![
          'Int',
          'Cents',
          'DecimalString',
        ].contains(available[expr['field']])) {
          invalid('算术字段必须为数值');
        }
        return;
      }
      if (expr.containsKey('literal') || expr.containsKey('param')) {
        value(expr);
        if (expr.containsKey('literal') && expr['literal'] is! int) {
          invalid('算术常量必须为整数');
        }
        if (expr.containsKey('param') &&
            !['Int', 'Cents'].contains(params[expr['param']]['type'])) {
          invalid('算术参数必须为数值');
        }
        return;
      }
      keys(expr, ['op', 'args']);
      if (!['add', 'subtract', 'multiply', 'divide'].contains(expr['op']) ||
          expr['args'] is! List ||
          (expr['args'] as List).length != 2) {
        invalid('算术算子无效');
      }
      for (final a in expr['args']) {
        arithmetic(a, available, depth + 1);
      }
    }

    for (final raw in input['steps']) {
      if (raw is! Map ||
          raw['id'] is! String ||
          steps.any((s) => s.id == raw['id'])) {
        invalid('步骤 ID 无效或重复');
      }
      final op = RecipeOperator.values
          .where((o) => o.name == raw['op'])
          .firstOrNull;
      if (op == null) invalid('未注册的查询算子');
      final args = Json.from(raw);
      final result = <String, String>{};
      switch (op) {
        case RecipeOperator.scan:
          keys(args, ['id', 'op', 'dataset', 'fields', 'where']);
          final schema = LedgerQueries.datasets[args['dataset']];
          if (schema == null) invalid('此数据集不可访问');
          if (args['fields'] is! List || (args['fields'] as List).isEmpty) {
            invalid('请声明投影字段');
          }
          for (final f in args['fields']) {
            field(f, schema);
            result[f] = schema[f]!;
          }
          if (args['where'] != null) predicate(args['where'], schema);
        case RecipeOperator.filter:
          keys(args, ['id', 'op', 'from', 'where']);
          result.addAll(fields(args['from']));
          predicate(args['where'], result);
        case RecipeOperator.calendar:
          keys(args, ['id', 'op', 'from', 'field', 'timezone', 'components']);
          result.addAll(fields(args['from']));
          if (result[args['field']] != 'Instant') invalid('日历算子需要时间字段');
          value(args['timezone']);
          if (args['components'] is! List) invalid('日历字段无效');
          for (final c in args['components']) {
            if (!['weekday', 'localHour', 'day', 'month'].contains(c) ||
                result.containsKey(c)) {
              invalid('日历字段无效或重复');
            }
            result[c] = ['weekday', 'localHour'].contains(c) ? 'Int' : 'String';
          }
        case RecipeOperator.group:
          keys(args, ['id', 'op', 'from', 'keys', 'aggregates']);
          final source = fields(args['from']);
          if (args['keys'] is! List ||
              args['aggregates'] is! Map ||
              (args['aggregates'] as Map).length > 20) {
            invalid('分组无效');
          }
          for (final k in args['keys']) {
            field(k, source);
            result[k] = source[k]!;
          }
          for (final entry in (args['aggregates'] as Map).entries) {
            final a = entry.value;
            if (a is! Map || a.length != 1 || result.containsKey(entry.key)) {
              invalid('聚合声明无效');
            }
            final operator = a.keys.single, target = a.values.single;
            if (operator == 'count' && target == '*') {
              result[entry.key] = 'Int';
            } else if ([
                  'sumCents',
                  'minCents',
                  'maxCents',
                ].contains(operator) &&
                source[target] == 'Cents') {
              result[entry.key] = 'Cents';
            } else {
              invalid('金额聚合只接受 Cents 字段');
            }
          }
        case RecipeOperator.derive:
          keys(args, ['id', 'op', 'from', 'fields']);
          result.addAll(fields(args['from']));
          if (args['fields'] is! Map || (args['fields'] as Map).length > 20) {
            invalid('派生字段无效');
          }
          for (final entry in (args['fields'] as Map).entries) {
            if (result.containsKey(entry.key)) invalid('派生字段不能覆盖已有字段');
            arithmetic(entry.value, result);
            result[entry.key] = 'DecimalString';
          }
        case RecipeOperator.compare:
          keys(args, ['id', 'op', 'left', 'right', 'keys', 'field']);
          final left = fields(args['left']), right = fields(args['right']);
          if (args['keys'] is! List ||
              left[args['field']] != 'Cents' ||
              right[args['field']] != 'Cents') {
            invalid('比较需要匹配的金额字段');
          }
          for (final k in args['keys']) {
            field(k, left);
            field(k, right);
            result[k] = left[k]!;
          }
          result.addAll({
            'left': 'Cents',
            'right': 'Cents',
            'delta': 'Cents',
            'ratio': 'DecimalString',
            'reason': 'String',
          });
        case RecipeOperator.sort:
          keys(args, ['id', 'op', 'from', 'by']);
          result.addAll(fields(args['from']));
          if (args['by'] is! List || (args['by'] as List).length > 8) {
            invalid('排序无效');
          }
          for (final b in args['by']) {
            if (b is! Map) invalid('排序无效');
            keys(b, ['field', 'direction']);
            field(b['field'], result);
            if (!['asc', 'desc'].contains(b['direction'])) invalid('排序方向无效');
          }
        case RecipeOperator.take:
          keys(args, ['id', 'op', 'from', 'count']);
          result.addAll(fields(args['from']));
          if (args['count'] is! int ||
              args['count'] < 1 ||
              args['count'] > 200) {
            invalid('截取数量为 1 至 200');
          }
        case RecipeOperator.project:
          keys(args, ['id', 'op', 'from', 'fields']);
          final source = fields(args['from']);
          if (args['fields'] is! List) invalid('投影字段无效');
          for (final f in args['fields']) {
            field(f, source);
            result[f] = source[f]!;
          }
      }
      steps.add(RecipeStep(args['id'], op, args, Map.unmodifiable(result)));
    }
    final output = input['output'] as Map;
    keys(output, ['from', 'fields']);
    final available = fields(output['from']);
    if (output['fields'] is! List) invalid('输出字段无效');
    for (final f in output['fields']) {
      field(f, available);
    }
    return QueryRecipe._(
      Json.from(jsonDecode(jsonEncode(input))),
      List.unmodifiable(steps),
    );
  }

  Future<QueryResult<List<Json>>> run(
    LedgerQueries repository,
    Json parameters, {
    bool Function()? cancelled,
    Duration timeBudget = const Duration(seconds: 2),
  }) async {
    final declarations = source['parameters'] as Map;
    keys(parameters, declarations.keys.cast<String>());
    for (final entry in declarations.entries) {
      final value = parameters[entry.key], type = entry.value['type'];
      if (value == null && entry.value['required'] != true) continue;
      final valid = switch (type) {
        'Int' || 'Cents' => value is int,
        'Bool' => value is bool,
        'TimeRange' =>
          value is Map &&
              value.keys.toSet().containsAll([
                'startInclusive',
                'endExclusive',
              ]) &&
              value.length == 2,
        'Array<ID>' || 'Array<String>' =>
          value is List &&
              value.length <= 200 &&
              value.every((v) => v is String),
        _ => value is String && value.length <= 2000,
      };
      if (!valid) invalid('参数类型错误：${entry.key}');
      if (type == 'Cents') checkedCents(value);
    }
    final clock = Stopwatch()..start();
    var scanned = 0;
    Future<void> check() async {
      await Future<void>.delayed(Duration.zero);
      if (cancelled?.call() == true) {
        throw const ErrorEnvelope(ErrorCode.cancelled, '查询已停止');
      }
      if (clock.elapsed > timeBudget) {
        throw const ErrorEnvelope(ErrorCode.limitExceeded, '查询超时，请缩小范围');
      }
    }

    dynamic val(dynamic node) =>
        node.containsKey('param') ? parameters[node['param']] : node['literal'];
    bool matches(Json row, Map p) {
      if (p.containsKey('and')) {
        return (p['and'] as List).every((e) => matches(row, e));
      }
      if (p.containsKey('or')) {
        return (p['or'] as List).any((e) => matches(row, e));
      }
      final a = row[p['field']],
          op = p.keys.firstWhere((k) => k != 'field'),
          b = val(p[op]);
      if (op == 'isNull') return (a == null) == b;
      if (op == 'eq') return a == b;
      if (op == 'ne') return a != b;
      if (a == null) return false;
      if (op == 'in') {
        if (b is! List) invalid('in 需要列表');
        return b.contains(a);
      }
      if (op == 'contains') {
        if (a is! String || b is! String) invalid('contains 需要文本');
        return a.contains(b);
      }
      if (op == 'inRange') {
        if (b is! Map || b.length != 2) invalid('日期范围无效');
        final start = parseLedgerDate(b['startInclusive']),
            end = parseLedgerDate(b['endExclusive']);
        if (!start.isBefore(end)) invalid('日期范围无效');
        return DateRange(start, end).contains(parseLedgerDate(a));
      }
      if (!(a is int && b is int || a is String && b is String)) {
        invalid('比较类型不匹配');
      }
      final order = (a as Comparable).compareTo(b);
      return switch (op) {
        'lt' => order < 0,
        'lte' => order <= 0,
        'gt' => order > 0,
        'gte' => order >= 0,
        _ => false,
      };
    }

    _Fraction? arithmetic(Json row, Map expr) {
      if (!expr.containsKey('op')) {
        final value = expr.containsKey('field')
            ? row[expr['field']]
            : val(expr);
        if (value == null) return null;
        if (value is String && RegExp(r'^-?\d+\.\d{1,6}$').hasMatch(value)) {
          final pieces = value.split('.');
          final denominator = BigInt.from(10).pow(pieces[1].length);
          final n =
              BigInt.parse(pieces[0].replaceFirst('-', '')) * denominator +
              BigInt.parse(pieces[1]);
          return _Fraction(value.startsWith('-') ? -n : n, denominator);
        }
        if (value is! int) invalid('算术只接受整数金额或整数');
        return _Fraction(BigInt.from(value), BigInt.one);
      }
      final a = arithmetic(row, expr['args'][0]),
          b = arithmetic(row, expr['args'][1]);
      if (a == null || b == null) return null;
      return switch (expr['op']) {
        'add' => _Fraction(a.n * b.d + b.n * a.d, a.d * b.d),
        'subtract' => _Fraction(a.n * b.d - b.n * a.d, a.d * b.d),
        'multiply' => _Fraction(a.n * b.n, a.d * b.d),
        'divide' => b.n == BigInt.zero ? null : _Fraction(a.n * b.d, a.d * b.n),
        _ => null,
      };
    }

    final outputs = <String, List<Json>>{};
    final limitations = <String>['覆盖已记录数据；历史时刻精度未知的记录不代表精确购买时间。'];
    for (final step in steps) {
      await check();
      final a = step.args;
      final rows = outputs[a['from']] ?? <Json>[];
      List<Json> result;
      switch (step.op) {
        case RecipeOperator.scan:
          result = [];
          // Account balances depend on the transaction ledger, too.
          if (a['dataset'] == 'ledger.accounts') {
            scanned += repository.data.transactions.length;
            if (scanned > 50000) {
              throw const ErrorEnvelope(
                ErrorCode.limitExceeded,
                '账户余额查询超过程序扫描预算，请使用账户概览能力',
              );
            }
          }
          for (final row in repository.rows(a['dataset'])) {
            if (++scanned > 50000) {
              throw const ErrorEnvelope(
                ErrorCode.limitExceeded,
                '查询超过 50000 行预算，请缩小数据集或使用汇总能力',
              );
            }
            if (scanned % 256 == 0) await check();
            if (a['where'] == null || matches(row, a['where'])) {
              result.add({for (final f in a['fields']) f: row[f]});
            }
          }
        case RecipeOperator.filter:
          result = rows.where((r) => matches(r, a['where'])).toList();
        case RecipeOperator.calendar:
          final timezone = val(a['timezone']);
          if (!['local', 'UTC'].contains(timezone)) {
            throw const ErrorEnvelope(
              ErrorCode.capabilityUnavailable,
              '当前支持设备本地时区和 UTC',
            );
          }
          result = rows.map((r) {
            final parsed = parseLedgerDate(r[a['field']]);
            final date = timezone == 'UTC' ? parsed.toUtc() : parsed.toLocal();
            return <String, dynamic>{
              ...r,
              for (final c in a['components'])
                c: switch (c) {
                  'weekday' => date.weekday,
                  'localHour' => date.hour,
                  'day' => dayKey(date),
                  _ => '${date.year}-${date.month.toString().padLeft(2, '0')}',
                },
            };
          }).toList();
        case RecipeOperator.group:
          final groups = <String, Json>{};
          for (var i = 0; i < rows.length; i++) {
            if (i % 256 == 0) await check();
            final row = rows[i],
                key = jsonEncode([for (final k in a['keys']) row[k]]);
            final group = groups.putIfAbsent(
              key,
              () => {for (final k in a['keys']) k: row[k]},
            );
            for (final e in (a['aggregates'] as Map).entries) {
              final op = (e.value as Map).keys.single,
                  field = e.value.values.single;
              final previous = group[e.key] as int?, value = row[field];
              if (op == 'count') {
                group[e.key] = (previous ?? 0) + 1;
                continue;
              }
              if (value == null) continue;
              if (value is! int) invalid('金额字段不是整数分');
              group[e.key] = checkedCents(switch (op) {
                'sumCents' => (previous ?? 0) + value,
                'minCents' =>
                  previous == null || value < previous ? value : previous,
                _ => previous == null || value > previous ? value : previous,
              });
            }
          }
          result = groups.values.toList();
        case RecipeOperator.derive:
          result = rows
              .map(
                (r) => <String, dynamic>{
                  ...r,
                  for (final e in (a['fields'] as Map).entries)
                    e.key: arithmetic(r, e.value)?.decimal(),
                },
              )
              .toList();
          limitations.add('派生数值为十进制字符串，保留 6 位小数，四舍五入；零分母为 null。');
        case RecipeOperator.compare:
          String key(Json row) =>
              jsonEncode([for (final k in a['keys']) row[k]]);
          final left = <String, Json>{}, right = <String, Json>{};
          for (final pair in [
            (outputs[a['left']]!, left),
            (outputs[a['right']]!, right),
          ]) {
            for (final row in pair.$1) {
              if (pair.$2.containsKey(key(row))) invalid('比较键不唯一，请先分组');
              pair.$2[key(row)] = row;
            }
          }
          result = [
            for (final k in {...left.keys, ...right.keys})
              (() {
                final l = left[k]?[a['field']] as int?,
                    r = right[k]?[a['field']] as int?;
                return <String, dynamic>{
                  for (final f in a['keys']) f: (left[k] ?? right[k])![f],
                  'left': l,
                  'right': r,
                  'delta': l == null || r == null ? null : checkedCents(r - l),
                  'ratio': l == null || r == null || l == 0
                      ? null
                      : _Fraction(BigInt.from(r - l), BigInt.from(l)).decimal(),
                  'reason': l == null || r == null
                      ? 'missing'
                      : l == 0
                      ? 'zeroDenominator'
                      : null,
                };
              })(),
          ];
        case RecipeOperator.sort:
          final ranked = [for (var i = 0; i < rows.length; i++) (i, rows[i])];
          ranked.sort((x, y) {
            for (final b in a['by']) {
              final l = x.$2[b['field']], r = y.$2[b['field']];
              final c = l == r
                  ? 0
                  : l == null
                  ? -1
                  : r == null
                  ? 1
                  : (l as Comparable).compareTo(r);
              if (c != 0) return b['direction'] == 'desc' ? -c : c;
            }
            return x.$1.compareTo(y.$1);
          });
          result = ranked.map((r) => r.$2).toList();
        case RecipeOperator.take:
          result = rows.take(a['count']).toList();
          if (result.length < rows.length) {
            limitations.add('展示按 take 截取，不能把这些行重新求和当作全量总额。');
          }
        case RecipeOperator.project:
          result = [
            for (final r in rows) {for (final f in a['fields']) f: r[f]},
          ];
      }
      outputs[step.id] = result;
    }
    await check();
    final output = source['output'];
    final result = [
      for (final r in outputs[output['from']]!)
        <String, dynamic>{for (final f in output['fields']) f: r[f]},
    ];
    if (result.length > 200 || utf8.encode(jsonEncode(result)).length > 65536) {
      throw const ErrorEnvelope(
        ErrorCode.limitExceeded,
        '结果超过 200 行或 64 KiB，请聚合或截取展示',
      );
    }
    return QueryResult(
      data: result,
      scope: const QueryScope(metric: 'queryRecipe'),
      snapshot: repository.snapshot,
      matchedRows: scanned,
      returnedRows: result.length,
      limitations: limitations,
    );
  }
}

class _Fraction {
  final BigInt n, d;
  _Fraction(this.n, this.d) {
    if (n.bitLength > 256 || d.bitLength > 256) {
      throw const ErrorEnvelope(ErrorCode.limitExceeded, '算术结果超出预算');
    }
  }
  String decimal() {
    final scale = BigInt.from(1000000),
        numerator = n.abs() * scale,
        denominator = d.abs();
    final rounded = (numerator + denominator ~/ BigInt.two) ~/ denominator;
    return '${n.sign * d.sign < 0 && rounded != BigInt.zero ? '-' : ''}${rounded ~/ scale}.${(rounded % scale).toString().padLeft(6, '0')}';
  }
}
