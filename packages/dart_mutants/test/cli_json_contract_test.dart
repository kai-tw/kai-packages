import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A caller scoring per-file at a threshold other than "zero undetected"
/// (e.g. a per-file 80% pass bar) depends on reading `--json` even when
/// this binary's own exit code disagrees with their verdict. This drives
/// the real CLI binary end to end and asserts on real stdout — the
/// property under test is specifically about what actually reaches stdout
/// before the process exits, which a unit test against `MutationRunReport`
/// alone cannot observe.
final String _binPath = p.join(
  Directory.current.path,
  'bin',
  'dart_mutants.dart',
);

Future<Directory> _fixtureWithOneUndetectedMutant() async {
  final Directory dir = Directory.systemTemp.createTempSync(
    'cli_json_contract_test_',
  );
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: fixture
environment:
  sdk: ^3.8.0
dev_dependencies:
  test: ^1.25.0
''');
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  // Never called by any test — its one ternary mutant is guaranteed
  // undetected, which is what drives the CLI's exit code non-zero.
  File(p.join(dir.path, 'lib', 'uncovered.dart')).writeAsStringSync(
    "String classify(bool isPositive) => isPositive ? 'positive' : 'negative';\n",
  );
  // A real, passing, unrelated test — `dart test` treats a package with
  // zero tests anywhere as itself a failure (exit 79), which would trip
  // this package's own red-baseline check for the wrong reason. `classify`
  // itself must stay uncalled so its one mutant is genuinely undetected.
  File(p.join(dir.path, 'test', 'uncovered_test.dart')).writeAsStringSync(
    "import 'package:test/test.dart';\n\nvoid main() { test('sanity', () => expect(1, 1)); }\n",
  );
  final ProcessResult pubGet = await Process.run('dart', <String>[
    'pub',
    'get',
  ], workingDirectory: dir.path);
  if (pubGet.exitCode != 0) {
    throw StateError(
      'dart pub get failed:\n${pubGet.stdout}\n${pubGet.stderr}',
    );
  }
  return dir;
}

void main() {
  test(
    '[boundary] --json still prints a complete report to stdout when the '
    'exit code is non-zero',
    () async {
      final Directory dir = await _fixtureWithOneUndetectedMutant();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ProcessResult result = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        '--json',
        p.join(dir.path, 'lib', 'uncovered.dart'),
      ], workingDirectory: dir.path);

      expect(
        result.exitCode,
        isNot(0),
        reason: 'an undetected mutant must make this binary exit non-zero',
      );

      final Object? decoded = jsonDecode(result.stdout as String);
      expect(decoded, isA<Map<String, Object?>>());
      final Map<String, Object?> json = decoded! as Map<String, Object?>;
      final Map<String, Object?> files = json['files']! as Map<String, Object?>;
      final Map<String, Object?> fileReport =
          files.values.single as Map<String, Object?>;
      expect(fileReport['undetected'], 1);
      // The budget each mutant actually got, next to what it was derived
      // from — neither is necessarily the --mutant-timeout that was passed.
      final num baseline = json['baselineSeconds']! as num;
      final num budget = json['mutantTimeoutSeconds']! as num;
      expect(baseline, greaterThan(0));
      expect(budget, greaterThanOrEqualTo(30));
      expect(budget, greaterThanOrEqualTo(baseline * 4 - 0.001));
    },
  );

  for (final (String flag, String value) in <(String, String)>[
    ('--baseline-timeout', '0'),
    ('--baseline-timeout', 'soon'),
    ('--baseline-factor', '-1'),
    ('--baseline-factor', 'NaN'),
    ('--baseline-factor', 'Infinity'),
  ]) {
    test('[error] $flag $value is a usage error, exit 64', () async {
      final ProcessResult result = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        flag,
        value,
        'lib/anything.dart',
      ]);

      expect(result.exitCode, 64);
      // Not just the flag name: an unknown option names it too, so this is
      // what tells "rejected the value" from "does not know the flag".
      expect(result.stderr, contains('$flag must be'));
    });
  }

  test(
    '[partition] --baseline-factor 0 leaves the flat floor, and '
    '--baseline-timeout is accepted',
    () async {
      final Directory dir = await _fixtureWithOneUndetectedMutant();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ProcessResult result = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        '--baseline-factor',
        '0',
        '--baseline-timeout',
        '120',
        '--json',
        p.join(dir.path, 'lib', 'uncovered.dart'),
      ], workingDirectory: dir.path);

      final Map<String, Object?> json =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(json['abortKind'], isNull, reason: '${json['abortReason']}');
      expect(json['mutantTimeoutSeconds'], 30);
    },
  );

  test(
    '[boundary] an aborted run (red baseline) still prints the abort '
    'reason as valid JSON, with an empty files map, not nothing',
    () async {
      final Directory dir = await _fixtureWithOneUndetectedMutant();
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'test', 'broken_test.dart')).writeAsStringSync(
        "import 'package:test/test.dart';\n\nvoid main() { test('x', () => throw Exception('red')); }\n",
      );

      final ProcessResult result = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        '--json',
        p.join(dir.path, 'lib', 'uncovered.dart'),
      ], workingDirectory: dir.path);

      expect(result.exitCode, isNot(0));
      final Map<String, Object?> json =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(
        json['abortKind'],
        'baseline-failed',
        reason:
            'the field a caller branches on — a red suite and a slow one call '
            'for opposite fixes, and the reason text is not a contract',
      );
      expect(json['abortReason'], isNotNull);
      expect(json['files'], isEmpty);
      // The baseline finished, red, so it has a duration; no mutant ran, so
      // there was never a budget.
      expect(json['baselineSeconds'], isA<num>());
      expect(json.containsKey('mutantTimeoutSeconds'), isFalse);
    },
  );

  test(
    '[boundary] a file path comes back exactly as it was passed in, not '
    'normalised to absolute or to relative — `files` is KEYED by it, so a '
    'caller matching the report against its own requested list depends on '
    'the two forms being identical',
    () async {
      final Directory dir = await _fixtureWithOneUndetectedMutant();
      addTearDown(() => dir.deleteSync(recursive: true));

      // Deliberately relative, and deliberately asserted as the same string
      // rather than via p.equals: a caller keying a lookup on these paths
      // cares about the literal bytes, not about path equivalence.
      const String relative = 'lib/uncovered.dart';
      final ProcessResult relativeRun = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        '--json',
        relative,
      ], workingDirectory: dir.path);

      final Map<String, Object?> relativeJson =
          jsonDecode(relativeRun.stdout as String) as Map<String, Object?>;
      final Map<String, Object?> relativeFiles =
          relativeJson['files']! as Map<String, Object?>;
      expect(relativeFiles.keys, <String>[relative]);
      expect(
        (relativeFiles[relative]! as Map<String, Object?>)['filePath'],
        relative,
      );

      // The same file by absolute path comes back absolute — which is what
      // makes this an echo rather than a normalisation to either form.
      final String absolute = p.join(dir.path, 'lib', 'uncovered.dart');
      final ProcessResult absoluteRun = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        '--json',
        absolute,
      ], workingDirectory: dir.path);

      final Map<String, Object?> absoluteJson =
          jsonDecode(absoluteRun.stdout as String) as Map<String, Object?>;
      expect(
        (absoluteJson['files']! as Map<String, Object?>).keys,
        <String>[absolute],
      );
    },
    // This one test drives the real CLI binary to completion TWICE
    // (relative path, then absolute), each its own full baseline-plus-mutant
    // run through real `dart pub get`/`analyze`/`test` subprocesses — roughly
    // double the single-run cost the package default (30s) is sized for.
    // Measured at ~19s for one run alone; the two together tripped the
    // default, which is a test-runtime ceiling, not a `dart_mutants` gate —
    // unlike `--mutant-timeout`, doubling it cannot hide a genuine hang here.
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
