import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../mutant.dart';
import 'compile_safety_gate.dart';
import 'mutant_result.dart';
import 'mutant_verdict.dart';
import 'run_control.dart';
import 'switched_file.dart';
import 'switched_job.dart';
import 'switched_stats.dart';
import 'switched_toolchain.dart';
import 'temp_space.dart';
import 'test_compiler.dart';
import 'test_slot.dart';
import 'test_slots.dart';
import 'worker_sandbox.dart';

/// Runs mutants as switched files: every mutant of a file written in at
/// once (see [switchMutants]), each test file compiled once, and each mutant
/// run by starting the compiled program with [mutantIdVariable] set.
///
/// `flutter test` and `dart test` compile every test file they run, every
/// time — 2–3.5s a file on a large app even when nothing changed — so a
/// mutant that 30 test files reach costs over a minute before any test runs.
/// Here that is paid once per test file for the whole run.
///
/// A mutant that cannot be switched — in a constant context, a whole local
/// declaration, a part file, or one that stops its file compiling beside the
/// others — is compiled alone: written into the file as it is, with each of
/// its test files compiled again around it. That costs what a test-runner
/// run would, for those few mutants only.
///
/// Each of [workers] lanes has its own copy of the package (a
/// [WorkerSandbox]), compiler and test process; the package itself is never
/// written to. The copies go when the run ends, or with the run's other
/// temporary directories when it is interrupted or killed.
///
/// A lane holds one of [slots] while it compiles or runs a test file, and
/// waits for one before it does; it gives it back while paused, while it
/// waits on another lane, and when it has nothing left to run.
///
/// A test file has to compile and pass with no mutant on before any mutant
/// runs against it. One that does not means this run would not run what the
/// test command runs, so the whole run stops, naming the file — scoring
/// mutants against it would read every one of them as detected.
///
/// A test file no mutant still waits on is not run at all, not even
/// unmutated: once every mutant that listed it is settled — detected by an
/// earlier file, say — it has nothing left to decide.
class SwitchedRunner {
  SwitchedRunner({
    required this.toolchain,
    required this.root,
    required this.gateFor,
    required this.temps,
    required this.testFileTimeout,
    required this.budgetFrom,
    required this.onResult,
    required this.stats,
    required this.control,
    required this.slots,
    this.onSlotWait,
    this.workers = 1,
    this.arguments = const <String>[],
    this.testTimeout,
    this.shouldStop,
    this.selectByReach = false,
  });

  /// Run a switched mutant only against the test files whose unmutated run
  /// reached its switch — see [reachedVariable]. A test file that does not
  /// reach the switch runs, with the mutant on, exactly what it runs with it
  /// off, so it cannot detect it. A switched mutant no test file reaches is
  /// undetected and uncovered, settled without running it.
  ///
  /// A mutant compiled alone has no switch to reach, and runs against every
  /// test file it was given that its switch did not already rule out.
  final bool selectByReach;

  final SwitchedToolchain toolchain;

  /// The package's directory.
  final String root;

  /// The gate that judges a target file, by its path.
  final SourceCompileSafetyGate Function(String file) gateFor;
  final TempSpace temps;
  final int workers;

  /// The test command's own filtering options, handed to every test file.
  final List<String> arguments;

  /// The longest one test may run, unmutated or with a mutant on, before it
  /// fails; `null` leaves it to the test's own timeout. See
  /// `runSwitchedSuite`.
  final Duration? testTimeout;

  /// How long one test file's compile, or its unmutated run, may take.
  final Duration testFileTimeout;

  /// A mutant's budget on a test file, from how long that file took
  /// unmutated.
  final Duration Function(Duration unmutated) budgetFrom;

  /// Called with each mutant's result as soon as it has one, the lane that
  /// settled it, and how long its own test runs took.
  final void Function(
    SwitchedJob job,
    MutantResult result,
    int lane,
    Duration tests,
  )
  onResult;

  final SwitchedStats stats;

  /// Checked between runs; `true` ends the run, leaving every mutant without
  /// a result.
  final bool Function()? shouldStop;

