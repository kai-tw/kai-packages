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

/// A real Flutter package, because what is under test is the boundary
/// between real things: the switched source, Flutter's compiler and
/// `flutter_tester`. One plain test file and one widget test, so the engine
/// starts the way `flutter test` starts it, fonts and all.
Future<Directory> _flutterPackage() async {
  final Directory dir = Directory.systemTemp.createTempSync('schemata_test_');
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
  test_core: any
''');
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  File(p.join(dir.path, 'lib', 'calc.dart')).writeAsStringSync('''
int clampAdd(int a, int b, int max) {
  final int sum = a + b;
  if (sum > max) {
    return max;
  }
  return sum;
}

String label(int n) => n > 0 ? 'positive' : 'not positive';
''');
  File(p.join(dir.path, 'test', 'calc_test.dart')).writeAsStringSync('''
import 'package:fixture/calc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adds', () => expect(clampAdd(1, 2, 10), 3));
  test('clamps', () => expect(clampAdd(5, 6, 10), 10));
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
  });
}
''');
  // Passes under `flutter test` and fails in a switched run, which always
  // sets the variable: the one test file whose mutants must go back.
  File(p.join(dir.path, 'test', 'env_test.dart')).writeAsStringSync('''
import 'dart:io';

import 'package:fixture/calc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('labels', () {
    expect(Platform.environment.containsKey('DART_MUTANTS_ID'), isFalse);
    expect(label(1), 'positive');
  });
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
  required bool schemata,
  List<String>? notes,
  List<String> flags = const <String>[],
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
    schemata: schemata,
    onSchemataUnavailable: notes?.add,
    mutantTimeout: const Duration(seconds: 60),
    baselineFactor: 0,
  ).run(<String>[p.join(dir.path, 'lib', 'calc.dart')]);
}

/// Every mutant's line, operator and verdict, in report order.
List<String> _verdicts(MutationRunReport report) => <String>[
  for (final MutantTiming m in report.stats!.mutants) _describe(m),
]..sort();

String _describe(MutantTiming m) {
  final String at = '${m.result.mutant.line}:${m.result.mutant.column}';
  return '$at ${m.result.mutant.operatorName} ${m.bucket}';
}

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
    '[happy] switched files score every mutant the same as one flutter test '
    'each, send back the mutants of a test file that fails unmutated, and '
    'leave the package untouched',
    () async {
      final String source = File(
        p.join(dir.path, 'lib', 'calc.dart'),
      ).readAsStringSync();

      final List<String> notes = <String>[];
      final MutationRunReport switched = await _run(
        dir,
        schemata: true,
        notes: notes,
      );
      expect(notes, isEmpty);
      expect(switched.aborted, isFalse, reason: switched.abortReason);
      expect(switched.stats!.schemata!.switched, greaterThan(0));
      expect(switched.stats!.schemata!.brokenTestFiles, <String>[
        'test/env_test.dart',
      ]);
      // label()'s mutants reach only env_test.dart, so they went back.
      expect(
        switched.stats!.mutants
            .where((MutantTiming m) => m.result.mutant.line == 9)
            .map((MutantTiming m) => m.switched),
        everyElement(isFalse),
      );
      expect(
        switched.stats!.mutants.where((MutantTiming m) => m.switched),
        isNotEmpty,
      );
      expect(
        File(p.join(dir.path, 'lib', 'calc.dart')).readAsStringSync(),
        source,
      );
      expect(
        Directory(dir.path).listSync().map((FileSystemEntity e) {
          return p.basename(e.path);
        }),
        isNot(contains('dart_mutants_test_entry.dart')),
      );

      final MutationRunReport plain = await _run(dir, schemata: false);
      expect(plain.stats!.schemata, isNull);
      expect(_verdicts(switched), _verdicts(plain));
      // Both ways a switched run can end: a test failed, and every selected
      // test file passed with the mutant on (`sum >= max` here).
      final FileMutationReport file = switched.files.single;
      expect(file.detected, greaterThan(0));
      expect(
        file.undetectedMutants.where((MutantResult r) => !r.uncovered),
        isNotEmpty,
      );
    },
    skip: _hasFlutter() ? false : 'needs flutter on PATH',
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    '[error] a test-command flag a switched run cannot pass on says so, and '
    'every mutant goes through the test command',
    () async {
      final List<String> notes = <String>[];
      final MutationRunReport report = await _run(
        dir,
        schemata: true,
        notes: notes,
        flags: <String>['--dart-define=MODE=x'],
      );
      expect(notes, <String>[
        'the test command passes --dart-define=MODE=x, which it cannot pass on',
      ]);
      expect(report.stats!.schemata, isNull);
      expect(
        report.stats!.mutants.where((MutantTiming m) => m.switched),
        isEmpty,
      );
    },
    skip: _hasFlutter() ? false : 'needs flutter on PATH',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
