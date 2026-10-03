/// Validate components before DateTime.parse can normalize invalid dates.
DateTime parseLedgerDate(dynamic value) {
  final match = value is String
      ? RegExp(
          r'^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,6})?)?(?:[Zz]|([+-])(\d{2}):?(\d{2}))?)?$',
        ).firstMatch(value)
      : null;
  if (match == null) throw const FormatException('日期必须是有效的 ISO 日期');
  int part(int index) => int.parse(match.group(index) ?? '0');
  final year = part(1), month = part(2), day = part(3);
  final calendar = DateTime.utc(year, month, day);
  if (year < 1 ||
      calendar.year != year ||
      calendar.month != month ||
      calendar.day != day ||
      part(4) > 23 ||
      part(5) > 59 ||
      part(6) > 59 ||
      part(8) > 23 ||
      part(9) > 59) {
    throw const FormatException('日期或时间超出有效范围');
  }
  return DateTime.parse(value as String).toLocal();
}