  /// Checked between runs too: while it is paused, a lane closes its
  /// compiler and waits — see [_waitOutPause].
  final RunControl control;

  /// The test slots the lanes share with every other run on the machine;
  /// `null` puts no limit on them.
  final TestSlots? slots;

  /// Called with `true` when the run starts waiting for a slot — a lane
  /// waiting for one, and none holding one — and with `false` when that
  /// wait ends, so a clock can leave the wait out.
  final void Function(bool waiting)? onSlotWait;

  /// Lanes holding a slot, and lanes waiting for one.
  int _holding = 0;
  int _waitingForSlot = 0;

  /// What [onSlotWait] was last told.
  bool _slotWaitReported = false;

  /// The test files each mutant still has to pass on, by id. A mutant whose
  /// set empties survived.
  final Map<int, Set<String>> _remaining = <int, Set<String>>{};

  /// Each mutant's own test time so far, by id.
  final Map<int, Duration> _spent = <int, Duration>{};

  final Set<int> _settled = <int>{};

  /// Under [selectByReach], the mutants some test file's unmutated run
  /// reached.
  final Set<int> _reached = <int>{};

  /// The budget each mutant last ran under, by id.
  final Map<int, Duration> _budgets = <int, Duration>{};

  /// Switched mutants, by id.
  final Map<int, SwitchedJob> _switched = <int, SwitchedJob>{};

  /// Mutants compiled alone, in order.
  final List<SwitchedJob> _alone = <SwitchedJob>[];

  /// What each switched target holds in every lane, by its path in the
  /// package.
  final Map<String, String> _sources = <String, String>{};

  /// Each target's unmodified content, by its path in the package.
  final Map<String, String> _originals = <String, String>{};

  /// Each test file's unmutated time, once a lane has it — `null` when it
  /// failed, which stops the run.
  final Map<String, Completer<Duration?>> _unmutated =
      <String, Completer<Duration?>>{};

  List<String> _files = <String>[];
  int _nextFile = 0;
  int _nextAlone = 0;

  /// Why the run cannot be trusted, once a lane finds out — see [_fail].
  String? _failure;

  bool get _stopped => _failure != null || (shouldStop?.call() ?? false);

  /// Whether a test file or a mutant compiled alone is still unclaimed.
  bool get _workLeft => _nextFile < _files.length || _nextAlone < _alone.length;

  /// Each lane's wait for a slot, completed to end the wait once its
  /// condition holds — see [_readyToRun].
  final Map<Completer<void>, bool Function()> _slotWaits =
      <Completer<void>, bool Function()>{};

  /// Runs [jobs]: `null` when each got a result or [shouldStop] ended the
  /// run, otherwise why the run stopped.
  Future<String?> run(List<SwitchedJob> jobs) async {
    if (jobs.isEmpty) {
      return null;
    }
    for (final SwitchedJob job in jobs) {
      _remaining[job.id] = job.tests.toSet();
    }
    final Stopwatch clock = Stopwatch()..start();
    await _switchAll(jobs);
    stats
      ..switching = clock.elapsed
      ..switched = _switched.length
      ..alone = _alone.length;
    _files = <String>{for (final SwitchedJob job in jobs) ...job.tests}.toList()
      ..sort();
    for (final String file in _files) {
      _unmutated[file] = Completer<Duration?>();
    }
    final List<_Lane> lanes = <_Lane>[
      for (int id = 0; id < workers; id++) _lane(id),
    ];
    try {
      await Future.wait(<Future<void>>[for (final _Lane l in lanes) _drain(l)]);
    } finally {
      await _closeLanes(lanes);
    }
    return _outcome(jobs);
  }

  /// [lanes] closed, their slots given back and their directories deleted,
  /// their disk use kept.
  Future<void> _closeLanes(List<_Lane> lanes) async {
    for (final _Lane lane in lanes) {
      _giveBackSlot(lane);
      await lane.compiler.close();
      temps
        ..delete(lane.work)
        ..delete(Directory(lane.box.directory));
    }
    stats.workerDiskBytes = <int>[
      for (final _Lane lane in lanes) lane.diskBytes,
    ];
  }

