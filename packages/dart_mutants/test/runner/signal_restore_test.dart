import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fixture_pubspec.dart';

/// Regression coverage for a real incident: a mutation run killed by a
/// timeout once left a parameter-swap mutation sitting in a consumer's
/// working tree, noticed only because that particular mutant happened not to
/// compile. Mutants now run only in copies of the package,
/// so what is left to prove is that an interrupt takes the run's child
/// processes and copies with it. This drives the actual CLI binary as a real
/// subprocess and sends it a real `SIGTERM` while a mutant is running,
/// because the property under test — does the signal
/// handler actually fire and actually win the race against the process
/// dying — cannot be verified by calling Dart methods against each other in
/// one process. Slow by design (mirrors a real kill-mid-run), so it is kept
/// out of the main runner test file's group rather than slowing every run
/// down by default.
final String _binPath = p.join(
  Directory.current.path,
  'bin',
  'dart_mutants.dart',
);

Future<Directory> _slowFixture() async {
  final Directory dir = Directory.systemTemp.createTempSync(
    'signal_restore_test_',
  );
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: slow_fixture
environment:
  sdk: ^3.8.0
dev_dependencies:
  test: ^1.25.0
$dartMutantsDevDependency''');
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  File(p.join(dir.path, 'lib', 'calc.dart')).writeAsStringSync(
    "String classify(bool isPositive) => isPositive ? 'positive' : 'negative';\n",
  );
  // Slow enough to reliably catch the file mid-mutation from outside the
  // process, without making the whole suite painfully slow.
  File(p.join(dir.path, 'test', 'calc_test.dart')).writeAsStringSync('''
import 'package:slow_fixture/calc.dart';
import 'package:test/test.dart';

void main() {
  test('positive', () async {
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(classify(true), 'positive');
  });
}
''');
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

Future<void> _waitUntil(
  bool Function() condition, {
  required Duration timeout,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition never became true within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Walks `ps` independently of the implementation under test. Deliberately a
/// second copy rather than reaching into `ProcessCommand`'s own walk: a test
/// that enumerates processes the same way the code does would agree with it
/// even when both are wrong.
List<int> _descendantsOf(int rootPid) {
  final Map<int, List<int>> childrenOf = <int, List<int>>{};
  final String table =
      Process.runSync('ps', <String>['-Ao', 'pid=,ppid=']).stdout as String;
  for (final String line in table.split('\n')) {
    final List<String> fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 2) {
      continue;
    }
    final int? pid = int.tryParse(fields[0]);
    final int? ppid = int.tryParse(fields[1]);
    if (pid != null && ppid != null) {
      childrenOf.putIfAbsent(ppid, () => <int>[]).add(pid);
    }
  }

  final List<int> found = <int>[];
  final List<int> queue = <int>[rootPid];
  while (queue.isNotEmpty) {
    for (final int child in childrenOf[queue.removeAt(0)] ?? const <int>[]) {
      found.add(child);
      queue.add(child);
    }
  }
  return found;
}

bool _isAlive(int pid) {
  final String listed =
      Process.runSync('ps', <String>['-o', 'pid=', '-p', '$pid']).stdout
          as String;
  return listed.trim().isNotEmpty;
}

List<int> _aliveAmong(List<int> pids) => pids.where(_isAlive).toList();

void main() {
  useHermeticVersionCheck();

  /// Starts the CLI on [dir]'s `lib/calc.dart` with its temporary
  /// directories under [temps], and waits until a mutant is running: a
  /// switched lane's copy exists and a child process is in flight.
  Future<Process> startMidMutant(Directory dir, Directory temps) async {
    final Process process = await Process.start(
      'dart',
      <String>[
        'run',
        _binPath,
        '--test-command',
        'dart test',
        p.join(dir.path, 'lib', 'calc.dart'),
      ],
      workingDirectory: dir.path,
      environment: <String, String>{
        ...cliEnvironment,
        'TMPDIR': temps.path,
      },
    );
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    // Drain stdio so the child cannot block on a full pipe buffer.
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    await _waitUntil(
      () =>
          _ownTemps(temps, process.pid).any(
            (String name) => name.contains('_switched0_'),
          ) &&
          _descendantsOf(process.pid).isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    return process;
  }

  test(
    'SIGTERM mid-mutant exits 1, leaves the package as it was and deletes '
    'every copy the run made',
    () async {
      final Directory dir = await _slowFixture();
      addTearDown(() => dir.deleteSync(recursive: true));
      final Directory temps = Directory.systemTemp.createTempSync(
        'signal_temps_',
      );
      addTearDown(() => temps.deleteSync(recursive: true));
      final File target = File(p.join(dir.path, 'lib', 'calc.dart'));
      final String original = target.readAsStringSync();

      final Process process = await startMidMutant(dir, temps);
      expect(
        process.kill(ProcessSignal.sigterm),
        isTrue,
        reason: 'the process must still be alive to kill',
      );

      // The handler must reach its own exit(1), not fall through to
      // whatever code the process would otherwise end with.
      expect(
        await process.exitCode.timeout(const Duration(seconds: 10)),
        1,
      );
      expect(target.readAsStringSync(), original);
      expect(_ownTemps(temps, process.pid), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'SIGTERM mid-mutant also takes the in-flight compiler and test process '
    'down with it, rather than orphaning them',
    () async {
      // The interrupt half of the leak that exhausted a workstation's memory.
      // A timeout was the way it was found, but Ctrl-C reaches the identical
      // state: the handler called `exit`, and the test process it had
      // started went on running with nobody left to reap it. A
      // `flutter_tester` in that state was measured growing at roughly
      // 130 MB/s, indefinitely.
      final Directory dir = await _slowFixture();
      addTearDown(() => dir.deleteSync(recursive: true));
      final Directory temps = Directory.systemTemp.createTempSync(
        'signal_temps_',
      );
      addTearDown(() => temps.deleteSync(recursive: true));

      final Process process = await startMidMutant(dir, temps);
      final List<int> inFlight = _descendantsOf(process.pid);
      expect(
        inFlight,
        isNotEmpty,
        reason: 'nothing was running, so this test could not observe a leak',
      );

      process.kill(ProcessSignal.sigterm);
      expect(
        await process.exitCode.timeout(const Duration(seconds: 10)),
        1,
      );

      List<int> survivors = inFlight;
      for (int attempt = 0; attempt < 30 && survivors.isNotEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        survivors = _aliveAmong(survivors);
      }
      expect(
        survivors,
        isEmpty,
        reason:
            'an orphaned subprocess outlives the run that created it and '
            'nothing will ever reap it',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'SIGTERM during the coverage pass deletes its temporary directory, '
    'rather than leaving it to fill the disk',
    () async {
      final Directory dir = await _slowFixture();
      addTearDown(() => dir.deleteSync(recursive: true));
      // The run's own temporary root, through TMPDIR, so what it leaves can
      // be seen apart from every other process on the machine.
      final Directory temps = Directory.systemTemp.createTempSync(
        'signal_temps_',
      );
      addTearDown(() => temps.deleteSync(recursive: true));

      final Process process = await Process.start(
        'dart',
        <String>[
          'run',
          _binPath,
          '--test-command',
          'dart test',
          '--select-by-coverage',
          p.join(dir.path, 'lib', 'calc.dart'),
        ],
        workingDirectory: dir.path,
        environment: <String, String>{
          ...cliEnvironment,
          'TMPDIR': temps.path,
        },
      );
      addTearDown(() => process.kill(ProcessSignal.sigkill));
      process.stdout.drain<void>();
      process.stderr.drain<void>();

      bool coverageDirExists() => temps.listSync().any(
        (FileSystemEntity e) =>
            p.basename(e.path).startsWith('dart_mutants_${process.pid}_cov_'),
      );
      await _waitUntil(
        coverageDirExists,
        timeout: const Duration(seconds: 30),
      );

      process.kill(ProcessSignal.sigterm);
      expect(
        await process.exitCode.timeout(const Duration(seconds: 10)),
        1,
      );
      expect(coverageDirExists(), isFalse);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// The temporary directories the run with [pid] made under [temps], by name.
List<String> _ownTemps(Directory temps, int pid) => <String>[
  for (final FileSystemEntity e in temps.listSync())
    if (p.basename(e.path).startsWith('dart_mutants_${pid}_'))
      p.basename(e.path),
];
