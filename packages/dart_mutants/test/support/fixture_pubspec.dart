import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_mutants/src/version.dart';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The directory of this package, dart_mutants itself.
final String dartMutantsRoot = p.dirname(
  p.dirname(
    Isolate.resolvePackageUriSync(
      Uri.parse('package:dart_mutants/switched_suite.dart'),
    )!.toFilePath(),
  ),
);

/// A fixture package's `dev_dependencies` entry for dart_mutants: a switched
/// run compiles test entries that import `package:dart_mutants`, so a
/// package it runs in has to resolve it, as a real consumer does.
///
/// It ends the `pubspec.yaml`, because it also overrides test_toolkit to the
/// working tree next to this package. dart_mutants names test_toolkit by
/// git tag, and a fixture should run against the test_toolkit beside it,
/// not the last one tagged, which doesn't exist yet when both change in one
/// commit.
String get dartMutantsDevDependency =>
    '  dart_mutants:\n    path: $dartMutantsRoot\n'
    'dependency_overrides:\n'
    '  test_toolkit:\n'
    '    path: ${p.join(p.dirname(dartMutantsRoot), 'test_toolkit')}\n';

/// A plain Dart fixture's `pubspec.yaml`, named [name].
String dartFixturePubspec(String name) =>
    '''
name: $name
environment:
  sdk: ^3.8.0
dev_dependencies:
  test: ^1.25.0
$dartMutantsDevDependency''';

/// What every CLI a test starts runs with: a cache saying this engine is
/// the newest release, read a moment ago, so the version check never asks
/// the network. Set by [useHermeticVersionCheck].
Map<String, String> get cliEnvironment => <String, String>{
  'XDG_CACHE_HOME': _cache!.path,
  // A run under test takes slots of its own, even when this suite runs
  // under a parent that holds some.
  'TEST_QUEUE_HELD': '',
};

Directory? _cache;

/// Gives this test file a [cliEnvironment] for its whole run, deleted once
/// it ends. Call at the top of `main`.
void useHermeticVersionCheck() {
  setUpAll(() {
    final Directory dir = Directory.systemTemp.createTempSync('dm_cache_');
    File(p.join(dir.path, 'dart_mutants', 'latest_release.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode(<String, String>{
          'latest': packageVersion,
          'checkedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    _cache = dir;
  });
  tearDownAll(() => _cache?.deleteSync(recursive: true));
}