  /// Why the run of [jobs] cannot be trusted, or `null`.
  String? _outcome(List<SwitchedJob> jobs) {
    if (_failure case final String failure) {
      return failure;
    }
    final int open = jobs
        .where((SwitchedJob j) => !_settled.contains(j.id))
        .length;
    if (open > 0 && !_stopped) {
      return '$open mutants were left without a result';
    }
    return null;
  }

  /// Every file of [jobs] switched, into [_sources]; each job lands in
  /// [_switched] or [_alone].
  Future<void> _switchAll(List<SwitchedJob> jobs) async {
    final Map<String, List<SwitchedJob>> byFile = <String, List<SwitchedJob>>{};
    for (final SwitchedJob job in jobs) {
      byFile.putIfAbsent(job.mutant.filePath, () => <SwitchedJob>[]).add(job);
    }
    for (final MapEntry<String, List<SwitchedJob>> file in byFile.entries) {
      final SwitchedFile switched = await _verified(file.key, file.value);
      _originals[file.key] = file.value.first.source;
      _sources[file.key] = switched.source;
      for (final SwitchedJob job in file.value) {
        if (switched.switched.contains(job.id)) {
          _switched[job.id] = job;
        } else {
          _alone.add(job);
          stats.aloneFor(switched.skipped[job.id] ?? 'not switched');
        }
      }
    }
  }

  /// A lane: its own copy of the package with every switched file written
  /// in, and its own compiler.
  _Lane _lane(int id) {
    final WorkerSandbox box = WorkerSandbox.create(
      id: id,
      root: root,
      targets: _sources.keys.toList(),
      temps: temps,
      flutter: toolchain is FlutterToolchain,
    );
    final Directory work = temps.create('switched$id');
    toolchain.prepare(work.path);
    final String packageConfig = p.join(
      box.directory,
      '.dart_tool',
      'package_config.json',
    );
    return _Lane(
      id,
      box,
      work.path,
      packageConfig,
      TestCompiler(
        toolchain.compiler(
          outputDill: p.join(work.path, 'test.dill'),
          packageConfig: packageConfig,
        ),
        workingDirectory: box.directory,
      ),
      work,
    )..sync(_sources);
  }

  /// Each of [files] back to its unmodified content in every lane, and each
  /// of its switched mutants still without a result moved to [_alone] —
  /// `true` when any was still switched.
  bool _unswitch(Iterable<String> files) {
    bool changed = false;
    for (final String file in files.toSet()) {
      if (_sources[file] == _originals[file]) {
        continue;
      }
      changed = true;
      _sources[file] = _originals[file]!;
      for (final SwitchedJob job in _switched.values.toList()) {
        if (job.mutant.filePath != file) {
          continue;
        }
        _switched.remove(job.id);
        if (!_settled.contains(job.id)) {
          _alone.add(job);
          stats
            ..switched -= 1
            ..alone += 1
            ..aloneFor('breaks a test file switched');
        }
      }
    }
    return changed;
  }

  /// [lane] takes test files until none is left, then mutants to compile
  /// alone.
  ///
  /// It stops waiting for a slot once the other lanes have claimed the
  /// last of the work, or the run stops: a slot that comes free hours later,
  /// after another run on the machine is done with it, would otherwise hold
  /// back a run whose results are all in.
  Future<void> _drain(_Lane lane) async {
    try {
      while (!_stopped && _workLeft) {
        final bool ready = await _readyToRun(
          lane,
          giveUpWhen: () => _stopped || !_workLeft,
        );
        // Stopped, or the work all claimed, while it waited: the loop's
        // test ends it, and [run] reports why.
        if (!ready || _stopped) {
          continue;
        }
        if (_nextFile < _files.length) {
          final String file = _files[_nextFile++];
          _wakeSlotWaits();
          if (_waitedOn(file)) {
            await _runFile(lane, file);
          } else {
            // No waiter is left to read it, nor can one come: the mutants
            // still open, alone ones included, do not list this file.
            _unmutated[file]!.complete(Duration.zero);
            stats.skippedTestFiles += 1;
          }
        } else if (_nextAlone < _alone.length) {
          final SwitchedJob job = _alone[_nextAlone++];
          _wakeSlotWaits();
          await _runAlone(lane, job);
        }
      }
    } finally {
      _giveBackSlot(lane);
    }
  }

