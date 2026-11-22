import 'dart:io';

import 'package:dart_mutants/src/mutation_operator.dart';
import 'package:dart_mutants/src/operators/condition_negation.dart';
import 'package:dart_mutants/src/operators/null_coalescing_deletion.dart';
import 'package:dart_mutants/src/operators/statement_deletion.dart';
import 'package:dart_mutants/src/runner/compile_check.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_timing.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:dart_mutants/src/runner/mutation_test_runner.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_pubspec.dart';

/// A logging-style API: every method that only reports something is marked
/// `dart_mutants:diagnostic`, the way a consumer's logger would mark its own.
/// `count` and `ready` return values, so a statement can use them.
const String _markedSink = '''
class Sink {
  @pragma('dart_mutants:diagnostic')
  static void info(String message) {}

  @pragma('dart_mutants:diagnostic')
  static Future<void> flush(String message) async {}

  @pragma('dart_mutants:diagnostic')
  static void items(List<String> items) {}

  @pragma('dart_mutants:diagnostic')
  static int count() => 0;

  @pragma('dart_mutants:diagnostic')
  static bool ready() => true;
}
''';

/// The same shape as [_markedSink], with no marker anywhere.
const String _unmarkedSink = '''
class Sink {
  static void info(String message) {}

  static int count() => 0;
}
''';

/// Marked methods on an object, for a receiver that is more than a name:
/// `channelOf()` is a call, `Box` has a `const` constructor and a method.
const String _effectSink = '''
class Sink {
  @pragma('dart_mutants:diagnostic')
  static void info(String message, {String? tag}) {}

  @pragma('dart_mutants:diagnostic')
  static void items(List<String> items) {}
}

class Channel {
  @pragma('dart_mutants:diagnostic')
  void note(String message) {}
}

Channel channelOf() => Channel();

class Box {
  const Box();

  @pragma('dart_mutants:diagnostic')
  void note(String message) {}
}
''';

