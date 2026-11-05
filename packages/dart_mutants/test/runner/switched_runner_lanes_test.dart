import 'dart:io';

import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/runner/compile_safety_gate.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:dart_mutants/src/runner/run_control.dart';
import 'package:dart_mutants/src/runner/switched_job.dart';
import 'package:dart_mutants/src/runner/switched_runner.dart';
import 'package:dart_mutants/src/runner/switched_stats.dart';
import 'package:dart_mutants/src/runner/switched_toolchain.dart';
import 'package:dart_mutants/src/runner/temp_space.dart';
import 'package:dart_mutants/src/runner/worker_sandbox.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_pubspec.dart';

/// A gate that accepts everything: what is under test is how the lanes
/// share the work, not whether a mutant compiles.
class _AcceptingGate implements SourceCompileSafetyGate {
  @override
  Future<bool> compiles(String filePath) async => true;

  @override
  Future<bool> compilesSource(String filePath, String source) async => true;

  @override
  Future<void> close() async {}
}

/// The Dart toolchain, with a compiler that cannot start when [compilerPath]
/// is given.
class _Toolchain implements SwitchedToolchain {
  _Toolchain(this._real, {this.compilerPath});

  final SwitchedToolchain _real;
  final String? compilerPath;

  @override
  List<String> get requiredPackages => _real.requiredPackages;

  @override
  List<String> compiler({
    required String outputDill,
    required String packageConfig,
  }) {
    final List<String> real = _real.compiler(
      outputDill: outputDill,
      packageConfig: packageConfig,
    );
    return compilerPath == null
        ? real
        : <String>[compilerPath!, ...real.skip(1)];
  }

  @override
  void prepare(String work) => _real.prepare(work);

  @override
  ProcessCommand command(
    String dill, {
    required String workingDirectory,
    required String packageConfig,
    required String work,
    int? mutantId,
  }) => _real.command(
    dill,
    workingDirectory: workingDirectory,
    packageConfig: packageConfig,
    work: work,
    mutantId: mutantId,
  );

  @override
  String entry(
    String testFile, {
    required String root,
    required List<String> arguments,
  }) => _real.entry(testFile, root: root, arguments: arguments);
}

const String _lib = '''
const int step = 1;
const List<int> steps = <int>[step > 0 ? 1 : 2];

int lower(int a, int b) => a < b ? a : b;
''';

/// A Dart package with [testFiles] test files, a mutant of `lower` that is
/// switched and one in a constant context that has to be compiled alone.
Future<Directory> _package(int testFiles) async {
  final Directory dir = Directory.systemTemp.createTempSync('dm_lanes_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
    dartFixturePubspec('lanes'),
  );
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  File(p.join(dir.path, 'lib', 'a.dart')).writeAsStringSync(_lib);
  for (int i = 0; i < testFiles; i++) {
    File(p.join(dir.path, 'test', 'a${i}_test.dart')).writeAsStringSync('''
import 'package:lanes/a.dart';
import 'package:test/test.dart';

void main() {
  test('lower', () => expect(lower(1, 2), 1));
}
''');
  }
  final ProcessResult pubGet = await Process.run('dart', <String>[
    'pub',
    'get',
  ], workingDirectory: dir.path);
  if (pubGet.exitCode != 0) {
    throw StateError('dart pub get failed:\n${pubGet.stdout}${pubGet.stderr}');
  }
  return dir;
}

Mutant _mutant(String file, String original, String replacement) {
  final int offset = _lib.indexOf(original);
  return Mutant(
    filePath: file,
    offset: offset,
    length: original.length,
    line: 1,
    column: 1,
    original: original,
    replacement: replacement,
    operatorName: 'test',
    description: '',
  );
}

void main() {
  late Directory scratch;
  late SwitchedToolchain real;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('dm_lanes_scratch_');
    real = DartToolchain.locate(
      onMissing: (String reason) => fail('no Dart toolchain: $reason'),
    )!;
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  SwitchedRunner runner(
    Directory dir,
    SwitchedToolchain toolchain,
    List<String> results, {
    required int workers,
  }) {
    final TempSpace temps = TempSpace();
    addTearDown(temps.deleteAll);
    return SwitchedRunner(
      toolchain: toolchain,
      root: realPath(dir.path),
      gateFor: (String file) => _AcceptingGate(),
      temps: temps,
      testFileTimeout: const Duration(seconds: 60),
      budgetFrom: (Duration unmutated) => const Duration(seconds: 60),
      onResult:
          (SwitchedJob job, MutantResult result, int lane, Duration tests) =>
              results.add('${job.id} ${result.verdict.name}'),
      stats: SwitchedStats(),
      control: RunControl(),
      slots: null,
      workers: workers,
    );
  }

  test(
    '[F1] a toolchain that will not start ends the run naming it, though '
    'another lane is waiting on that test file for a mutant of its own',
    () async {
      final Directory dir = await _package(1);
      final String file = realPath(p.join(dir.path, 'lib', 'a.dart'));
      final List<String> results = <String>[];

      final String? failure =
          await runner(
                dir,
                _Toolchain(
                  real,
                  compilerPath: p.join(scratch.path, 'no_compiler'),
                ),
                results,
                workers: 2,
              )
              .run(<SwitchedJob>[
                // Compiled alone: it waits on the test file's unmutated run.
                SwitchedJob(
                  1,
                  _mutant(file, 'step > 0', 'step >= 0'),
                  _lib,
                  <String>['test/a0_test.dart'],
                ),
              ])
              .timeout(const Duration(seconds: 90));

      expect(failure, contains('would not start'));
      expect(results, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