  /// Whether a mutant without a result still has to pass on [file].
  bool _waitedOn(String file) => _remaining.entries.any(
    (MapEntry<int, Set<String>> e) =>
        !_settled.contains(e.key) && e.value.contains(file),
  );

  /// [file] compiled and run unmutated, then once per switched mutant still
  /// waiting on it.
  Future<void> _runFile(_Lane lane, String file) async {
    final Duration? unmutated = await _unmutatedRun(lane, file);
    // [_failure] says why, and the run stops with it.
    if (unmutated == null) {
      return;
    }
    final Duration budget = budgetFrom(unmutated);
    for (final SwitchedJob job in _switched.values.toList()) {
      if (_settled.contains(job.id) || !_remaining[job.id]!.contains(file)) {
        continue;
      }
      // Stopped: [run] reports why.
      if (!await _readyToRun(lane, giveUpWhen: () => _stopped) || _stopped) {
        return;
      }
      final int? exitCode = await _timed(
        job,
        () => lane.run(toolchain, job.id, budget),
      );
      _settle(job, file, exitCode, budget, lane.id);
    }
  }

  /// [_prepare]'s answer for [file], given to every lane waiting on it — an
  /// environment failure on the way included, as `null` with [_failure]
  /// saying why, so no lane waits on [file] forever.
  Future<Duration?> _unmutatedRun(_Lane lane, String file) async {
    Duration? unmutated;
    try {
      unmutated = await _prepare(lane, file);
    } on FileSystemException catch (e) {
      // Writing the lane's copy or the test entry failed: a full disk, say.
      _fail(
        '$file could not be written for a switched run: ${e.message} '
        '(${e.path})',
      );
    } on ProcessException catch (e) {
      _fail(
        '$file could not be run in a switched run: ${e.executable} would not '
        'start (${e.message})',
      );
    } finally {
      _unmutated[file]!.complete(unmutated);
    }
    return unmutated;
  }