/// A real temp package with [lib] (file name to source) under `lib/` and the
/// test [testSource] as `test/fixture_test.dart`. The mutants are decided by
/// what the analyzer resolves, so the fixture has to be a package the
/// analyzer can resolve, not a string handed to a parser.
Future<Directory> _fixture({
  required Map<String, String> lib,
  required String testSource,
}) async {
  final Directory dir = Directory.systemTemp.createTempSync(
    'diagnostic_mutants_test_',
  );
  addTearDown(() => dir.deleteSync(recursive: true));
  File(
    p.join(dir.path, 'pubspec.yaml'),
  ).writeAsStringSync(dartFixturePubspec('fixture'));
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  for (final MapEntry<String, String> file in lib.entries) {
    File(p.join(dir.path, 'lib', file.key)).writeAsStringSync(file.value);
  }
  File(
    p.join(dir.path, 'test', 'fixture_test.dart'),
  ).writeAsStringSync(testSource);
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

/// A test file that calls `work()` from `lib/work.dart` and asserts nothing:
/// nothing in these fixtures is observable, which is what makes every
/// mutant that runs a survivor.
const String _callsWork = '''
import 'package:fixture/work.dart';
import 'package:test/test.dart';

void main() {
  test('work', work);
}
''';

/// Runs [operators] over `lib/` [files] of [dir]. By default through the
/// in-process analyzer, the check a caller gets when they pass none.
Future<MutationRunReport> _run(
  Directory dir,
  List<String> files, {
  required List<MutationOperator> operators,
  CompileCheck? check,
}) async {
  final InProcessAnalyzerCheck analyzer = InProcessAnalyzerCheck(<String>[
    dir.path,
  ]);
  addTearDown(analyzer.close);
  final MutationRunReport report = await MutationTestRunner(
    testCommand: ProcessCommand('dart', <String>[
      'test',
    ], workingDirectory: dir.path),
    compileCheck: check ?? analyzer,
    operators: operators,
    mutantTimeout: const Duration(seconds: 20),
    baselineFactor: 0,
  ).run(<String>[for (final String f in files) p.join(dir.path, 'lib', f)]);
  expect(report.isAborted, isFalse, reason: report.abortReason);
  return report;
}

/// [_fixture] and [_run] in one, for a group whose tests share one run.
///
/// A group declares its run as a `late final` field and awaits it in each
/// test: the run then starts with the first test that reads it, so a group
/// of skipped tests costs nothing, which a `setUpAll` would not give.
Future<MutationRunReport> _runFixture({
  required Map<String, String> lib,
  required String testSource,
  required List<String> files,
  required List<MutationOperator> operators,
}) async => _run(
  await _fixture(lib: lib, testSource: testSource),
  files,
  operators: operators,
);

/// [_runFixture] over `lib/work.dart` alone, answering with its report.
Future<FileMutationReport> _runFileFixture({
  required Map<String, String> lib,
  required String testSource,
  required List<MutationOperator> operators,
}) async => _fileOf(
  await _runFixture(
    lib: lib,
    testSource: testSource,
    files: <String>['work.dart'],
    operators: operators,
  ),
  'work.dart',
);

FileMutationReport _fileOf(MutationRunReport report, String name) =>
    report.files.singleWhere(
      (FileMutationReport f) => p.basename(f.filePath) == name,
    );

/// `operatorName:line` of each mutant in [file]'s JSON list [key]
/// (`undetectedMutants`, `diagnosticMutants`, ...). Read through `toJson`,
/// the report's wire shape, so a test names what a caller of the JSON sees.
List<String> _listed(FileMutationReport file, String key) => <String>[
  for (final Object? mutant in file.toJson()[key]! as List<Object?>)
    _where(mutant! as Map<String, Object?>),
];

String _where(Map<String, Object?> mutant) =>
    '${mutant['operatorName']}:${mutant['line']}';

/// The 1-based line of [source] that holds [needle].
int _lineOf(String source, String needle) =>
    source.split('\n').indexWhere((String l) => l.contains(needle)) + 1;

void main() {
  group('[S1] deleting a call to a marked method', () {
    const String work = '''
import 'sink.dart';

void work() {
  Sink.info('x');
}
''';

    late final Future<MutationRunReport> report = _runFixture(
      lib: <String, String>{'sink.dart': _markedSink, 'work.dart': work},
      testSource: _callsWork,
      files: <String>['work.dart'],
      operators: <MutationOperator>[StatementDeletion()],
    );

    test(
      '[S1] is listed as diagnostic, not scored: it is in neither '
      'detected nor undetected, nor invalid, and the file has no rate',
      () async {
        final FileMutationReport f = _fileOf(await report, 'work.dart');

        expect(_listed(f, 'diagnosticMutants'), <String>[
          'statement_deletion:4',
        ]);
        expect(f.toJson()['diagnostic'], 1);
        expect(<int>[f.detected, f.undetected, f.invalid], <int>[0, 0, 0]);
        expect(f.total, 0);
        expect(f.detectionRate, isNull);
      },
    );

    test(
      '[S1] is never run: the mutant has no test run and no budget, and the '
      'run statistics file it under diagnostic',
      () async {
        final MutantTiming timing = (await report).stats!.mutants.single;

        expect(timing.bucket, 'diagnostic');
        expect(timing.test, isNull);
        expect(timing.result.timeout, isNull);
      },
    );
  });

  group('[S2] a mutation inside the arguments of a marked call', () {
    const String work = '''
import 'sink.dart';

void work(String? b, String c) {
  Sink.info('a \${b ?? c}');
}
''';

    test(
      '[S2] the `??` mutants of an interpolation are diagnostic as well, '
      'not survivors',
      () async {
        final Directory dir = await _fixture(
          lib: <String, String>{'sink.dart': _markedSink, 'work.dart': work},
          testSource: '''
import 'package:fixture/work.dart';
import 'package:test/test.dart';

void main() {
  test('work', () {
    work(null, 'c');
    work('b', 'c');
  });
}
''',
        );

        final MutationRunReport report = await _run(
          dir,
          <String>['work.dart'],
          operators: <MutationOperator>[NullCoalescingDeletion()],
        );

        final FileMutationReport f = _fileOf(report, 'work.dart');
        // Both sides of the `??` are offered, so two mutants.
        expect(_listed(f, 'diagnosticMutants'), <String>[
          'null_coalescing_deletion:4',
          'null_coalescing_deletion:4',
        ]);
        expect(<int>[f.detected, f.undetected], <int>[0, 0]);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('[S3] the same shape against a target with no marker', () {
    const String work = '''
import 'plain.dart';

void work(String? b, String c) {
  Sink.info('a \${b ?? c}');
  Sink.info('x');
}
''';

    test(
      '[S3] runs as it always did: the mutants survive, and nothing is '
      'listed as diagnostic',
      () async {
        final Directory dir = await _fixture(
          lib: <String, String>{'plain.dart': _unmarkedSink, 'work.dart': work},
          testSource: '''
import 'package:fixture/work.dart';
import 'package:test/test.dart';

void main() {
  test('work', () {
    work(null, 'c');
    work('b', 'c');
  });
}
''',
        );

        final MutationRunReport report = await _run(
          dir,
          <String>['work.dart'],
          operators: <MutationOperator>[
            StatementDeletion(),
            NullCoalescingDeletion(),
          ],
        );

        final FileMutationReport f = _fileOf(report, 'work.dart');
        expect(f.toJson()['diagnostic'], 0);
        expect(_listed(f, 'diagnosticMutants'), isEmpty);
        expect(
          _listed(f, 'undetectedMutants'),
          unorderedEquals(<String>[
            'null_coalescing_deletion:4',
            'null_coalescing_deletion:4',
            'statement_deletion:4',
            'statement_deletion:5',
          ]),
        );
        expect(f.total, 4);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('[S4] a marked call whose arguments do something', () {
    const List<(String, String)> effects = <(String, String)>[
      ('a call', 'Sink.info(describe());'),
      ('a call inside an interpolation', "Sink.info('a \${describe()}');"),
      ('an await', 'Sink.info(await load());'),
      ('an assignment', "Sink.info(last = 'a');"),
      ('an increment', "Sink.info('\${counter++}');"),
      ('a decrement', "Sink.info('\${--counter}');"),
      ('a throw', "Sink.info(name ?? (throw StateError('none')));"),
      ('a cascade', "Sink.items(<String>['a']..add('b'));"),
    ];

    final String work =
        '''
import 'sink.dart';

String describe() => 'd';
Future<String> load() async => 'l';
int counter = 0;
String? last;

Future<void> work() async {
  final String? name = 'n';
${effects.map(((String, String) e) => '  ${e.$2}').join('\n')}
}
''';

    late final Future<MutationRunReport> report = _runFixture(
      lib: <String, String>{'sink.dart': _markedSink, 'work.dart': work},
      testSource: _callsWork,
      files: <String>['work.dart'],
      operators: <MutationOperator>[StatementDeletion()],
    );

    for (final (String what, String statement) in effects) {
      test(
        '[S4] with $what in the argument, deleting it is a survivor to read, '
        'not diagnostic: deleting the statement would delete the effect',
        () async {
          final FileMutationReport f = _fileOf(await report, 'work.dart');
          final int line = _lineOf(work, statement);

          expect(
            _listed(f, 'diagnosticMutants'),
            isNot(contains('statement_deletion:$line')),
          );
          expect(
            _listed(f, 'undetectedMutants'),
            contains('statement_deletion:$line'),
          );
        },
      );
    }
  });

  group('[S5] a marked call that is not a statement by itself', () {
    const String work = '''
import 'sink.dart';

int? last;
int touched = 0;

int? viaReturn() {
  return Sink.count();
}

void viaAssignment() {
  last = Sink.count();
}

void viaDeclaration() {
  final int n = Sink.count();
}

void viaCondition() {
  if (Sink.ready()) {
    touched++;
  }
}

void work() {
  viaReturn();
  viaAssignment();
  viaDeclaration();
  viaCondition();
}
''';

    late final Future<MutationRunReport> report = _runFixture(
      lib: <String, String>{'sink.dart': _markedSink, 'work.dart': work},
      testSource: _callsWork,
      files: <String>['work.dart'],
      operators: <MutationOperator>[StatementDeletion(), ConditionNegation()],
    );

    for (final (String what, String needle, String operator)
        in <(String, String, String)>[
          ('a returned call', 'return Sink.count();', 'statement_deletion'),
          ('an assigned call', 'last = Sink.count();', 'statement_deletion'),
          ('a call kept in a variable', 'final int n =', 'statement_deletion'),
          (
            'the `if` that tests a call',
            'if (Sink.ready())',
            'statement_deletion',
          ),
          (
            'a negated condition that is a call',
            'if (Sink.ready())',
            'condition_negation',
          ),
        ]) {
      test(
        '[S5] deleting or changing $what is not diagnostic',
        () async {
          final FileMutationReport f = _fileOf(await report, 'work.dart');
          final String mutant = '$operator:${_lineOf(work, needle)}';

          expect(_listed(f, 'diagnosticMutants'), isNot(contains(mutant)));
          expect(_listed(f, 'undetectedMutants'), contains(mutant));
        },
      );
    }
  });

  group('[S6] a marked call that is awaited or parenthesised', () {
    const String work = '''
import 'sink.dart';

Future<void> work() async {
  await Sink.flush('x');
  (Sink.info('y'));
}
''';

    late final Future<FileMutationReport> file = _runFileFixture(
      lib: <String, String>{'sink.dart': _markedSink, 'work.dart': work},
      testSource: _callsWork,
      operators: <MutationOperator>[StatementDeletion()],
    );

    test(
      '[S6] `await Sink.flush(..);` is diagnostic',
      () async {
        final FileMutationReport f = await file;

        expect(
          _listed(f, 'diagnosticMutants'),
          contains('statement_deletion:4'),
        );
        expect(_listed(f, 'undetectedMutants'), isEmpty);
      },
    );

    test(
      '[S6] `(Sink.info(..));` is diagnostic: the parentheses do not make it '
      'something else',
      () async {
        final FileMutationReport f = await file;

        expect(
          _listed(f, 'diagnosticMutants'),
          contains('statement_deletion:5'),
        );
        expect(_listed(f, 'undetectedMutants'), isEmpty);
      },
    );
  });

  group('[S7] a class of the same name with no marker', () {
    const String markedWork = '''
import 'sink.dart';

void markedWork() {
  Sink.info('x');
}
''';
    const String plainWork = '''
import 'plain.dart';

void plainWork() {
  Sink.info('x');
}
''';

    test(
      '[S7] what a call resolves to decides, not the name it is written '
      'with: the same `Sink.info(..)` text is diagnostic in one file and a '
      'survivor in the other',
      () async {
        final Directory dir = await _fixture(
          lib: <String, String>{
            'sink.dart': _markedSink,
            'plain.dart': _unmarkedSink,
            'marked_work.dart': markedWork,
            'plain_work.dart': plainWork,
          },
          testSource: '''
import 'package:fixture/marked_work.dart';
import 'package:fixture/plain_work.dart';
import 'package:test/test.dart';

void main() {
  test('work', () {
    markedWork();
    plainWork();
  });
}
''',
        );

        final MutationRunReport report = await _run(
          dir,
          <String>['marked_work.dart', 'plain_work.dart'],
          operators: <MutationOperator>[StatementDeletion()],
        );

        final FileMutationReport marked = _fileOf(report, 'marked_work.dart');
        final FileMutationReport plain = _fileOf(report, 'plain_work.dart');
        expect(_listed(marked, 'diagnosticMutants'), <String>[
          'statement_deletion:4',
        ]);
        expect(_listed(marked, 'undetectedMutants'), isEmpty);
        expect(_listed(plain, 'diagnosticMutants'), isEmpty);
        expect(_listed(plain, 'undetectedMutants'), <String>[
          'statement_deletion:4',
        ]);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('[S11] with a caller-named analyze command', () {
    const String work = '''
import 'sink.dart';

void work() {
  Sink.info('x');
}
''';

    test(
      '[S11] a command that is not the in-process analyzer cannot tell what '
      'a call resolves to, so the deletion runs as usual and survives',
      () async {
        final Directory dir = await _fixture(
          lib: <String, String>{'sink.dart': _markedSink, 'work.dart': work},
          testSource: _callsWork,
        );

        final MutationRunReport report = await _run(
          dir,
          <String>['work.dart'],
          operators: <MutationOperator>[StatementDeletion()],
          check: const AnalyzerProcessCheck(
            ProcessCommand('dart', <String>['analyze']),
          ),
        );

        final FileMutationReport f = _fileOf(report, 'work.dart');
        expect(f.toJson()['diagnostic'], 0);
        expect(_listed(f, 'diagnosticMutants'), isEmpty);
        expect(_listed(f, 'undetectedMutants'), <String>[
          'statement_deletion:4',
        ]);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('[S13] a branch that only wraps a marked call', () {
    const String work = '''
import 'sink.dart';

void work(bool x) {
  if (x) {
    Sink.info('a');
  }
}
''';

    test(
      '[S13] negating the condition, and deleting the `if`, run as usual; '
      'only the call inside is diagnostic',
      () async {
        final Directory dir = await _fixture(
          lib: <String, String>{'sink.dart': _markedSink, 'work.dart': work},
          testSource: '''
import 'package:fixture/work.dart';
import 'package:test/test.dart';

void main() {
  test('work', () {
    work(true);
    work(false);
  });
}
''',
        );

        final MutationRunReport report = await _run(
          dir,
          <String>['work.dart'],
          operators: <MutationOperator>[
            StatementDeletion(),
            ConditionNegation(),
          ],
        );

        final FileMutationReport f = _fileOf(report, 'work.dart');
        expect(_listed(f, 'diagnosticMutants'), <String>[
          'statement_deletion:5',
        ]);
        expect(
          _listed(f, 'undetectedMutants'),
          unorderedEquals(<String>[
            'statement_deletion:4',
            'condition_negation:4',
          ]),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('[F1] a call the analyzer cannot resolve to a declaration', () {
    const String channel = '''
class Channel {
  @pragma('dart_mutants:diagnostic')
  void note(String message) {}
}
''';
    const String work = '''
import 'channel.dart';

void viaDynamic(dynamic channel) {
  channel.note('x');
}

void viaFunctionValue(void Function(String) log) {
  log('y');
}

void work() {
  viaDynamic(Channel());
  viaFunctionValue(Channel().note);
}
''';

    late final Future<FileMutationReport> file = _runFileFixture(
      lib: <String, String>{'channel.dart': channel, 'work.dart': work},
      testSource: _callsWork,
      operators: <MutationOperator>[StatementDeletion()],
    );

    test(
      '[F1] a call on a `dynamic` receiver is not diagnostic, even when the '
      'object at run time is one with a marked method',
      () async {
        final FileMutationReport f = await file;

        expect(_listed(f, 'diagnosticMutants'), isEmpty);
        expect(
          _listed(f, 'undetectedMutants'),
          contains('statement_deletion:${_lineOf(work, "channel.note")}'),
        );
      },
    );

    test(
      '[F1] a call through a function value is not diagnostic: it resolves '
      'to the variable, not to the marked method',
      () async {
        final FileMutationReport f = await file;

        expect(_listed(f, 'diagnosticMutants'), isEmpty);
        expect(
          _listed(f, 'undetectedMutants'),
          contains('statement_deletion:${_lineOf(work, "log('y')")}'),
        );
      },
    );
  });

  group('[B1] where the marker sits', () {
    const String sink = '''
class Marked {
  @pragma('dart_mutants:diagnostic')
  static void staticMethod(String message) {}

  @pragma('dart_mutants:diagnostic')
  void instanceMethod(String message) {}
}

@pragma('dart_mutants:diagnostic')
void topLevel(String message) {}

extension MarkedText on String {
  @pragma('dart_mutants:diagnostic')
  void extensionMethod() {}
}

class Misnamed {
  @pragma('dart_mutants:diagnostics')
  static void plural(String message) {}

  @pragma('diagnostic')
  static void unprefixed(String message) {}

  @pragma('other:diagnostic')
  static void otherPrefix(String message) {}

  @pragma('dart_mutants:other')
  static void otherName(String message) {}
}
''';
    const String work = '''
import 'sink.dart';

final Marked marked = Marked();

void work() {
  Marked.staticMethod('a');
  topLevel('b');
  marked.instanceMethod('c');
  'd'.extensionMethod();
  Misnamed.plural('e');
  Misnamed.unprefixed('f');
  Misnamed.otherPrefix('g');
  Misnamed.otherName('h');
}
''';

    late final Future<FileMutationReport> file = _runFileFixture(
      lib: <String, String>{'sink.dart': sink, 'work.dart': work},
      testSource: _callsWork,
      operators: <MutationOperator>[StatementDeletion()],
    );

    for (final (String where, String needle) in <(String, String)>[
      ('a static method', 'Marked.staticMethod'),
      ('a top-level function', "topLevel('b')"),
      ('an instance method', 'marked.instanceMethod'),
      ('an extension method', "'d'.extensionMethod"),
    ]) {
      test(
        '[B1] a marker on $where is recognised',
        () async {
          expect(
            _listed(await file, 'diagnosticMutants'),
            contains('statement_deletion:${_lineOf(work, needle)}'),
          );
        },
      );
    }

    test(
      '[B1] a pragma that is not named `dart_mutants:diagnostic` is not '
      'recognised: a near miss and another tool\'s pragma both survive',
      () async {
        final FileMutationReport f = await file;
        final List<String> diagnostic = _listed(f, 'diagnosticMutants');
        final List<String> undetected = _listed(f, 'undetectedMutants');

        for (final String needle in <String>[
          'Misnamed.plural',
          'Misnamed.unprefixed',
          'Misnamed.otherPrefix',
          'Misnamed.otherName',
        ]) {
          final String mutant = 'statement_deletion:${_lineOf(work, needle)}';
          expect(diagnostic, isNot(contains(mutant)), reason: needle);
          expect(undetected, contains(mutant), reason: needle);
        }
      },
    );
  });

  group('[S4] a marked call whose receiver or arguments do something', () {
    const String work = '''
import 'sink.dart';

final List<String> items = <String>['a'];

void work() {
  channelOf().note('x');
  Box().note('x');
  Sink.info('\${Box()}');
  Sink.info('\${const Box()}');
  Sink.items(items..length);
}
''';

    late final Future<FileMutationReport> file = _runFileFixture(
      lib: <String, String>{'sink.dart': _effectSink, 'work.dart': work},
      testSource: _callsWork,
      operators: <MutationOperator>[StatementDeletion()],
    );

    for (final (String what, String needle) in <(String, String)>[
      ('a call', 'channelOf().note'),
      ('a non-const constructor call', 'Box().note'),
      ('a non-const constructor call in an interpolation', "info('\${Box()}')"),
      ('a cascade with no call in it', 'items..length'),
    ]) {
      test(
        '[S4] with $what in the receiver or argument, deleting the call is a '
        'survivor to read, not diagnostic',
        () async {
          final FileMutationReport f = await file;
          final String mutant = 'statement_deletion:${_lineOf(work, needle)}';

          expect(_listed(f, 'diagnosticMutants'), isNot(contains(mutant)));
          expect(_listed(f, 'undetectedMutants'), contains(mutant));
        },
      );
    }

    test(
      '[S4] a `const` constructor call in the argument does nothing, so '
      'deleting the call is diagnostic',
      () async {
        final FileMutationReport f = await file;
        final String mutant =
            'statement_deletion:${_lineOf(work, "const Box()")}';

        expect(_listed(f, 'diagnosticMutants'), contains(mutant));
        expect(_listed(f, 'undetectedMutants'), isNot(contains(mutant)));
      },
    );
  });

  group('[S4] a marked call whose deletion could drop a throw or a write', () {
    const String work = '''
import 'sink.dart';

Channel? logger = Channel();
Object channel = Channel();
String? text = 't';
Object value = 'v';

void work() {
  String a = '1';
  String b = '2';
  logger!.note('x');
  Sink.info(text!);
  (channel as Channel).note('x');
  Sink.info(value as String);
  Sink.info('\${(a, b) = (b, a)}');
}
''';

    late final Future<FileMutationReport> file = _runFileFixture(
      lib: <String, String>{'sink.dart': _effectSink, 'work.dart': work},
      testSource: _callsWork,
      operators: <MutationOperator>[StatementDeletion()],
    );

    for (final (String what, String needle) in <(String, String)>[
      ('a null assertion on the receiver', 'logger!.note'),
      ('a null assertion in the argument', 'info(text!)'),
      ('an `as` cast on the receiver', '(channel as Channel)'),
      ('an `as` cast in the argument', 'info(value as String)'),
      ('a pattern assignment in the argument', '(a, b) = (b, a)'),
    ]) {
      test(
        '[S4] with $what, deleting the call is a survivor to read, not '
        'diagnostic: the deletion could drop a throw or a write',
        () async {
          final FileMutationReport f = await file;
          final String mutant = 'statement_deletion:${_lineOf(work, needle)}';

          expect(_listed(f, 'diagnosticMutants'), isNot(contains(mutant)));
          expect(_listed(f, 'undetectedMutants'), contains(mutant));
        },
      );
    }
  });

  group('[S4] a marked call whose argument can throw from a pattern or '
      'read a stream', () {
    const String work = '''
import 'sink.dart';

String? maybe = 'm';
Object any = 'a';
final Stream<String> source = Stream<String>.fromIterable(<String>['s']);

Future<void> work() async {
  Sink.info(switch (maybe) { var s! => s });
  Sink.info(switch (any) { var s as String => s });
  Sink.items(<String>[if (maybe case var s!) s]);
  Sink.items(<String>[if (any case var s as String) s]);
  Sink.items(<String>[await for (final String x in source) x]);
}
''';

    late final Future<FileMutationReport> file = _runFileFixture(
      lib: <String, String>{'sink.dart': _effectSink, 'work.dart': work},
      testSource: _callsWork,
      operators: <MutationOperator>[StatementDeletion()],
    );

    for (final (String what, String needle) in <(String, String)>[
      (
        'a null assertion pattern in a switch expression',
        'info(switch (maybe)',
      ),
      ('a cast pattern in a switch expression', 'info(switch (any)'),
      ('a null assertion pattern in an if-case', 'case var s!'),
      ('a cast pattern in an if-case', 'case var s as String'),
      ('an `await for` in a collection literal', 'await for'),
    ]) {
      test(
        '[S4] with $what, deleting the call is a survivor to read, not '
        'diagnostic: the deletion could drop a throw or a read',
        () async {
          final FileMutationReport f = await file;
          final String mutant = 'statement_deletion:${_lineOf(work, needle)}';

          expect(_listed(f, 'diagnosticMutants'), isNot(contains(mutant)));
          expect(_listed(f, 'undetectedMutants'), contains(mutant));
        },
      );
    }
  });

  group('[S4] a marked call with a spread in the argument', () {
    const String work = '''
import 'sink.dart';

void work() {
  final List<String> items = <String>['a'];
  Sink.items(<String>[...items]);
}
''';

    late final Future<FileMutationReport> file = _runFileFixture(
      lib: <String, String>{'sink.dart': _effectSink, 'work.dart': work},
      testSource: _callsWork,
      operators: <MutationOperator>[StatementDeletion()],
    );

    test(
      '[S4] a spread only reads a list, so deleting the call stays diagnostic',
      () async {
        final FileMutationReport f = await file;
        final String mutant =
            'statement_deletion:${_lineOf(work, 'Sink.items')}';

        expect(_listed(f, 'diagnosticMutants'), contains(mutant));
        expect(_listed(f, 'undetectedMutants'), isNot(contains(mutant)));
      },
    );
  });

  group('[S4] a marked call with a plain for element in the argument', () {
    const String work = '''
import 'sink.dart';

void work() {
  final List<String> items = <String>['a'];
  Sink.items(<String>[for (final String x in items) x]);
}
''';

    late final Future<FileMutationReport> file = _runFileFixture(
      lib: <String, String>{'sink.dart': _effectSink, 'work.dart': work},
      testSource: _callsWork,
      operators: <MutationOperator>[StatementDeletion()],
    );

    test(
      '[S4] a for element without await only reads a list, so deleting the '
      'call stays diagnostic',
      () async {
        final FileMutationReport f = await file;
        final String mutant =
            'statement_deletion:${_lineOf(work, 'Sink.items')}';

        expect(_listed(f, 'diagnosticMutants'), contains(mutant));
        expect(_listed(f, 'undetectedMutants'), isNot(contains(mutant)));
      },
    );
  });

  group('[S6] a marked call in other statement shapes', () {
    const String work = '''
import 'sink.dart';

Channel? sink = Channel();

void work() {
  sink?.note('x');
  Sink.info('x', tag: 't');
}
''';

    late final Future<FileMutationReport> file = _runFileFixture(
      lib: <String, String>{'sink.dart': _effectSink, 'work.dart': work},
      testSource: _callsWork,
      operators: <MutationOperator>[StatementDeletion()],
    );

    for (final (String what, String needle) in <(String, String)>[
      ('a null-aware call', 'sink?.note'),
      ('a call with a named argument', 'tag:'),
    ]) {
      test(
        '[S6] deleting $what is diagnostic',
        () async {
          final FileMutationReport f = await file;

          expect(
            _listed(f, 'diagnosticMutants'),
            contains('statement_deletion:${_lineOf(work, needle)}'),
          );
          expect(_listed(f, 'undetectedMutants'), isEmpty);
        },
      );
    }
  });

  group('[S5] a marked call as the body of a function', () {
    const String work = '''
import 'sink.dart';

void viaArrow() => Sink.info('x');

void work() {
  viaArrow();
}
''';

    test(
      '[S5] `=> Sink.info(..)` is the value of the function, not a '
      'statement: nothing about it is diagnostic',
      () async {
        final FileMutationReport f = await _runFileFixture(
          lib: <String, String>{'sink.dart': _markedSink, 'work.dart': work},
          testSource: _callsWork,
          operators: <MutationOperator>[
            StatementDeletion(),
            ConditionNegation(),
            NullCoalescingDeletion(),
          ],
        );

        expect(_listed(f, 'diagnosticMutants'), isEmpty);
        expect(f.toJson()['diagnostic'], 0);
        // The arrow body is not a mutation site; only the call to `viaArrow`
        // on line 6 is, and it is no marked call.
        expect(_listed(f, 'undetectedMutants'), <String>[
          'statement_deletion:6',
        ]);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('[S13] a branch without braces that only wraps a marked call', () {
    const String work = '''
import 'sink.dart';

void work(bool x) {
  if (x) Sink.info('a');
}
''';

    test(
      '[S13] negating the condition runs as usual, like the braced form',
      () async {
        final Directory dir = await _fixture(
          lib: <String, String>{'sink.dart': _markedSink, 'work.dart': work},
          testSource: '''
import 'package:fixture/work.dart';
import 'package:test/test.dart';

void main() {
  test('work', () {
    work(true);
    work(false);
  });
}
''',
        );

        final MutationRunReport report = await _run(
          dir,
          <String>['work.dart'],
          operators: <MutationOperator>[
            StatementDeletion(),
            ConditionNegation(),
          ],
        );

        final FileMutationReport f = _fileOf(report, 'work.dart');
        expect(_listed(f, 'diagnosticMutants'), isEmpty);
        // Without braces the call is not a statement of its own: the `if`
        // as a whole is deleted and negated, and both are scored.
        expect(
          _listed(f, 'undetectedMutants'),
          unorderedEquals(<String>[
            'statement_deletion:4',
            'condition_negation:4',
          ]),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
