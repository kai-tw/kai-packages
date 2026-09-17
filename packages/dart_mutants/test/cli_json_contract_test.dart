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
      // Without --select-by-coverage: the run says it did not select, and
      // no survivor is called uncovered.
      expect(json['selectedByCoverage'], isFalse);
      expect(fileReport['uncovered'], 0);
      // The budget each mutant actually got, next to what it was derived
      // from — neither is necessarily the --mutant-timeout that was passed.
      final num baseline = json['baselineSeconds']! as num;
      final num budget = json['mutantTimeoutSeconds']! as num;
      expect(baseline, greaterThan(0));
      expect(budget, greaterThanOrEqualTo(30));
      expect(budget, greaterThanOrEqualTo(baseline * 4 - 0.001));
    },
  );

  test(
    '[partition] --select-by-coverage marks a mutant no test executes as '
    'uncovered, per mutant and per file, and says the run was selected',
    () async {
      final Directory dir = await _fixtureWithOneUndetectedMutant();
      addTearDown(() => dir.deleteSync(recursive: true));
      // Loaded by a test, but only `covered` is ever called: `neglected`'s
      // line is reported by coverage, at zero hits.
      File(p.join(dir.path, 'lib', 'partly.dart')).writeAsStringSync(
        "String covered(bool b) => b ? 'yes' : 'no';\n"
        "String neglected(bool b) => b ? 'yes' : 'no';\n",
      );
      File(p.join(dir.path, 'test', 'partly_test.dart')).writeAsStringSync(
        "import 'package:fixture/partly.dart';\n"
        "import 'package:test/test.dart';\n\n"
        'void main() {\n'
        "  test('covered', () {\n"
        "    expect(covered(true), 'yes');\n"
        "    expect(covered(false), 'no');\n"
        '  });\n'
        '}\n',
      );

      final ProcessResult result = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        '--select-by-coverage',
        '--json',
        'lib/partly.dart',
      ], workingDirectory: dir.path);

      final Map<String, Object?> json =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(json['selectedByCoverage'], isTrue, reason: '${result.stderr}');
      final Map<String, Object?> file =
          (json['files']! as Map<String, Object?>)['lib/partly.dart']!
              as Map<String, Object?>;
      expect(file['detected'], 1);
      expect(file['undetected'], 1);
      expect(file['uncovered'], 1);
      final Map<String, Object?> survivor =
          (file['undetectedMutants']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(survivor['line'], 2);
      expect(survivor['uncovered'], isTrue);
    },
    timeout: const Timeout(Duration(seconds: 90)),
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

  test(
    '[partition] --output writes the JSON report to the file, and stdout '
    'keeps the plan, one progress line per mutant, and the text report',
    () async {
      final Directory dir = await _fixtureWithOneUndetectedMutant();
      addTearDown(() => dir.deleteSync(recursive: true));
      final String out = p.join(dir.path, 'reports', 'mutation.json');

      final ProcessResult result = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        '--output',
        out,
        'lib/uncovered.dart',
      ], workingDirectory: dir.path);

      expect(result.exitCode, 1, reason: '${result.stderr}');
      final Map<String, Object?> json =
          jsonDecode(File(out).readAsStringSync()) as Map<String, Object?>;
      final Map<String, Object?> file =
          (json['files']! as Map<String, Object?>)['lib/uncovered.dart']!
              as Map<String, Object?>;
      expect(file['undetected'], 1);
      final Map<String, Object?> survivor =
          (file['undetectedMutants']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(survivor['timeoutSeconds'], json['mutantTimeoutSeconds']);
      expect(File('$out.partial').existsSync(), isFalse);

      final List<String> lines = (result.stdout as String).trim().split('\n');
      expect(lines[0], startsWith('1 mutant in 1 file — baseline '));
      expect(
        lines[1],
        matches(
          RegExp(
            r'^\[1/1\] undetected lib/uncovered\.dart:1:\d+ ternary_swap '
            r'\(\d+\.\ds\)$',
          ),
        ),
      );
      expect(lines, contains(startsWith('lib/uncovered.dart: 0% ')));
    },
  );

  test(
    '[boundary] --output is written for an aborted run too',
    () async {
      final Directory dir = await _fixtureWithOneUndetectedMutant();
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'test', 'broken_test.dart')).writeAsStringSync(
        "import 'package:test/test.dart';\n\nvoid main() { test('x', () => throw Exception('red')); }\n",
      );
      final String out = p.join(dir.path, 'mutation.json');

      final ProcessResult result = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        '--output',
        out,
        'lib/uncovered.dart',
      ], workingDirectory: dir.path);

      expect(result.exitCode, 1);
      final Map<String, Object?> json =
          jsonDecode(File(out).readAsStringSync()) as Map<String, Object?>;
      expect(json['abortKind'], 'baseline-failed');
      expect(result.stdout, startsWith('aborted: '));
    },
  );

  for (final String flag in <String>['--output', '--history']) {
    test(
      '[error] $flag naming a directory is a usage error, exit 64, before '
      'anything runs',
      () async {
        final Directory dir = Directory.systemTemp.createTempSync(
          'cli_output_',
        );
        addTearDown(() => dir.deleteSync(recursive: true));

        final ProcessResult result = await Process.run('dart', <String>[
          'run',
          _binPath,
          '--test-command',
          'dart test',
          flag,
          dir.path,
          'lib/anything.dart',
        ]);

        expect(result.exitCode, 64);
        expect(result.stderr, contains('$flag must name a file'));
      },
    );
  }

  test(
    '[state] --history appends one line per run, each a whole report with '
    'its statistics, aborted runs included',
    () async {
      final Directory dir = await _fixtureWithOneUndetectedMutant();
      addTearDown(() => dir.deleteSync(recursive: true));
      final String history = p.join(dir.path, 'history', 'runs.jsonl');
      Future<ProcessResult> run() => Process.run('dart', <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        '--history',
        history,
        'lib/uncovered.dart',
      ], workingDirectory: dir.path);

      await run();
      File(p.join(dir.path, 'test', 'broken_test.dart')).writeAsStringSync(
        "import 'package:test/test.dart';\n\nvoid main() { test('x', () => throw Exception('red')); }\n",
      );
      await run();

      final List<Map<String, Object?>> lines = File(history)
          .readAsLinesSync()
          .map((String l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      expect(lines, hasLength(2));

      final Map<String, Object?> first = lines[0];
      expect(first['abortKind'], isNull);
      final Map<String, Object?> stats =
          first['stats']! as Map<String, Object?>;
      expect(stats['finishedAt'], isA<String>());
      final List<Object?> mutants = stats['mutants']! as List<Object?>;
      expect(
        (mutants.single! as Map<String, Object?>)['verdict'],
        'undetected',
      );
      expect(
        ((stats['verdicts']! as Map<String, Object?>)['undetected']!
            as Map<String, Object?>)['count'],
        1,
      );

      expect(lines[1]['abortKind'], 'baseline-failed');
      expect(
        (lines[1]['stats']! as Map<String, Object?>)['mutants'],
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
