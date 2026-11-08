import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture_pubspec.dart';
import 'support/marker_fixture.dart';

final String _binPath = p.join(
  Directory.current.path,
  'bin',
  'dart_mutants.dart',
);

/// The runs directory the brief names: `<cache>/dart_mutants/runs`.
Directory _runsDir() => Directory(
  p.join(cliEnvironment['XDG_CACHE_HOME']!, 'dart_mutants', 'runs'),
)..createSync(recursive: true);

Future<ProcessResult> _control(String verb, Directory dir, [String? pid]) =>
    Process.run(
      'dart',
      <String>['run', _binPath, verb, ?pid],
      workingDirectory: dir.path,
      environment: cliEnvironment,
    );

/// Starts a run in [dir] and completes with it and the pid its run file is
/// named after, once the run file appears.
Future<(Process, String)> _startRun(
  Directory dir,
  File marker, {
  String? output,
}) async {
  final Directory runs = _runsDir();
  final Completer<String> appeared = Completer<String>();
  final StreamSubscription<FileSystemEvent> watch = runs.watch().listen((
    FileSystemEvent e,
  ) {
    if (e is FileSystemCreateEvent &&
        e.path.endsWith('.json') &&
        !appeared.isCompleted) {
      appeared.complete(p.basenameWithoutExtension(e.path));
    }
  });
  addTearDown(watch.cancel);
  final Process run = await Process.start(
    'dart',
    <String>[
      'run',
      _binPath,
      '--test-command',
      'dart test',
      if (output != null) ...<String>['--output', output],
      'lib/a.dart',
    ],
    workingDirectory: dir.path,
    environment: <String, String>{
      ...cliEnvironment,
      'DM_MARKER': marker.path,
      'DM_ID': 'run',
    },
  );
  // Whatever the test does, the run must not outlive it: it may be left
  // paused, which nothing else would ever end.
  addTearDown(() => run.kill(ProcessSignal.sigkill));
  return (run, await appeared.future);
}

