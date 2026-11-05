import 'dart:io';

import 'package:dart_mutants/src/runner/compile_safety_gate.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutant_timing.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:dart_mutants/src/runner/mutation_test_runner.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_pubspec.dart';

/// A real Flutter package, because what is under test is the boundary
/// between real things: the switched source, Flutter's compiler and
/// `flutter_tester`. A plain test file, a widget test, a test file that a
/// tag in `dart_test.yaml` skips, and a mutant in a constant context, so
/// the engine starts each the way `flutter test` would, fonts and all.
Future<Directory> _flutterPackage() async {
  final Directory dir = Directory.systemTemp.createTempSync('switched_test_');
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: fixture
environment:
  sdk: ^3.8.0
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  flutter_test:
    sdk: flutter
$dartMutantsDevDependency''');
  // Declares a tag and skips one: a run that ignored this file would run
  // the always-failing test below and stop.
  File(p.join(dir.path, 'dart_test.yaml')).writeAsStringSync('''
tags:
  golden:
  broken:
    skip: "kept out of every run"
''');
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  File(p.join(dir.path, 'lib', 'calc.dart')).writeAsStringSync('''
const int step = 1;

int clampAdd(int a, int b, int max) {
  final int sum = a + b;
  if (sum > max) {
    return max;
  }
  return sum;
}

String label(int n) => n > 0 ? 'positive' : 'not positive';

int next(int n) {
  const List<int> steps = <int>[step > 0 ? 1 : 2];
  return n + steps.first;
}
''');
  File(p.join(dir.path, 'test', 'calc_test.dart')).writeAsStringSync('''
import 'package:fixture/calc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adds', () => expect(clampAdd(1, 2, 10), 3));
  test('clamps', () => expect(clampAdd(5, 6, 10), 10));
  test('labels', () => expect(label(1), 'positive'));
  test('steps', () => expect(next(1), 2));
  test('broken', () => expect(next(1), 3), tags: 'broken');
}
''');
  File(p.join(dir.path, 'test', 'widget_test.dart')).writeAsStringSync('''
import 'package:fixture/calc.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the sum', (WidgetTester tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Text('\${clampAdd(2, 2, 3)}'),
      ),
    );
    expect(find.text('3'), findsOneWidget);
  }, tags: 'golden');
}
''');
  final ProcessResult pubGet = await Process.run('flutter', <String>[
    'pub',
    'get',
  ], workingDirectory: dir.path);
  if (pubGet.exitCode != 0) {
    throw StateError('flutter pub get failed:\n${pubGet.stderr}');
  }
  return dir;
}

Future<MutationRunReport> _run(
  Directory dir, {
  List<String> flags = const <String>[],
  int workers = 1,
}) async {
  final InProcessAnalyzerGate gate = InProcessAnalyzerGate(<String>[
    dir.path,
  ]);
  addTearDown(gate.close);
  return MutationTestRunner(
    testCommand: ProcessCommand('flutter', <String>[
      'test',
      '--no-pub',
      ...flags,
    ], workingDirectory: dir.path),
    compileSafetyGate: gate,
    selectByCoverage: true,
    workers: workers,
    mutantTimeout: const Duration(seconds: 60),
    baselineFactor: 0,
  ).run(<String>[p.join(dir.path, 'lib', 'calc.dart')]);
}

/// Every mutant's line, operator and verdict, sorted.
List<String> _verdicts(MutationRunReport report) => <String>[
  for (final MutantTiming m in report.stats!.mutants)
    <Object>[
      '${m.result.mutant.line}:${m.result.mutant.column}',
      m.result.mutant.operatorName,
      m.bucket,
    ].join(' '),
]..sort();

bool _hasFlutter() {
  try {
    return Process.runSync('flutter', <String>['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  late Directory dir;
  setUpAll(() async => dir = await _flutterPackage());
  tearDownAll(() => dir.deleteSync(recursive: true));

  test(
    '[happy] a Flutter package is scored through switched files and '
    'mutants compiled alone, applying dart_test.yaml, with one worker or '
    'two alike, and the package is left untouched',
    () async {
      final String source = File(
        p.join(dir.path, 'lib', 'calc.dart'),
      ).readAsStringSync();

      final MutationRunReport one = await _run(dir);
      expect(one.aborted, isFalse, reason: one.abortReason);
      expect(one.stats!.switched!.switched, greaterThan(0));
      // The ternary in the constant list cannot read the environment.
      expect(
        one.stats!.switched!.aloneReasons.keys,
        contains('constant context'),
      );
      final FileMutationReport file = one.files.single;
      expect(file.detected, greaterThan(0));
      // `sum > max` to `sum >= max`: no test sets the two equal.
      expect(
        file.undetectedMutants.where((MutantResult r) => !r.uncovered),
        isNotEmpty,
      );

      final MutationRunReport two = await _run(dir, workers: 2);
      expect(two.aborted, isFalse, reason: two.abortReason);
      expect(_verdicts(two), _verdicts(one));

      expect(
        File(p.join(dir.path, 'lib', 'calc.dart')).readAsStringSync(),
        source,
      );
      expect(
        Directory(dir.path).listSync().map(
          (FileSystemEntity e) => p.basename(e.path),
        ),
        isNot(contains('dart_mutants_test_entry.dart')),
      );
    },
    skip: _hasFlutter() ? false : 'needs flutter on PATH',
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test(
    '[error] a test-command option a switched run cannot apply stops the run '
    'before the baseline, naming it',
    () async {
      final MutationRunReport report = await _run(
        dir,
        flags: <String>['--dart-define=MODE=x'],
      );
      expect(report.abortKind, AbortKind.switchedRunUnavailable);
      expect(report.abortReason, contains('--dart-define=MODE=x'));
      expect(report.baselineDuration, isNull);
    },
    skip: _hasFlutter() ? false : 'needs flutter on PATH',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
