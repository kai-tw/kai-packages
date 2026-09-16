import 'dart:async';
import 'dart:io';

import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A shell that backgrounds a child and waits, recording the child's pid so a
/// test can ask about it afterwards. It stands in for the shape that caused
/// the leak: `flutter test` is three processes, not one.
String _spawnerScript(String pidFile) =>
    'sleep 120 & echo \$! > "$pidFile"; wait';

/// Three levels deep, not two: the outer shell backgrounds an INNER shell
/// (level 1 — a direct child), which itself backgrounds `sleep` (level 2 —
/// a grandchild of the process this test starts) and then `wait`s on it, so
/// the chain stays alive rather than the inner shell exiting immediately and
/// leaving `sleep` reparented to init before anything gets to check. This is
/// the shape `_descendantsOf`'s breadth-first walk exists for: finding it
/// requires continuing the walk past the first level, which
/// `flutter test` -> `dartaotruntime` -> `flutter_tester` is a real-world
/// instance of.
String _threeLevelSpawnerScript(String pidFile) =>
    'sh -c \'sleep 120 & echo \$! > "$pidFile"; wait\' & wait';

bool _isAlive(int pid) =>
    (Process.runSync('ps', <String>['-o', 'pid=', '-p', '$pid']).stdout
            as String)
        .trim()
        .isNotEmpty;