void main() {
  useHermeticVersionCheck();

  late Directory scratch;
  late File marker;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('dm_pause_');
    marker = File(p.join(scratch.path, 'marker.txt'))..createSync();
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  Future<Directory> fixture() async {
    final Directory dir = await markerFixture(name: 'pausable', testFiles: 3);
    addTearDown(() => dir.deleteSync(recursive: true));
    return dir;
  }

  Map<String, Object?> fileReport(String path) {
    final Map<String, Object?> json =
        jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    return (json['files']! as Map<String, Object?>).values.single!
        as Map<String, Object?>;
  }

  test(
    '[S4] a paused and resumed run ends with the same result as one that '
    'never paused, and its run file is gone',
    () async {
      final Directory dir = await fixture();
      final String plain = p.join(scratch.path, 'plain.json');
      final String paused = p.join(scratch.path, 'paused.json');

      final (Process, String) first = await _startRun(
        dir,
        marker,
        output: plain,
      );
      expect(await first.$1.exitCode, anyOf(0, 1));

      final (Process, String) run = await _startRun(
        dir,
        marker,
        output: paused,
      );
      final String pid = run.$2;
      expect(File(p.join(_runsDir().path, '$pid.json')).existsSync(), isTrue);
      expect((await _control('pause', dir)).exitCode, 0);
      expect((await _control('resume', dir)).exitCode, 0);
      expect(await run.$1.exitCode, anyOf(0, 1));

      final Map<String, Object?> a = fileReport(plain);
      final Map<String, Object?> b = fileReport(paused);
      for (final String key in <String>['detected', 'undetected', 'invalid']) {
        expect(b[key], a[key], reason: key);
      }
      expect(File(p.join(_runsDir().path, '$pid.json')).existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    '[S4] pause, resume and stop name a run by pid as well',
    () async {
      final Directory dir = await fixture();
      final (Process, String) run = await _startRun(dir, marker);
      final String pid = run.$2;

      final Directory elsewhere = Directory.systemTemp.createTempSync(
        'dm_cwd_',
      );
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      expect((await _control('pause', elsewhere, pid)).exitCode, 0);
      expect((await _control('resume', elsewhere, pid)).exitCode, 0);
      expect((await _control('stop', elsewhere, pid)).exitCode, 0);

      await run.$1.exitCode;
      expect(File(p.join(_runsDir().path, '$pid.json')).existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    '[S4] stop ends the run with exit 1 and a report that says it was '
    'stopped, and removes its run file',
    () async {
      final Directory dir = await fixture();
      final String output = p.join(scratch.path, 'stopped.json');
      final (Process, String) run = await _startRun(
        dir,
        marker,
        output: output,
      );
      final String pid = run.$2;

      expect((await _control('stop', dir)).exitCode, 0);
      expect(await run.$1.exitCode, 1);

      final Map<String, Object?> report =
          jsonDecode(File(output).readAsStringSync()) as Map<String, Object?>;
      expect(report['abortKind'], 'stopped');
      expect(report['abortReason'], contains('stopped after'));
      expect(File(p.join(_runsDir().path, '$pid.json')).existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    '[S4] a paused run starts no new test file until it is resumed',
    () async {
      final Directory dir = await fixture();
      final String output = p.join(scratch.path, 'held.json');

      // Completes once [done] holds for the markers on disk.
      Future<void> until(bool Function(List<MarkerEvent>) done) async {
        final Completer<void> reached = Completer<void>();
        void check() {
          if (!reached.isCompleted && done(readMarkers(marker))) {
            reached.complete();
          }
        }

        final StreamSubscription<FileSystemEvent> watch = scratch
            .watch()
            .listen((_) => check());
        try {
          check();
          await reached.future;
        } finally {
          await watch.cancel();
        }
      }

      int starts() =>
          readMarkers(marker).where((MarkerEvent e) => e.start).length;
      bool idle(List<MarkerEvent> events) =>
          events.where((MarkerEvent e) => e.start).length ==
          events.where((MarkerEvent e) => !e.start).length;

      final (Process, String) run = await _startRun(
        dir,
        marker,
        output: output,
      );
      // Past the baseline and the coverage pass, which run in a process of
      // their own each: from the third process on, mutants are being scored.
      await until(
        (List<MarkerEvent> e) =>
            e.map((MarkerEvent x) => x.pid).toSet().length >= 3,
      );
      expect((await _control('pause', dir)).exitCode, 0);
      // The test files already running finish; nothing new may begin.
      // A lane that got past its pause check just before the signal is still
      // compiling its next test file, which leaves no marker until it runs —
      // so the markers can read idle while that file is about to start. Let
      // it start and finish before taking the count.
      await until(idle);
      await Future<void>.delayed(const Duration(seconds: 10));
      await until(idle);
      final int whenPaused = starts();
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(starts(), whenPaused, reason: 'a test file began while paused');

      expect((await _control('resume', dir)).exitCode, 0);
      expect(await run.$1.exitCode, anyOf(0, 1));
      expect(starts(), greaterThan(whenPaused));
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  group('no single run to act on', () {
    test(
      '[S4] with no run in this package, pause, resume and stop exit 2',
      () async {
        final Directory dir = await fixture();
        for (final String verb in <String>['pause', 'resume', 'stop']) {
          final ProcessResult r = await _control(verb, dir);
          expect(r.exitCode, 2, reason: '$verb: ${r.stderr}');
        }
      },
    );

    test(
      '[S4] a pid that names no run exits 2',
      () async {
        final Directory dir = await fixture();
        final ProcessResult r = await _control('pause', dir, '999999');
        expect(r.exitCode, 2, reason: '${r.stderr}');
      },
    );

    test(
      '[S4] a run file whose pid now belongs to a process started after the '
      'file was written is deleted as a leftover, and the process is left '
      'alone',
      () async {
        final Directory dir = await fixture();
        final Process bystander = await Process.start('tail', <String>[
          '-f',
          '/dev/null',
        ]);
        addTearDown(() => bystander.kill(ProcessSignal.sigkill));
        final File record =
            File(
              p.join(_runsDir().path, '${bystander.pid}.json'),
            )..writeAsStringSync(
              jsonEncode(<String, String>{
                'packagePath': dir.resolveSymbolicLinksSync(),
                'startedAt': DateTime.now()
                    .subtract(const Duration(hours: 1))
                    .toUtc()
                    .toIso8601String(),
              }),
            );

        final ProcessResult r = await _control('stop', dir);

        expect(r.exitCode, 2, reason: '${r.stderr}');
        expect(record.existsSync(), isFalse);
        // A stop that reached it would have ended it by now.
        final int exit = await bystander.exitCode.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () => -1,
        );
        expect(exit, -1, reason: 'the bystander was signalled');
      },
    );

    test(
      "[S4] a run file written after its process started is that process's "
      'run: it is found and kept',
      () async {
        final Directory dir = await fixture();
        final Process run = await Process.start('tail', <String>[
          '-f',
          '/dev/null',
        ]);
        addTearDown(() => run.kill(ProcessSignal.sigkill));
        final File record = File(p.join(_runsDir().path, '${run.pid}.json'))
          ..writeAsStringSync(
            jsonEncode(<String, String>{
              'packagePath': dir.resolveSymbolicLinksSync(),
              'startedAt': DateTime.now().toUtc().toIso8601String(),
            }),
          );

        final ProcessResult r = await _control('pause', dir);

        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(record.existsSync(), isTrue);
      },
    );

    test(
      '[S4] two runs in this package: without a pid exit 2, naming one acts',
      () async {
        final Directory dir = await fixture();
        // Two live processes standing in for two runs; run files hold the
        // package path and start time (key names are an open question).
        final Process a = await Process.start('tail', <String>[
          '-f',
          '/dev/null',
        ]);
        addTearDown(() => a.kill(ProcessSignal.sigkill));
        final Process b = await Process.start('tail', <String>[
          '-f',
          '/dev/null',
        ]);
        addTearDown(() => b.kill(ProcessSignal.sigkill));
        for (final Process fake in <Process>[a, b]) {
          File(p.join(_runsDir().path, '${fake.pid}.json')).writeAsStringSync(
            jsonEncode(<String, String>{
              'packagePath': dir.resolveSymbolicLinksSync(),
              'startedAt': DateTime.now().toUtc().toIso8601String(),
            }),
          );
        }

        final ProcessResult ambiguous = await _control('pause', dir);
        expect(ambiguous.exitCode, 2, reason: '${ambiguous.stderr}');
        final ProcessResult named = await _control('pause', dir, '${a.pid}');
        expect(named.exitCode, isNot(2), reason: '${named.stderr}');
      },
    );
  });
}
