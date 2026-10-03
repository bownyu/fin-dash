import 'dart:collection';
import '../domain/models.dart';

/// Copy-on-write list with an explicit changed-record set. No JSON diff is
/// needed for ordinary commands; arbitrary reorder falls back to compatibility.
class LedgerList<T> extends ListBase<T> {
  final List<T> original;
  final String Function(T) idOf;
  List<T>? _copy;
  final before = <String, T>{}, after = <String, T>{};
  final removed = <String>{}, appended = <String>{};
  bool reordered = false;
  Set<String>? _ids;
  Set<String> get ids => _ids ??= _read.map(idOf).toSet();
  LedgerList(this.original, this.idOf);
  List<T> get _read => _copy ?? original;
  List<T> get _write => _copy ??= List.of(original);
  bool get changed =>
      before.isNotEmpty || after.isNotEmpty || removed.isNotEmpty;
  @override
  int get length => _read.length;
  @override
  set length(int value) {
    if (value > length) throw UnsupportedError('使用 add 添加非空记录');
    removeRange(value, length);
  }

  @override
  T operator [](int index) => _read[index];
  void _remove(T value) {
    final id = idOf(value);
    if (!appended.contains(id)) before.putIfAbsent(id, () => value);
    after.remove(id);
    removed.add(id);
    appended.remove(id);
    ids.remove(id);
  }

  void _put(T value) {
    final id = idOf(value);
    if (!ids.add(id)) throw const FormatException('账本包含重复的记录 ID');
    after[id] = value;
    removed.remove(id);
  }

  @override
  void operator []=(int index, T value) {
    final old = _read[index];
    _remove(old);
    _put(value);
    _write[index] = value;
  }

  @override
  void add(T element) {
    final value = element;
    _put(value);
    appended.add(idOf(value));
    _write.add(value);
  }

  @override
  void addAll(Iterable<T> iterable) {
    for (final value in iterable) {
      add(value);
    }
  }

  @override
  T removeAt(int index) {
    final value = _read[index];
    _remove(value);
    return _write.removeAt(index);
  }

  @override
  void removeWhere(bool Function(T) test) {
    _write.removeWhere((v) {
      if (!test(v)) return false;
      _remove(v);
      return true;
    });
  }

  @override
  void retainWhere(bool Function(T) test) => removeWhere((v) => !test(v));
  @override
  void removeRange(int start, int end) {
    for (final v in _read.sublist(start, end)) {
      _remove(v);
    }
    _write.removeRange(start, end);
  }

  @override
  void clear() => removeRange(0, length);
  @override
  void insert(int index, T element) {
    final value = element;
    if (index == length) {
      add(value);
      return;
    }
    reordered = true;
    _put(value);
    _write.insert(index, value);
  }

  @override
  void sort([int Function(T, T)? compare]) {
    reordered = true;
    _write.sort(compare);
  }
}

class LedgerChangeSet {
  final WalletData previous, next;
  final Set<String> movedTransactionIds,
      movedAccountIds,
      movedCategoryIds,
      movedQuickIds;
  LedgerChangeSet(
    this.previous,
    this.next, {
    required this.movedTransactionIds,
    required this.movedAccountIds,
    required this.movedCategoryIds,
    required this.movedQuickIds,
  });
  static WalletData draft(WalletData current) =>
      current.withMetadata(current.cloneMetadata())
        ..accounts = LedgerList(current.accounts, (a) => a.id)
        ..transactions = LedgerList(current.transactions, (t) => t.id)
        ..categories = LedgerList(current.categories, (c) => c.id)
        ..quickEntries = LedgerList(current.quickEntries, (q) => q.id);
  static LedgerChangeSet? from(WalletData previous, WalletData next) {
    if ([
      next.accounts,
      next.transactions,
      next.categories,
      next.quickEntries,
    ].any((v) => v is! LedgerList || (v as LedgerList).reordered)) {
      return null;
    }
    final a = next.accounts as LedgerList<WalletAccount>,
        t = next.transactions as LedgerList<LedgerTx>,
        c = next.categories as LedgerList<WalletCategory>,
        q = next.quickEntries as LedgerList<QuickEntry>;
    final old = previous.withMetadata(previous.cloneMetadata())
      ..accounts = a.before.values.toList()
      ..transactions = t.before.values.toList()
      ..categories = c.before.values.toList()
      ..quickEntries = q.before.values.toList();
    final fresh = next.withMetadata(next.cloneMetadata())
      ..accounts = a.after.values.toList()
      ..transactions = t.after.values.toList()
      ..categories = c.after.values.toList()
      ..quickEntries = q.after.values.toList();
    return LedgerChangeSet(
      old,
      fresh,
      movedTransactionIds: t.appended,
      movedAccountIds: a.appended,
      movedCategoryIds: c.appended,
      movedQuickIds: q.appended,
    );
  }
}