  /// Compiles [file] in [lane] and runs it unmutated: how long that run
  /// took, or `null` once [_failure] says why it could not be had.
  ///
  /// A switch can change what a declaration's type is inferred as — a
  /// `final name = given ?? 'none';` whose switched `??` reads as nullable —
  /// which breaks a file that uses it while the switched file itself
  /// compiles. So a test file that does not compile is tried again with the
  /// files its own mutants sit in unswitched, then with every file
  /// unswitched, those files' mutants compiled alone instead; only a test
  /// file that still does not compile stops the run.
  Future<Duration?> _prepare(_Lane lane, String file) async {
    final Stopwatch clock = Stopwatch()..start();
    final bool compiled = await _compileUnswitching(lane, file);
    stats.compiling += clock.elapsed;
    if (!compiled) {
      _fail(
        '$file does not compile in a switched run',
      );
      return null;
    }
    final File? reached = selectByReach ? lane.reachedFile() : null;
    clock.reset();
    final int? exitCode = await lane.run(
      toolchain,
      null,
      testFileTimeout,
      reached: reached?.path,
    );
    final Duration took = clock.elapsed;
    stats.unmutated += took;
    if (exitCode != 0) {
      _fail(
        '$file ${exitCode == null ? 'did not finish within '
                  '${testFileTimeout.inSeconds}s' : 'failed (exit $exitCode)'} '
        'unmutated in a switched run',
      );
      return null;
    }
    if (reached != null) {
      _narrow(file, _idsIn(reached), lane.id);
    }
    return took;
  }

  /// The ids [file] holds, one a line; none when it was never written.
  static Set<int> _idsIn(File file) => file.existsSync()
      ? file.readAsLinesSync().map(int.tryParse).nonNulls.toSet()
      : const <int>{};

  /// Drops [file] from every switched mutant [reached] leaves out, settling
  /// one that has no file left: [file]'s unmutated run did not reach it, so
  /// it would not detect it. The ones moved to [_alone] while [file] compiled
  /// are left as they are: [file] ran them unswitched, so it says nothing
  /// about them.
  void _narrow(String file, Set<int> reached, int lane) {
    for (final SwitchedJob job in _switched.values) {
      final Set<String> remaining = _remaining[job.id]!;
      if (_settled.contains(job.id) || !remaining.contains(file)) {
        continue;
      }
      if (reached.contains(job.id)) {
        _reached.add(job.id);
        continue;
      }
      remaining.remove(file);
      stats.unreachedRuns += 1;
      if (remaining.isEmpty) {
        _resolve(
          job,
          lane,
          MutantResult(
            mutant: job.mutant,
            verdict: MutantVerdict.undetected,
            uncovered: !_reached.contains(job.id),
            timeout: _budgets[job.id],
          ),
        );
      }
    }
  }

  /// [file] compiled in [lane], tried again as [_prepare] describes while it
  /// does not compile and there is a file left to unswitch.
  Future<bool> _compileUnswitching(_Lane lane, String file) async {
    bool compiled = await _compile(lane, file);
    if (!compiled &&
        _unswitch(<String>[
          for (final SwitchedJob job in _switched.values)
            if (job.tests.contains(file)) job.mutant.filePath,
        ])) {
      compiled = await _compile(lane, file);
    }
    if (!compiled && _unswitch(_sources.keys.toList())) {
      compiled = await _compile(lane, file);
    }
    return compiled;
  }

  /// [lane]'s copy brought up to date with [_sources], then [testFile]'s
  /// entry compiled.
  Future<bool> _compile(_Lane lane, String testFile) {
    stats.compiledTestFiles += 1;
    lane.sync(_sources);
    return lane.compile(
      toolchain,
      root,
      testFile,
      arguments,
      testFileTimeout,
      testTimeout: testTimeout,
    );
  }

  /// [job]'s mutant written into its file as it is, and each test file it
  /// has not yet passed on compiled around it and run until one decides it.
  Future<void> _runAlone(_Lane lane, SwitchedJob job) async {
    final String file = job.mutant.filePath;
    lane.hold(file, job.mutant.applyTo(job.source));
    try {
      for (final String test in _remaining[job.id]!.toList()..sort()) {
        final Completer<Duration?> unmutatedRun = _unmutated[test]!;
        // Another lane is still running [test] unmutated, and may need this
        // very slot to do it.
        if (!unmutatedRun.isCompleted) {
          _giveBackSlot(lane);
        }
        final Duration? unmutated = await unmutatedRun.future;
        if (unmutated == null ||
            !await _readyToRun(lane, giveUpWhen: () => _stopped) ||
            _stopped ||
            _settled.contains(job.id)) {
          return;
        }
        final Duration budget = budgetFrom(unmutated);
        final Stopwatch clock = Stopwatch()..start();
        final bool compiled = await _compile(lane, test);
        stats.compiling += clock.elapsed;
        // The same files compiled with this test file unmutated, so one that
        // no longer compiles with the mutant in fails to load under the test
        // command, and a load failure is a failed test.
        final int? exitCode = compiled
            ? await _timed(job, () => lane.run(toolchain, null, budget))
            : 1;
        _settle(job, test, exitCode, budget, lane.id);
      }
    } finally {
      lane.release(file);
    }
  }

  /// Waits until [lane] may run: the run not paused, and [lane] holding a
  /// slot — `true` then, or `false` once [giveUpWhen] holds while it waits
  /// for a slot. Called only between runs, so neither a pause nor a wait for
  /// a slot cuts a test file's run short, and no run's budget counts either.
  Future<bool> _readyToRun(
    _Lane lane, {
    required bool Function() giveUpWhen,
  }) async {
    await _waitOutPause(lane);
    final TestSlots? shared = slots;
    while (shared != null && lane.slot == null) {
      if (giveUpWhen()) {
        return false;
      }
      final Completer<void> giveUp = Completer<void>();
      _slotWaits[giveUp] = giveUpWhen;
      _waitingForSlot += 1;
      _reportSlotWait();
      final TestSlot? slot = await shared.acquire(until: giveUp.future);
      _slotWaits.remove(giveUp);
      _waitingForSlot -= 1;
      if (slot == null) {
        _reportSlotWait();
        return false;
      }
      lane.slot = slot;
      _holding += 1;
      _reportSlotWait();
      // A pause that came during the wait gives the slot straight back.
      await _waitOutPause(lane);
    }
    return true;
  }

  /// Ends each wait for a slot whose condition now holds. Called wherever
  /// one can come to hold: work claimed, a mutant settled — which can stop
  /// the run through [shouldStop] — and the run failing.
  void _wakeSlotWaits() {
    for (final MapEntry<Completer<void>, bool Function()> wait
        in _slotWaits.entries.toList()) {
      if (wait.value()) {
        _slotWaits.remove(wait.key);
        wait.key.complete();
      }
    }
  }

  /// Records why the run cannot be trusted — the first reason only — and
  /// ends every lane's wait for a slot.
  void _fail(String reason) {
    _failure ??= reason;
    _wakeSlotWaits();
  }

  /// Waits while [control] is paused, [lane]'s slot given back and its
  /// compiler closed meanwhile, so a paused run holds neither; the lane's
  /// next compile starts a new compiler.
  Future<void> _waitOutPause(_Lane lane) async {
    while (control.isPaused) {
      _giveBackSlot(lane);
      await lane.compiler.close();
      await control.resumed;
    }
  }

  /// [lane]'s slot back to [slots]. A lane holding none — it has not
  /// taken one yet, or already gave it back to wait — has nothing to give.
  void _giveBackSlot(_Lane lane) {
    final TestSlot? slot = lane.slot;
    if (slot == null) {
      return;
    }
    slot.release();
    lane.slot = null;
    _holding -= 1;
    _reportSlotWait();
  }

  void _reportSlotWait() {
    final bool waiting = _holding == 0 && _waitingForSlot > 0;
    if (waiting != _slotWaitReported) {
      _slotWaitReported = waiting;
      onSlotWait?.call(waiting);
    }
  }

  Future<int?> _timed(SwitchedJob job, Future<int?> Function() run) async {
    final Stopwatch clock = Stopwatch()..start();
    final int? exitCode = await run();
    _spent[job.id] = (_spent[job.id] ?? Duration.zero) + clock.elapsed;
    return exitCode;
  }

  /// Gives [job] its result when [exitCode] on [file] decides one: a failed
  /// run is a detection, one that did not finish a timeout, and a pass
  /// decides only once every test file of the mutant has passed.
  void _settle(
    SwitchedJob job,
    String file,
    int? exitCode,
    Duration budget,
    int lane,
  ) {
    if (_settled.contains(job.id)) {
      return;
    }
    _budgets[job.id] = budget;
    final Set<String> remaining = _remaining[job.id]!..remove(file);
    final MutantVerdict? verdict = switch (exitCode) {
      null => MutantVerdict.timeout,
      0 => remaining.isEmpty ? MutantVerdict.undetected : null,
      _ => MutantVerdict.detected,
    };
    if (verdict == null) {
      return;
    }
    _resolve(
      job,
      lane,
      MutantResult(mutant: job.mutant, verdict: verdict, timeout: budget),
    );
  }

  /// Records [result] as [job]'s, once.
  void _resolve(SwitchedJob job, int lane, MutantResult result) {
    _settled.add(job.id);
    onResult(job, result, lane, _spent[job.id] ?? Duration.zero);
    _wakeSlotWaits();
  }

  /// [jobs]' file switched with as many of them as still compile together:
  /// all at once when that compiles, or else each added in turn and kept
  /// only when the file still compiles with it — a mutant that, switched,
  /// hides a null check flow analysis relied on further down, say.
  Future<SwitchedFile> _verified(String file, List<SwitchedJob> jobs) async {
    final String source = jobs.first.source;
    final SwitchedFile all = switchMutants(source, <int, Mutant>{
      for (final SwitchedJob job in jobs) job.id: job.mutant,
    });
    if (all.switched.isEmpty ||
        await gateFor(file).compilesSource(file, all.source)) {
      return all;
    }
    final Map<int, Mutant> kept = <int, Mutant>{};
    final Map<int, String> skipped = <int, String>{...all.skipped};
    for (final SwitchedJob job in jobs.where(
      (SwitchedJob j) => all.switched.contains(j.id),
    )) {
      final Map<int, Mutant> tried = <int, Mutant>{...kept, job.id: job.mutant};
      if (await gateFor(file).compilesSource(
        file,
        switchMutants(source, tried).source,
      )) {
        kept[job.id] = job.mutant;
      } else {
        skipped[job.id] = 'does not compile switched';
      }
    }
    final SwitchedFile last = switchMutants(source, kept);
    return SwitchedFile(last.source, last.switched, <int, String>{
      ...skipped,
      ...last.skipped,
    });
  }
}

