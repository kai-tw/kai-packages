import 'dart:io';

import 'package:dart_mutants/src/version.dart';
import 'package:test/test.dart';

void main() {
  test(
    '[state] the version recorded in statistics is the one in pubspec.yaml',
    () {
      final String pubspec = File('pubspec.yaml').readAsStringSync();
      final String version = RegExp(
        r'^version: (\S+)$',
        multiLine: true,
      ).firstMatch(pubspec)![1]!;

      expect(packageVersion, version);
    },
  );
}
