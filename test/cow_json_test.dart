import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/domain/cow_json.dart';
import 'package:fin_dash/domain/models.dart';

void main() {
  FrozenMap sample() =>
      freezeValue({
            'rows': <Json>[
              {'id': 'a', 'n': 1},
              {'id': 'b', 'n': 2},
            ],
            'other': {'flag': true},
          })
          as FrozenMap;
  test('read-only and equal writes reuse the original', () {
    final original = sample(), draft = CowMap(sample());
    final read = CowMap(original);
    expect(identical(read.materialize(), original), true);
    (read['rows'] as List).first['n'] = 1;
    expect(identical(read.materialize(), original), true);
    expect(() => original['other']['flag'] = false, throwsUnsupportedError);
    expect(draft['rows'], same(draft['rows']));
  });
  test('nested writes and assigned Json copies share untouched subtrees', () {
    final original = sample(), draft = CowMap(sample());
    final nested = CowMap(original);
    nested['rows'][0]['n'] = 3;
    final next = nested.materialize();
    expect(next['other'], same(original['other']));
    expect(next['rows'][1], same(original['rows'][1]));
    expect(original['rows'][0]['n'], 1);
    final copy = Json.from(draft);
    copy['other'] = Json.from(copy['other']);
    expect(freezeValue(copy, previous: draft.original), same(draft.original));
  });
  test('insert, removeWhere, sort, remove, clear and aliases materialize', () {
    final draft = CowMap(sample());
    final list = draft['rows'] as List;
    final alias = list[0];
    list.insert(1, {'id': 'c', 'n': 4});
    list.removeWhere((v) => v['id'] == 'b');
    list.sort((a, b) => (b['n'] as int).compareTo(a['n']));
    draft['alias'] = alias;
    alias['n'] = 7;
    final next = draft.materialize();
    expect(next['rows'].map((v) => v['n']).toList(), [4, 7]);
    expect(next['alias']['n'], 7);
    final removed = CowMap(next);
    final rows = removed['rows'] as List;
    rows.remove(rows.first);
    expect(rows.length, 1);
    rows.clear();
    expect(removed.materialize()['rows'], isEmpty);
  });
}
