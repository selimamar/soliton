import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:models_app/app/constants.dart';

void main() {
  test('appVersion matches the version in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*([^+\s]+)', multiLine: true).firstMatch(pubspec)!.group(1);
    expect(appVersion, version, reason: 'Update appVersion in lib/app/constants.dart');
  });
}
