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
    '[S4] stop ends the run before the remaining mutants are scored, and '
    'removes its run file',
    () async {
      final Directory dir = await fixture();
      final (Process, String) run = await _startRun(dir, marker);
      final String pid = run.$2;

      expect((await _control('stop', dir)).exitCode, 0);
      await run.$1.exitCode;

      expect(File(p.join(_runsDir().path, '$pid.json')).existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 4)),
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
      '[S4] two runs in this package: without a pid exit 2, naming one acts',
      () async {
        final Directory dir = await fixture();
        // Two live processes standing in for two runs; run files hold the
        // package path and start time (key names are an open question).
        final Process a = await Process.start('tail', <String>[
          '-f',
          '/dev/null',
        ]);
        final Process b = await Process.start('tail', <String>[
          '-f',
          '/dev/null',
        ]);
        addTearDown(() {
          a.kill();
          b.kill();
        });
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