/// One lane's copy of the package, compiler and work directory.
class _Lane {
  _Lane(
    this.id,
    this.box,
    this.workPath,
    this.packageConfig,
    this.compiler,
    this.work,
  ) : _entry = p.join(box.directory, 'dart_mutants_test_entry.dart'),
      _dill = p.join(workPath, 'test.dill');

  final int id;
  final WorkerSandbox box;
  final String workPath;
  final String packageConfig;
  final TestCompiler compiler;
  final Directory work;
  final String _entry;
  final String _dill;

  /// Files written since the last compile, which the next one reads again.
  final Set<String> _changed = <String>{};

  /// The test slot this lane holds, or `null` — see
  /// [SwitchedRunner._readyToRun].
  TestSlot? slot;

  int get diskBytes =>
      Directory(box.directory).existsSync() ? box.diskBytes() : 0;

  /// What this lane's copy holds for each target, by its path in the
  /// package.
  final Map<String, String> _written = <String, String>{};

  /// The target holding a mutant compiled alone, which [sync] leaves be.
  String? _held;

  /// Writes [content] to [file] (a path in the package) in this lane's copy.
  void _write(String file, String content) {
    if (_written[file] == content) {
      return;
    }
    final String path = box.pathFor(file);
    box.write(path, content);
    _written[file] = content;
    _changed.add(path);
  }

