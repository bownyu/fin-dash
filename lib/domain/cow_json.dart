import 'dart:collection';

/// Frozen JSON subtrees are recognizable in O(1) and never expose mutable storage.
class FrozenMap extends MapBase<String, dynamic> {
  final Map<String, dynamic> _values;
  FrozenMap._(this._values);
  @override
  dynamic operator [](Object? key) => _values[key];
  @override
  Iterable<String> get keys => _values.keys;
  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('已提交数据不可修改');
  @override
  dynamic remove(Object? key) => throw UnsupportedError('已提交数据不可修改');
  @override
  void clear() => throw UnsupportedError('已提交数据不可修改');
}

class FrozenList<T> extends ListBase<T> {
  final List<T> _values;
  FrozenList._(this._values);
  @override
  int get length => _values.length;
  @override
  set length(int value) => throw UnsupportedError('已提交数据不可修改');
  @override
  T operator [](int index) => _values[index];
  @override
  void operator []=(int index, T value) => throw UnsupportedError('已提交数据不可修改');
}

dynamic _draft(dynamic value) => switch (value) {
  FrozenMap v => CowMap(v),
  FrozenList<Map<String, dynamic>> v => CowList<Map<String, dynamic>>(v),
  FrozenList v => CowList<dynamic>(v),
  _ => value,
};

/// Reads of scalars do not allocate. Child wrappers live in their parent's slot,
/// so nested mutations and aliases remain visible when the draft materializes.
class CowMap extends MapBase<String, dynamic> {
  final FrozenMap original;
  Map<String, dynamic>? _copy;
  CowMap(this.original);
  Map<String, dynamic> get _read => _copy ?? original;
  Map<String, dynamic> get _write => _copy ??= Map.of(original);
  @override
  dynamic operator [](Object? key) {
    final value = _read[key];
    if (value is FrozenMap || value is FrozenList) {
      return _write[key as String] = _draft(value);
    }
    return value;
  }

  @override
  Iterable<String> get keys => _read.keys;
  @override
  void operator []=(String key, dynamic value) => _write[key] = value;
  @override
  dynamic remove(Object? key) => _write.remove(key);
  @override
  void clear() => _write.clear();

  FrozenMap materialize() {
    if (_copy == null) return original;
    var same = _copy!.length == original.length;
    final values = <String, dynamic>{};
    for (final entry in _copy!.entries) {
      final old = original[entry.key];
      final value = freezeValue(entry.value, previous: old);
      values[entry.key] = value;
      if (!original.containsKey(entry.key) || !_sameValue(value, old))
        same = false;
    }
    return same ? original : FrozenMap._(values);
  }
}

class CowList<T> extends ListBase<T> {
  final FrozenList<T> original;
  List<T>? _copy;
  CowList(this.original);
  List<T> get _read => _copy ?? original;
  List<T> get _write => _copy ??= List<T>.of(original);
  @override
  int get length => _read.length;
  @override
  set length(int value) => _write.length = value;
  @override
  T operator [](int index) {
    final value = _read[index];
    if (value is FrozenMap || value is FrozenList) {
      return _write[index] = _draft(value) as T;
    }
    return value;
  }

  @override
  void operator []=(int index, T value) => _write[index] = value;
  @override
  void add(T value) => _write.add(value);
  @override
  void addAll(Iterable<T> values) => _write.addAll(values);
  @override
  void insert(int index, T value) => _write.insert(index, value);
  @override
  void insertAll(int index, Iterable<T> values) =>
      _write.insertAll(index, values);
  @override
  T removeAt(int index) {
    final value = this[index];
    _write.removeAt(index);
    return value;
  }

  @override
  void removeRange(int start, int end) => _write.removeRange(start, end);
  @override
  void removeWhere(bool Function(T) test) {
    // Use wrapper reads so predicates may also mutate a retained child.
    final retained = <T>[];
    for (var i = 0; i < length; i++) {
      final value = this[i];
      if (!test(value)) retained.add(value);
    }
    _copy = retained;
  }

  @override
  void retainWhere(bool Function(T) test) => removeWhere((v) => !test(v));
  @override
  void clear() => _write.clear();
  @override
  void sort([int Function(T, T)? compare]) {
    for (var i = 0; i < length; i++) {
      this[i];
    }
    _write.sort(compare);
  }

  FrozenList<T> materialize() {
    if (_copy == null) return original;
    var same = length == original.length;
    final values = <T>[];
    for (var i = 0; i < length; i++) {
      final old = i < original.length ? original[i] : null;
      final value = freezeValue(_copy![i], previous: old) as T;
      values.add(value);
      if (i >= original.length || !_sameValue(value, old)) same = false;
    }
    return same ? original : FrozenList<T>._(values);
  }
}

bool _sameValue(dynamic a, dynamic b) =>
    identical(a, b) || (a is! Map && a is! List && a == b);

/// Ordinary assigned containers are compared to their old position while being
/// frozen. Unchanged Frozen values skip recursion, including huge tool strings.
dynamic freezeValue(dynamic value, {dynamic previous}) {
  if (value is CowMap) value = value.materialize();
  if (value is CowList) value = value.materialize();
  if (value is FrozenMap || value is FrozenList) return value;
  if (value is Map) {
    var same = previous is FrozenMap && previous.length == value.length;
    final values = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) throw const FormatException('JSON 键必须为字符串');
      final old = previous is FrozenMap ? previous[entry.key] : null;
      final child = freezeValue(entry.value, previous: old);
      values[entry.key as String] = child;
      if (previous is! FrozenMap ||
          !previous.containsKey(entry.key) ||
          !_sameValue(child, old))
        same = false;
    }
    return same ? previous : FrozenMap._(values);
  }
  if (value is List) {
    return value is List<Map<String, dynamic>>
        ? freezeList<Map<String, dynamic>>(value, previous: previous)
        : freezeList<dynamic>(value, previous: previous);
  }
  if (value == null || value is String || value is num || value is bool) {
    return value == previous ? previous : value;
  }
  throw const FormatException('账本包含不支持的数据类型');
}

FrozenList<T> freezeList<T>(List<T> value, {dynamic previous}) {
  if (value is CowList<T>) return value.materialize();
  if (value is FrozenList<T>) return value;
  var same = previous is FrozenList<T> && previous.length == value.length;
  final values = <T>[];
  for (var i = 0; i < value.length; i++) {
    final old = previous is FrozenList && i < previous.length
        ? previous[i]
        : null;
    final child = freezeValue(value[i], previous: old) as T;
    values.add(child);
    if (!_sameValue(child, old)) same = false;
  }
  return same ? previous as FrozenList<T> : FrozenList<T>._(values);
}
