/// Loose matching for short Chinese text. Two-character grams let a misheard
/// "米雪冰城" still meet "蜜雪冰城" through "冰城"; letters and digits stay whole.
String normalizeSearchText(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

Set<String> searchTerms(String value) {
  final normalized = normalizeSearchText(value);
  return {
    ...RegExp(r'[a-z0-9]+').allMatches(normalized).map((m) => m.group(0)!),
    for (var i = 0; i < normalized.length - 1; i++)
      normalized.substring(i, i + 2),
  };
}