  /// Writes every one of [sources] this copy does not hold yet, but the
  /// file a mutant compiled alone is held in.
  void sync(Map<String, String> sources) => sources.forEach(
    (String file, String content) {
      if (file != _held) {
        _write(file, content);
      }
    },
  );

  /// Writes [content], a mutant compiled alone, to [file] until [release].
  void hold(String file, String content) {
    _held = file;
    _write(file, content);
  }

  /// Lets [sync] write [file] again.
  void release(String file) {
    if (_held == file) {
      _held = null;
    }
  }

  /// Compiles the entry for [testFile] (relative to [root]).
  Future<bool> compile(
    SwitchedToolchain toolchain,
    String root,
    String testFile,
    List<String> arguments,
    Duration timeout, {
    Duration? testTimeout,
  }) async {
    File(_entry).writeAsStringSync(
      toolchain.entry(
        box.pathFor(p.join(root, testFile)),
        root: box.directory,
        arguments: arguments,
        testTimeout: testTimeout,
      ),
    );
    final bool compiled = await compiler.compile(
      _entry,
      timeout,
      changed: _changed,
    );
    // Read again either way: a compile that failed stopped the compiler,
    // and the next one starts afresh.
    _changed.clear();
    return compiled;
  }

  /// The file the next run writes the switches it reaches to, emptied.
  File reachedFile() {
    final File file = File(p.join(workPath, 'reached'));
    if (file.existsSync()) {
      file.deleteSync();
    }
    return file;
  }

  /// The last compiled program, run with [mutantId] on — `null` none — for
  /// at most [timeout]: its exit code, or `null` when it did not finish. It
  /// writes the switches it reaches to [reached], when given.
  Future<int?> run(
    SwitchedToolchain toolchain,
    int? mutantId,
    Duration timeout, {
    String? reached,
  }) => toolchain
      .command(
        _dill,
        workingDirectory: box.directory,
        packageConfig: packageConfig,
        work: workPath,
        mutantId: mutantId,
        reached: reached,
      )
      .run(timeout: timeout);
}
