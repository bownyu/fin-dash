import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/app_version.dart';

void main() {
  test('app version is consistent in package, app and documentation', () {
    expect(appVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: $appVersion+$appBuildNumber'),
    );
    expect(
      File('Agent.md').readAsStringSync(),
      contains('当前应用版本：`$appVersion`'),
    );
    expect(File('CHANGELOG.md').readAsStringSync(), contains('## $appVersion'));
    expect(File('docs/releases/$appVersion.md').existsSync(), true);
  });
}