void main() {
  test(
    '[partition] a command that finishes before the timeout returns its '
    'exit code',
    () async {
      const ProcessCommand command = ProcessCommand('dart', <String>[
        '--version',
      ]);
      expect(await command.run(timeout: const Duration(seconds: 30)), 0);
    },
  );

  test(
    '[boundary] a command that outlives the timeout is killed, returns '
    'null, and does not make the caller actually wait out its own runtime',
    () async {
      const ProcessCommand command = ProcessCommand('sleep', <String>['30']);
      final Stopwatch stopwatch = Stopwatch()..start();

      final int? exitCode = await command.run(
        timeout: const Duration(seconds: 1),
      );

      stopwatch.stop();
      expect(exitCode, isNull);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason: 'the 30s sleep must have actually been killed, not awaited',
      );
    },
  );

  test('[partition] no timeout given waits for the real exit code', () async {
    const ProcessCommand command = ProcessCommand('dart', <String>[
      '--version',
    ]);
    expect(await command.run(), 0);
  });

  group('the timeout kills the process TREE, not just the direct child', () {
    // The defect these guard: `flutter test` is three processes — the wrapper
    // spawns a runtime, which spawns the engine that actually runs the test —
    // and a SIGKILL to the wrapper does not propagate downward. POSIX
    // reparents an orphan to init rather than killing it, so the engine
    // survived, went on executing the mutant's infinite loop, and nothing
    // would ever reap it. Measured at roughly 130 MB/s of growth, forever,
    // from ONE timed-out mutant; two runs exhausted a workstation's memory.
    late Directory dir;
    late String pidFile;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('tree_kill_test_');
      pidFile = p.join(dir.path, 'grandchild.pid');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<int> recordedGrandchildPid() async {
      final File file = File(pidFile);
      for (int i = 0; i < 50 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return int.parse(file.readAsStringSync().trim());
    }

    test(
      '[boundary] the fixture really does orphan — killing only the direct '
      'child leaves the grandchild running',
      () async {
        // Not a test of the operating system. It is what makes the assertion
        // in the next test non-vacuous: without it, a fixture that never
        // spawned a grandchild at all would pass that test for the wrong
        // reason, and the guard would quietly stop guarding anything.
        final Process process = await Process.start('/bin/sh', <String>[
          '-c',
          _spawnerScript(pidFile),
        ]);
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        final int grandchild = await recordedGrandchildPid();

        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(
          _isAlive(grandchild),
          isTrue,
          reason: 'the single-process kill is exactly the leak being fixed',
        );
        Process.killPid(grandchild, ProcessSignal.sigkill);
      },
    );

    test('[boundary] the timeout leaves no survivor behind', () async {
      final ProcessCommand command = ProcessCommand('/bin/sh', <String>[
        '-c',
        _spawnerScript(pidFile),
      ]);

      final int? exitCode = await command.run(
        timeout: const Duration(seconds: 2),
      );

      expect(exitCode, isNull, reason: 'the fixture must have timed out');
      final int grandchild = await recordedGrandchildPid();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        _isAlive(grandchild),
        isFalse,
        reason:
            'a surviving grandchild is the unbounded leak: it outlives the '
            'run that created it and nothing will ever reap it',
      );
    });
  });

  group('the process tree walk goes past the first level', () {
    // The BFS in _descendantsOf has to continue past a process's direct
    // children to find flutter_tools's actual shape (wrapper ->
    // dartaotruntime -> flutter_tester, three levels). A fixture with only
    // two levels cannot tell "found direct children" from "found every
    // descendant" apart — this one has three.
    late Directory dir;
    late String pidFile;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('three_level_kill_test_');
      pidFile = p.join(dir.path, 'greatgrandchild.pid');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<int> recordedPid() async {
      final File file = File(pidFile);
      for (int i = 0; i < 50 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return int.parse(file.readAsStringSync().trim());
    }

    test(
      '[boundary] a process two levels down is killed too, not just a '
      'direct child',
      () async {
        final ProcessCommand command = ProcessCommand('/bin/sh', <String>[
          '-c',
          _threeLevelSpawnerScript(pidFile),
        ]);

        final int? exitCode = await command.run(
          timeout: const Duration(seconds: 2),
        );

        expect(exitCode, isNull, reason: 'the fixture must have timed out');
        final int deepDescendant = await recordedPid();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(
          _isAlive(deepDescendant),
          isFalse,
          reason:
              'a survivor two levels down means the walk stopped at the '
              'first level of children instead of continuing into theirs',
        );
      },
    );
  });

  test('[partition] toString renders the executable and its arguments', () {
    const ProcessCommand command = ProcessCommand('dart', <String>[
      'test',
      'foo_test.dart',
    ]);
    expect(command.toString(), 'dart test foo_test.dart');
  });

  test(
    '[partition] killAllRunning kills every process this class is still '
    'tracking — the escape hatch a signal handler uses, since it has no '
    'way to wait for run() to hand it a pid first',
    () async {
      const ProcessCommand command = ProcessCommand('sleep', <String>['30']);
      final Future<int?> future = command.run();

      // Give the child a moment to actually start before asking about it.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final Stopwatch stopwatch = Stopwatch()..start();
      ProcessCommand.killAllRunning();
      await future;
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason:
            'the 30s sleep must have actually been killed, not awaited '
            'out',
      );
    },
  );

  test(
    '[boundary] output larger than a pipe buffer does not deadlock the '
    'child — stdout and stderr must both be drained continuously, not just '
    'read once at the end',
    () async {
      // 200 KB comfortably exceeds a 64 KB pipe buffer on Linux. An
      // undrained pipe blocks the child's write() forever once it fills,
      // which would only ever resolve via run()'s own timeout kill — a
      // generous timeout paired with an elapsed-time assertion tells the
      // two outcomes apart.
      const ProcessCommand command = ProcessCommand('/bin/sh', <String>[
        '-c',
        'head -c 200000 /dev/zero; head -c 200000 /dev/zero 1>&2',
      ]);
      final Stopwatch stopwatch = Stopwatch()..start();
      final int? exitCode = await command.run(
        timeout: const Duration(seconds: 20),
      );
      stopwatch.stop();

      expect(
        exitCode,
        isNotNull,
        reason: 'an undrained pipe would hang until the timeout killed it',
      );
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 10)),
        reason:
            'finishing near the 20s timeout means it was rescued by the '
            'kill, not by draining',
      );
    },
  );

  test(
    '[boundary] the survivor poll obeys its own attempt budget precisely — '
    'one extra attempt, or never stopping at the budget at all, both show '
    'up as extra elapsed time',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync(
        'poll_budget_test_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final String pidFile = p.join(dir.path, 'grandchild.pid');
      final Process process = await Process.start('/bin/sh', <String>[
        '-c',
        _spawnerScript(pidFile),
      ]);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final File file = File(pidFile);
      for (int i = 0; i < 50 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      // A budget far smaller than this container's own measured SIGKILL-to-
      // gone latency (over a second, empirically — real reaping here is
      // slow enough that this fixture is guaranteed to still be alive after
      // just one poll), paired with a 500ms interval so a single extra
      // iteration (one off-by-one on the attempt bound) shows up as an
      // extra ~500ms rather than getting lost in run-to-run process-spawn
      // jitter the way a shorter interval would.
      final Stopwatch stopwatch = Stopwatch()..start();
      ProcessCommand.killTree(
        process.pid,
        maxPollAttempts: 1,
        pollInterval: const Duration(milliseconds: 500),
      );
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 800)),
        reason:
            'a 1-attempt, 500ms budget must return in roughly 500ms — a '
            'second ~500ms interval on top means either the loop ran one '
            'attempt past its budget, or the guard let it keep polling '
            'instead of stopping at the budget at all',
      );

      // The real SIGKILL above is already in flight; give it time to
      // actually finish before the next test starts, rather than leaving
      // an unreaped process behind.
      await Future<void>.delayed(const Duration(seconds: 2));
    },
  );

  test(
    '[boundary] a survivor still alive when the poll budget runs out is '
    'reported, not silently left running',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync(
        'survivor_report_test_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final String pidFile = p.join(dir.path, 'grandchild.pid');
      final Process process = await Process.start('/bin/sh', <String>[
        '-c',
        _spawnerScript(pidFile),
      ]);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final File file = File(pidFile);
      for (int i = 0; i < 50 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final int grandchild = int.parse(file.readAsStringSync().trim());

      // maxPollAttempts: 0 skips the aliveness re-check entirely — the real
      // SIGKILLs above still go out, but `survivors` is never refreshed
      // from the raw (non-empty) descendants list, so the report fires
      // deterministically regardless of how fast THIS machine actually
      // reaps a killed process (measured over a second in this sandbox,
      // apparently much faster on other runners — a fixed small poll
      // budget flaked on the difference).
      final List<String> reports = <String>[];
      ProcessCommand.killTree(
        process.pid,
        maxPollAttempts: 0,
        reportSurvivors: reports.add,
      );

      expect(reports, hasLength(1));
      expect(reports.single, contains('1 subprocess(es) survived'));
      expect(reports.single, contains('$grandchild'));

      // The real SIGKILL above is already in flight; give it time to
      // actually finish before the next test starts, rather than leaving
      // an unreaped process behind.
      await Future<void>.delayed(const Duration(seconds: 2));
    },
  );

  group('what this class is tracking is directly inspectable in tests', () {
    test(
      '[partition] a completed run stops being tracked — its pid is gone '
      'from trackedPidsForTest once run() returns',
      () async {
        final Directory dir = Directory.systemTemp.createTempSync(
          'tracked_pid_test_',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final String pidFile = p.join(dir.path, 'self.pid');
        final ProcessCommand command = ProcessCommand('/bin/sh', <String>[
          '-c',
          'echo \$\$ > "$pidFile"',
        ]);

        final int? exitCode = await command.run();

        expect(exitCode, 0);
        final int pid = int.parse(File(pidFile).readAsStringSync().trim());
        expect(
          ProcessCommand.trackedPidsForTest(),
          isNot(contains(pid)),
          reason:
              'run() must stop tracking its own pid once it returns, or a '
              'later killAllRunning() would try to kill a process that has '
              'nothing to do with the run it was actually called for',
        );
      },
    );

    test(
      '[partition] killAllRunning clears its own tracking set immediately '
      '— not implicitly, later, whenever the killed process\'s own run() '
      'call gets around to noticing it exited',
      () async {
        const ProcessCommand command = ProcessCommand('sleep', <String>[
          '30',
        ]);
        final Future<int?> future = command.run();
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // killAllRunning is synchronous, so checking right after it
        // returns — before awaiting future — catches its OWN clear()
        // specifically. run()'s finally also removes this same pid once
        // its awaited exitCode resolves, but that needs at least one more
        // event-loop turn than a plain synchronous call gets, so it cannot
        // have run yet here.
        ProcessCommand.killAllRunning();

        expect(
          ProcessCommand.trackedPidsForTest(),
          isEmpty,
          reason:
              'a set killAllRunning forgot to clear would make a LATER '
              'call try to kill a pid that finished or was already killed, '
              'rather than starting from nothing',
        );

        await future;
      },
    );
  });

  test(
    '[boundary] the killed root process is actually reaped, not left a '
    'zombie for nothing to wait on',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync('reap_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String pidFile = p.join(dir.path, 'root.pid');
      // `exec` replaces the shell's own process image but keeps its pid, so
      // the pid this records is exactly the one run() starts, kills, and is
      // responsible for reaping — there is no separate descendant here.
      final ProcessCommand command = ProcessCommand('/bin/sh', <String>[
        '-c',
        'echo \$\$ > "$pidFile"; exec sleep 30',
      ]);

      final int? exitCode = await command.run(
        timeout: const Duration(seconds: 1),
      );

      expect(exitCode, isNull, reason: 'the fixture must have timed out');
      final int rootPid = int.parse(File(pidFile).readAsStringSync().trim());
      final String stat =
          (Process.runSync('ps', <String>[
                    '-o',
                    'stat=',
                    '-p',
                    '$rootPid',
                  ]).stdout
                  as String)
              .trim();
      expect(
        stat,
        isNot(startsWith('Z')),
        reason:
            'a zombie means nothing ever called waitpid() on the killed '
            'process — this class started it directly, so reaping it was '
            'always this class\'s own job, not the OS init\'s',
      );
    },
  );

  group('processTableForTest', () {
    test('[partition] parses pid/ppid pairs and skips malformed rows', () {
      expect(
        ProcessCommand.processTableForTest(
          () => ProcessResult(0, 0, '  10   1\n 11 10\nbogus\n\n x 3\n', ''),
        ),
        <List<int>>[
          <int>[10, 1],
          <int>[11, 10],
        ],
      );
    });

    test('[boundary] no `ps` degrades to an empty table, and says so', () {
      final _RecordingStdout err = _RecordingStdout();

      final List<List<int>> table = IOOverrides.runZoned(
        () => ProcessCommand.processTableForTest(
          () => throw const ProcessException('ps', <String>[]),
        ),
        stderr: () => err,
      );

      expect(table, isEmpty);
      expect(err.text.toString(), contains('no `ps` on this platform'));
    });
  });
}

class _RecordingStdout implements Stdout {
  final StringBuffer text = StringBuffer();

  @override
  void writeln([Object? object = '']) => text.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
