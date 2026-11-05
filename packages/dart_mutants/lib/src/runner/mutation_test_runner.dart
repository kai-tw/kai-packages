import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;
import 'package:test_core/src/runner/configuration.dart' show Configuration;

import '../generated_file_filter.dart';
import '../mutant.dart';
import '../mutation_operator.dart';
import '../mutation_visitor.dart';
import '../operators.dart';
import '../version.dart';
import 'compile_safety_gate.dart';
import 'coverage_map.dart';
import 'file_mutation_report.dart';
import 'host_load.dart';
import 'line_range.dart';
import 'mutant_filter.dart';
import 'mutant_progress.dart';
import 'mutant_result.dart';
import 'mutant_scope.dart';
import 'mutant_timing.dart';
import 'mutant_verdict.dart';
import 'mutated_file_registry.dart';
import 'mutation_run_report.dart';
import 'process_command.dart';
import 'run_budget.dart';
import 'run_journal.dart';
import 'run_plan.dart';
import 'run_stats.dart';
import 'switched_job.dart';
import 'switched_runner.dart';
import 'switched_stats.dart';
import 'switched_toolchain.dart';
import 'temp_space.dart';
import 'test_invocation.dart';
import 'test_selection.dart';
import 'wait_span.dart';
import 'worker_sandbox.dart';

/// Runs every operator's mutants against [testCommand] and scores the
/// result.
///
/// The contract this whole package exists to serve: hand it a file list and
/// a test command, get back per-file totals and the actual survivors. Which
/// files to pass, whether the score is good enough, and what to do about a
/// surviving mutant are all outside this class on purpose — that is policy,
/// decided by whoever calls this, not by the engine running the mutants.
///
/// Every mutant runs as a switched file — see [SwitchedRunner]: each test
/// file is compiled once for the whole run and run once per mutant, in a
/// copy of the package, so the package itself is never written to. There is
/// no other way a mutant runs. A run that cannot do this stops before the
/// baseline, as [AbortKind.switchedRunUnavailable], saying why.
class MutationTestRunner {
  MutationTestRunner({
    required this.testCommand,
    required this.compileSafetyGate,
    this.fallbackCompileSafetyGate,
    this.onGateFallback,
    List<MutationOperator>? operators,
    this.mutantTimeout = const Duration(seconds: 30),
    this.baselineFactor = defaultBaselineFactor,
    Duration? baselineTimeout,
    this.selectByCoverage = false,
    this.onPlan,
    this.onProgress,
    TempSpace? tempSpace,
    this.workers = 1,
    this.runBudget,
    this.journalPath,
    this.onJournalDiscarded,
    Map<String, Set<int>>? lines,
    this.perLine,
  }) : lines = lines == null
           ? null
           : <String, Set<int>>{
               for (final MapEntry<String, Set<int>> e in lines.entries)
                 _pathKey(e.key): e.value,
             },
       tempSpace = tempSpace ?? TempSpace(),
       operators = operators ?? defaultOperators(),
       baselineTimeout = baselineTimeout ?? mutantTimeout * 10 {
    if (workers < 1) {
      throw ArgumentError.value(workers, 'workers', 'must be 1 or more');
    }
    if (baselineFactor.isNaN ||
        baselineFactor.isInfinite ||
        baselineFactor < 0) {
      throw ArgumentError.value(
        baselineFactor,
        'baselineFactor',
        'must be a finite number, 0 or more',
      );
    }
  }

  /// See [baselineFactor]. 4 rather than 3 because the one drift
  /// measured was 3.2×, which 3 would not have covered.
  static const double defaultBaselineFactor = 4;

  /// A `dart test …` or `flutter test …` command, run in the package.
  final ProcessCommand testCommand;
  final CompileSafetyGate compileSafetyGate;

  /// Used instead of [compileSafetyGate] for any file that gate rejects
  /// before it has been mutated at all — see [run]. `null` means there is
  /// nothing to fall back to, and such a file aborts the run.
  final CompileSafetyGate? fallbackCompileSafetyGate;

  /// Called with a file that [compileSafetyGate] rejected unmodified and
  /// [fallbackCompileSafetyGate] will judge instead — a decision the run
  /// makes on its own, which a person should hear about.
  final void Function(String filePath)? onGateFallback;

  /// Run each mutant against only the test files that enter the function it
  /// sits in, and score a mutant in a function no test enters as undetected
  /// without running anything — see [TestSelection] and [executableScope].
  /// Without it, every mutant runs against every test file the command runs.
  ///
  /// Selecting fewer tests can lose a detection, never invent one: a test
  /// that fails when selected runs, and fails, in the full command too. So a
  /// selected score can only err low, and the known ways it does are: a
  /// mutant that changes a declaration's inferred type can break the
  /// compilation of a test file that never enters its function (in full,
  /// that reads as `detected`); code reached only from a subprocess or
  /// `Isolate.spawnUri`, whose coverage the test runner does not collect; and
  /// code whose execution depends on timing or randomness, which one coverage
  /// pass can miss.
  ///
  /// A command the coverage pass refuses — see `collectCoverage` — or a pass
  /// that fails aborts the run as [AbortKind.selectionUnavailable], before
  /// the first mutant.
  final bool selectByCoverage;

  /// Called once, before the first mutant runs, with what the run holds.
  final void Function(RunPlan plan)? onPlan;

  /// Called after every mutant, in the order they finish.
  final void Function(MutantProgress progress)? onProgress;

  final List<MutationOperator> operators;

  /// Where the run's temporary directories go. [run] deletes every one it
  /// made before it returns, and on `SIGINT`/`SIGTERM`; it also deletes the
  /// ones a run that was killed outright left behind — see [TempSpace].
  final TempSpace tempSpace;

  /// How many lanes run mutants at once, each with its own copy of the
  /// package, compiler and test process. Memory is the usual limit: a
  /// Flutter compiler and `flutter_tester` can take a gigabyte or two each.
  final int workers;

  /// How long the mutants may take, after which the run stops without
  /// scoring anything. `null`, the default, lets a run take as long as it
  /// takes. Only the pace the run is holding can say whether it will fit,
  /// and [RunBudget] decides when to trust that pace; a run that will not
  /// fit stops between mutants.
  final RunBudget? runBudget;

  /// Where to record each mutant's result as it finishes, and to reuse the
  /// results a stopped run already has — see [RunJournal] for when a result
  /// is reused. `null`, the default, records nothing.
  ///
  /// A passing baseline and a finished coverage pass are recorded too, and a
  /// start that finds them skips both: the journal only matches code whose
  /// fingerprint is unchanged, the code that baseline passed against and
  /// that map was collected from. The gate checks still run on every start.
  final String? journalPath;

  /// The only lines mutated, per target file — a diff's changed lines, so a
  /// review sees mutants in what it changed rather than in the whole file. A
  /// target with no entry is mutated whole; `null`, the default, mutates
  /// every target whole. See [narrowMutants].
  final Map<String, Set<int>>? lines;

  /// At most this many mutants on any one line; `null`, the default, keeps
  /// them all. See [narrowMutants] for which ones a line keeps.
  final int? perLine;

  static String _pathKey(String path) => p.normalize(p.absolute(path));

  /// Called with the reason a journal already at [journalPath] was started
  /// over rather than reused.
  final void Function(String reason)? onJournalDiscarded;

  RunJournal? _journal;

  /// The least time a mutant gets on one test file before it is killed and
  /// scored as [MutantVerdict.timeout] instead of waited on forever. A slow
  /// test file gets more — see [baselineFactor].
  final Duration mutantTimeout;

  /// A mutant's budget on a test file is the larger of [mutantTimeout] and
  /// this many times that file's own unmutated run in this run. `0` turns
  /// it off.
  ///
  /// The unmutated run is one sample. The multiple is there for load: the
  /// same unmodified suite on a workstation running several sessions at once
  /// was measured at 9s at its quietest and 29s at its busiest.
  ///
  /// Too small a budget does not fail safe. A mutant that would have
  /// survived and instead timed out leaves the score and the undetected list
  /// both, which is the survivor a caller most needed to see.
  final double baselineFactor;

  /// How long the baseline gets, and one test file's compile or unmutated
  /// run in the switched run. An already-hanging test command is exactly as
  /// unusable a baseline as an already-failing one. Defaults to ten times
  /// [mutantTimeout].
  final Duration baselineTimeout;

  /// Kills every running process and deletes the run's temporary
  /// directories on `SIGINT`/`SIGTERM`. Nothing is ever written to the
  /// package, so there is nothing to put back.
  final MutatedFileRegistry _signals = MutatedFileRegistry();

  int _completed = 0;
  int _planned = 0;

  /// Wall time over the mutants alone — started when the first one does, so
  /// the baseline and the coverage pass stay out of the pace they are used
  /// to project. See [runBudget].
  final Stopwatch _mutantClock = Stopwatch();

  /// Why the run stopped between mutants, once [runBudget] says the pace
  /// will not fit it. Non-null means no lane takes another job.
  String? _overBudget;

  /// Why [selectByCoverage] could not be applied, once the coverage pass
  /// says so. Non-null means the run aborts before the first mutant.
  String? _selectionUnavailable;

  /// Whether the selection came from the journal's map rather than a pass.
  bool _coverageReused = false;

  /// The current run's — see [run].
  late RunStats _stats;

  /// Runs the full session over [filePaths]. Generated files are dropped
  /// silently — they are never a meaningful target, not a policy choice a
  /// caller needs to make per run — everything else needs the caller to have
  /// already decided it belongs in this run; this class does not further
  /// filter by "was it actually covered" or any other policy question.
  ///
  /// Refuses to run at all if [testCommand] does not pass unmodified first:
  /// scoring mutants against a suite that was already red makes every one of
  /// them look detected, for a reason that has nothing to do with the
  /// mutation.
  ///
  /// The same rule, applied to the compile-safety gate: before anything is
  /// mutated, every target file that has mutants is put to the gate as it
  /// stands. A gate that rejects a target's unmodified code would score every
  /// one of its mutants `invalid` — silently, and in a shape a caller reads
  /// as "nothing to measure". Such a file is judged by
  /// [fallbackCompileSafetyGate] instead if that accepts it, and otherwise
  /// the run aborts before touching anything.
  ///
  /// That abort cannot tell its causes apart: the gate cannot read the file;
  /// the gate's own configuration rejects code that compiles (a
  /// caller-chosen command that fails on lints, or a lint promoted to an
  /// error); or the file genuinely does not compile. The baseline does not
  /// settle it, because it only vouches for files the test command loads —
  /// a broken target no test imports passes the baseline and ends up here.
  /// A file with no mutants is not put to the gate at all: there is nothing
  /// of it to judge, so nothing a wrong answer could cost.
  Future<MutationRunReport> run(List<String> filePaths) async {
    final List<String> targets = filePaths
        .where((String path) => !isGeneratedFile(path))
        .toList();

    // Armed before the baseline runs, not after: the baseline is a full test
    // command like any other, so a Ctrl-C during it orphans a subprocess tree
    // exactly the same way.
    //
    // Processes before directories: a test run killed mid-write would
    // otherwise be writing into a directory being deleted.
    _signals.armSignalRestore(
      beforeExit: () {
        ProcessCommand.killAllRunning();
        tempSpace.deleteAll();
      },
    );
    tempSpace.sweepStale();
    final RunStats stats = _stats = RunStats(
      startedAt: DateTime.now(),
      environment: _environment(),
      loadAtStart: await HostLoad.read(),
    );
    try {
      final _Switched? switched = _switchedSetup(targets);
      if (switched == null) {
        return MutationRunReport.aborted(
          stats: await _finished(stats),
          AbortKind.switchedRunUnavailable,
          'the mutants cannot run as switched files: $_unavailable. Nothing '
          'has run.',
        );
      }
      // Before the baseline, so the fingerprint is taken while every target
      // is still the code it starts from.
      _journal = _openJournal(targets);
      final _Baseline baselineRun = await _baseline();
      final Duration baseline = baselineRun.wallTime;
      final MutationRunReport? baselineAbort = await _baselineAbort(
        baselineRun,
        stats,
      );
      if (baselineAbort != null) {
        return baselineAbort;
      }

      // Every target is read and enumerated once, here, and the same lists
      // are what runs — the plan's count is the count that runs.
      final _Enumerated planned = await _enumerate(
        targets,
        switched,
        stats,
        baseline,
      );
      final MutationRunReport? gateAbort = planned.abort;
      if (gateAbort != null) {
        return gateAbort;
      }
      final List<_PlannedFile> plan = planned.files;

      final TestSelection? selection = await _selection(switched.invocation);
      if (_selectionUnavailable case final String unavailable) {
        return MutationRunReport.aborted(
          stats: await _finished(stats),
          AbortKind.selectionUnavailable,
          '--select-by-coverage cannot be applied: $unavailable. No mutant '
          'has run. Fix that, or run without --select-by-coverage to run '
          'every mutant against every test file.',
          baselineDuration: baseline,
          mutantTimeout: mutantTimeout,
        );
      }

      final List<_Job> jobs = _jobsFor(
        plan,
        planned.gates,
        selection,
        switched,
      );
      final List<MutantResult?> recalled = _recall(jobs);
      _completed = 0;
      _planned = recalled.where((MutantResult? r) => r == null).length;
      final RunPlan runPlan = RunPlan(
        fileCount: targets.length,
        mutantCount: _planned,
        reused: jobs.length - _planned,
        baseline: baseline,
        budget: mutantTimeout,
        workers: workers,
        baselineReused: baselineRun.reused,
        coverageReused: _coverageReused,
      );
      onPlan?.call(runPlan);
      final String? failure = await _runPending(
        _pending(jobs, recalled),
        switched,
        recalled,
        jobs,
      );
      final MutationRunReport? stopped = await _stopped(
        failure,
        stats,
        baseline,
      );
      if (stopped != null) {
        return stopped;
      }
      return MutationRunReport.completed(
        _fileReports(plan, _merge(recalled, jobs)),
        baselineDuration: baseline,
        mutantTimeout: mutantTimeout,
        selectedByCoverage: selection != null,
        reusedMutants: _journal == null ? null : runPlan.reused,
        stats: await _finished(stats),
      );
    } finally {
      _signals.restoreAll();
      tempSpace.deleteAll();
      await _signals.disarm();
    }
  }

  /// The abort a baseline that did not finish, or did not pass, ends the run
  /// with; `null` when it passed.
  Future<MutationRunReport?> _baselineAbort(
    _Baseline run,
    RunStats stats,
  ) async {
    final int? exitCode = run.exitCode;
    if (exitCode == null) {
      return MutationRunReport.aborted(
        stats: await _finished(stats),
        AbortKind.baselineTimeout,
        'the test command did not finish against unmodified code within '
        'the timeout (${baselineTimeout.inSeconds}s) — refusing to score '
        'mutants against a baseline that never even completes. If the '
        'suite is merely slow rather than hanging, raise the baseline '
        'timeout (--baseline-timeout).',
      );
    }
    stats.baseline = run.wallTime;
    if (exitCode != 0) {
      return MutationRunReport.aborted(
        stats: await _finished(stats),
        AbortKind.baselineFailed,
        'the test command failed against unmodified code (exit '
        '$exitCode) — refusing to score mutants against a baseline '
        'that was already red',
        baselineDuration: run.wallTime,
      );
    }
    return null;
  }

  /// Reads and enumerates every target and puts each one that has mutants to
  /// its gate. [_Enumerated.abort] is set, and the rest left short, when a
  /// gate rejects a file before it has been mutated.
  Future<_Enumerated> _enumerate(
    List<String> targets,
    _Switched switched,
    RunStats stats,
    Duration baseline,
  ) async {
    final List<_PlannedFile> plan = <_PlannedFile>[];
    final Map<String, SourceCompileSafetyGate> gates =
        <String, SourceCompileSafetyGate>{};
    final Stopwatch gateClock = Stopwatch()..start();
    for (final String filePath in targets) {
      final String source = await File(filePath).readAsString();
      final List<Mutant> mutants = _collectMutants(filePath, source);
      plan.add(_PlannedFile(filePath, source, mutants));
      if (mutants.isEmpty) {
        continue;
      }
      final CompileSafetyGate? gate = await _gateFor(filePath);
      if (gate == null) {
        stats.gateCheck = gateClock.elapsed;
        return _Enumerated.rejected(
          MutationRunReport.aborted(
            stats: await _finished(stats),
            AbortKind.gateRejectsUnmodified,
            'the compile-safety gate rejects $filePath before it has been '
            'mutated. The gate cannot read that file, or its configuration '
            'rejects code that compiles (`flutter analyze` needs '
            '--no-fatal-infos --no-fatal-warnings; a lint promoted to an '
            'error does it too), or the file does not compile and no test '
            'the command runs loads it. Refusing to score mutants with a '
            'gate that rejects the code they start from.',
            baselineDuration: baseline,
            mutantTimeout: mutantTimeout,
          ),
        );
      }
      gates[filePath] = _inMemory(gate, switched, targets);
    }
    stats.gateCheck = gateClock.elapsed;
    return _Enumerated(plan, gates);
  }

  /// The abort the pending mutants' run ended in, a failure of the run or
  /// the pace budget; `null` when it ran to the end.
  Future<MutationRunReport?> _stopped(
    String? failure,
    RunStats stats,
    Duration baseline,
  ) async {
    if (failure != null) {
      return MutationRunReport.aborted(
        stats: await _finished(stats),
        AbortKind.switchedRunFailed,
        'the switched run stopped: $failure. No mutant was scored: '
        'a run that does not run what the test command runs would read '
        'every mutant as detected.',
        baselineDuration: baseline,
        mutantTimeout: mutantTimeout,
      );
    }
    if (_overBudget case final String over) {
      return MutationRunReport.aborted(
        stats: await _finished(stats),
        AbortKind.overBudget,
        over,
        baselineDuration: baseline,
        mutantTimeout: mutantTimeout,
      );
    }
    return null;
  }

  /// Why [_switchedSetup] returned `null`.
  String? _unavailable;

  /// What the switched run needs from [testCommand] — or `null`, with the
  /// reason in [_unavailable], when it cannot have it.
  _Switched? _switchedSetup(List<String> targets) {
    final TestInvocation? invocation = TestInvocation.parse(testCommand);
    if (invocation == null) {
      _unavailable =
          'the test command is not `dart test …` or `flutter test …`';
      return null;
    }
    final String root = realPath(invocation.root);
    final _Arguments arguments = _Arguments.of(invocation);
    _unavailable =
        _packageRefusal(root, targets) ??
        _commandRefusal(invocation) ??
        arguments.refusal ??
        configRefusal(invocation);
    if (_unavailable != null) {
      return null;
    }
    final SwitchedToolchain? toolchain = _toolchain(invocation, root);
    if (toolchain == null) {
      return null;
    }
    _unavailable = _missingPackage(root, toolchain.requiredPackages);
    if (_unavailable != null) {
      return null;
    }
    return _Switched(invocation, root, toolchain, arguments.forwarded);
  }

  /// The toolchain [invocation] runs under, or `null` with the reason in
  /// [_unavailable] when it is not to be found.
  SwitchedToolchain? _toolchain(TestInvocation invocation, String root) {
    void unavailable(String reason) => _unavailable = reason;
    return switch (invocation.runner) {
      TestRunner.flutter => FlutterToolchain.locate(
        invocation.executable,
        packageRoot: root,
        onMissing: unavailable,
      ),
      TestRunner.dart => DartToolchain.locate(onMissing: unavailable),
    };
  }

  static String? _packageRefusal(String root, List<String> targets) {
    if (!File(p.join(root, 'pubspec.yaml')).existsSync()) {
      return 'the test command does not run in a package directory ($root)';
    }
    for (final String target in targets) {
      if (!p.isWithin(root, realPath(target))) {
        return '$target is outside the package the test command runs in';
      }
    }
    return null;
  }

  static String? _commandRefusal(TestInvocation invocation) {
    if (invocation.hasOptionTerminator) {
      return 'the test command uses `--`';
    }
    if (invocation.setsCoverage) {
      return 'the test command already collects coverage';
    }
    if (invocation.runsOffTheVm) {
      return 'the test command runs on a platform other than the VM';
    }
    if (invocation.unrecognised.isNotEmpty) {
      return 'the test command has arguments this cannot place: '
          '${invocation.unrecognised.join(' ')}';
    }
    if (invocation.testFiles().isEmpty) {
      return 'the test command names no *_test.dart files';
    }
    return null;
  }

  /// The first of [packages] the package at [root] does not resolve, said
  /// as a reason, or `null`.
  static String? _missingPackage(String root, List<String> packages) {
    final String config =
        WorkerSandbox.packageConfigOf(root)?.readAsStringSync() ?? '';
    for (final String package in packages) {
      if (!config.contains('"name": "$package"')) {
        return 'the package does not resolve package:$package — the '
            'compiled test files import it';
      }
    }
    return null;
  }

  /// [gate] as one that judges content in memory: itself when it can, or
  /// else asked about a copy of the package with the content written in.
  SourceCompileSafetyGate _inMemory(
    CompileSafetyGate gate,
    _Switched switched,
    List<String> targets,
  ) {
    if (gate is SourceCompileSafetyGate) {
      return gate;
    }
    return switched.copyGates[gate] ??= _CopyGate(
      gate,
      WorkerSandbox.create(
        id: workers,
        root: switched.root,
        targets: targets,
        temps: tempSpace,
        flutter: switched.invocation.runner == TestRunner.flutter,
      ),
    );
  }

  /// The test command against unmodified code — read from the journal when
  /// it holds a passing one, and recorded there when it passes now.
  Future<_Baseline> _baseline() async {
    if (_journal?.baseline case final Duration recorded) {
      return _Baseline(0, recorded, reused: true);
    }
    final Stopwatch clock = Stopwatch()..start();
    final int? exitCode = await testCommand.run(timeout: baselineTimeout);
    final Duration wallTime = clock.elapsed;
    if (exitCode == 0) {
      _journal?.recordBaseline(wallTime);
    }
    return _Baseline(exitCode, wallTime, reused: false);
  }

  /// The journal at [journalPath], opened for this run — `null` without one.
  RunJournal? _openJournal(List<String> targets) {
    final String? path = journalPath;
    if (path == null) {
      return null;
    }
    final CompileSafetyGate gate = compileSafetyGate;
    final RunJournal journal = RunJournal.open(path, <String, Object?>{
      'format': RunJournal.format,
      'testCommand': testCommand.toString(),
      'operators': operators.map((MutationOperator o) => o.name).toList(),
      'gate': gate is AnalyzerProcessGate
          ? gate.analyzeCommand.toString()
          : gate.runtimeType.toString(),
      'selectByCoverage': selectByCoverage,
      'fingerprint': RunJournal.fingerprint(
        testCommand.workingDirectory ?? Directory.current.path,
        targets,
      ),
    });
    if (journal.discarded case final String reason) {
      onJournalDiscarded?.call(reason);
    }
    return journal;
  }

  /// The gate that can judge [filePath], asked while the file is still
  /// unmodified — or `null` when neither gate accepts it. See [run].
  Future<CompileSafetyGate?> _gateFor(String filePath) async {
    if (await compileSafetyGate.compiles(filePath)) {
      return compileSafetyGate;
    }
    final CompileSafetyGate? fallback = fallbackCompileSafetyGate;
    if (fallback == null || !await fallback.compiles(filePath)) {
      return null;
    }
    onGateFallback?.call(filePath);
    return fallback;
  }

  /// The coverage pass, run once after the baseline when [selectByCoverage]
  /// asks for it and the journal holds no map from an earlier start. `null`
  /// when it does not ask, and when the pass fails — that with the reason in
  /// [_selectionUnavailable].
  Future<TestSelection?> _selection(TestInvocation invocation) async {
    _selectionUnavailable = null;
    _coverageReused = false;
    if (!selectByCoverage) {
      return null;
    }
    final Stopwatch clock = Stopwatch()..start();
    try {
      if (_journal?.coverage case final CoverageMap recorded) {
        _coverageReused = true;
        return TestSelection(invocation, recorded);
      }
      final TestSelection? selection = await collectCoverage(
        invocation,
        timeout: baselineTimeout,
        onFailure: (String reason) => _selectionUnavailable = reason,
        temps: tempSpace,
        recorded: _journal?.suites,
        onSuite: _journal?.recordSuite,
      );
      if (selection != null) {
        _journal?.recordCoverage(selection.map);
      }
      return selection;
    } finally {
      _stats.coveragePass = clock.elapsed;
    }
  }

  /// A budget derived from a test file's unmutated run — see
  /// [baselineFactor] — but never less than that run plus [mutantTimeout]
  /// plus `package:test`'s own 30s per-test timeout.
  ///
  /// One test file runs in a few seconds, so its derived budget is usually
  /// the [mutantTimeout] floor, 30s by default — the same 30s after which
  /// `package:test` fails a test that awaits forever. Measured on a large
  /// app: killed at that moment, two mutants `flutter test` scored
  /// `detected`, through that very timeout, read as `timeout`.
  Duration _budgetFrom(Duration unmutated) {
    final Duration derived = unmutated * baselineFactor;
    final Duration floor =
        unmutated + mutantTimeout + const Duration(seconds: 30);
    return derived > floor ? derived : floor;
  }

  /// What this run was given and where it runs, for [RunStats.environment].
  /// The test command is recorded as given; the target paths are in the
  /// report already.
  Map<String, Object?> _environment() => <String, Object?>{
    'dartMutantsVersion': packageVersion,
    'dartVersion': Platform.version,
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'processors': Platform.numberOfProcessors,
    'testCommand': <String>[
      testCommand.executable,
      ...testCommand.arguments,
    ].join(' '),
    'mutantTimeoutSeconds': MutantTiming.seconds(mutantTimeout),
    'baselineFactor': baselineFactor,
    'baselineTimeoutSeconds': MutantTiming.seconds(baselineTimeout),
    'selectByCoverage': selectByCoverage,
    'workers': workers,
    'operators': operators.map((MutationOperator o) => o.name).toList(),
  };

  Future<RunStats> _finished(RunStats stats) async {
    stats
      ..finishedAt = DateTime.now()
      ..loadAtEnd = await HostLoad.read();
    return stats;
  }

  /// Every mutant of [plan], in order, with the test files it runs against.
  List<_Job> _jobsFor(
    List<_PlannedFile> plan,
    Map<String, SourceCompileSafetyGate> gates,
    TestSelection? selection,
    _Switched switched,
  ) {
    final List<String> all = switched.invocation.testFiles();
    return <_Job>[
      for (final _PlannedFile file in plan)
        ..._jobsForFile(file, gates[file.path], selection, all),
    ];
  }

  List<_Job> _jobsForFile(
    _PlannedFile file,
    SourceCompileSafetyGate? gate,
    TestSelection? selection,
    List<String> all,
  ) {
    // No parse, and so no scope, where the selection cannot speak for this
    // file — every mutant in it then runs every test file.
    final ParseStringResult? parsed =
        selection == null || !selection.speaksFor(file.source)
        ? null
        : parseString(content: file.source, throwIfDiagnostics: false);
    return <_Job>[
      for (final Mutant mutant in file.mutants)
        if (_testsFor(mutant, selection, parsed) case final List<String> picked)
          _Job(mutant, file.source, gate!, picked, selected: true)
        else
          _Job(mutant, file.source, gate!, all, selected: false),
    ];
  }

  /// The test files [selection] picks for [mutant] — empty when no test
  /// reaches it — or `null` where it cannot say.
  static List<String>? _testsFor(
    Mutant mutant,
    TestSelection? selection,
    ParseStringResult? parsed,
  ) {
    if (selection == null || parsed == null) {
      return null;
    }
    final LineRange? scope = executableScope(
      parsed.unit,
      parsed.lineInfo,
      mutant.offset,
    );
    return selection.testsFor(mutant, scope);
  }

  /// Each job's result from the journal, or `null` where it has to run.
  List<MutantResult?> _recall(List<_Job> jobs) => <MutantResult?>[
    for (final _Job job in jobs) _journal?.recall(job.mutant),
  ];

  static List<_Job> _pending(List<_Job> jobs, List<MutantResult?> recalled) =>
      <_Job>[
        for (int i = 0; i < jobs.length; i++)
          if (recalled[i] == null) jobs[i],
      ];

  /// [recalled] with each gap filled by its job's result.
  static List<MutantResult> _merge(
    List<MutantResult?> recalled,
    List<_Job> jobs,
  ) => <MutantResult>[
    for (int i = 0; i < jobs.length; i++) recalled[i] ?? jobs[i].result!,
  ];

  /// Finishes the [pending] jobs that need no test run, `invalid` where the
  /// gate rejects the mutant and uncovered where no test reaches it, and
  /// returns the rest by the id a [SwitchedJob] carries. It stops early when
  /// the run is over budget.
  Future<Map<int, _Job>> _sortPending(List<_Job> pending) async {
    final Map<int, _Job> runnable = <int, _Job>{};
    for (final _Job job in pending) {
      if (_overBudget != null) {
        break;
      }
      final Stopwatch clock = Stopwatch()..start();
      final bool compiles = await job.gate.compilesSource(
        job.mutant.filePath,
        job.mutant.applyTo(job.source),
      );
      job.timing.gate = clock.elapsed;
      if (!compiles) {
        _finish(
          job,
          MutantResult(mutant: job.mutant, verdict: MutantVerdict.invalid),
        );
      } else if (job.tests.isEmpty) {
        _finish(
          job,
          MutantResult(
            mutant: job.mutant,
            verdict: MutantVerdict.undetected,
            uncovered: true,
          ),
        );
      } else {
        runnable[runnable.length] = job;
      }
    }
    return runnable;
  }

  /// The gate of the file [file], which every runnable job's file has.
  static SourceCompileSafetyGate _gateOf(
    Map<String, SourceCompileSafetyGate> gates,
    String file,
  ) {
    final SourceCompileSafetyGate? gate = gates[file];
    if (gate == null) {
      throw StateError('no gate was made for $file');
    }
    return gate;
  }

  /// Gives each of [pending] its result: `invalid` where the gate rejects
  /// it, undetected and uncovered where no test reaches it, and the rest
  /// from a [SwitchedRunner]. Why the switched run stopped, or `null`.
  Future<String?> _runPending(
    List<_Job> pending,
    _Switched switched,
    List<MutantResult?> recalled,
    List<_Job> jobs,
  ) async {
    _overBudget = null;
    _mutantClock
      ..reset()
      ..start();
    _stats.workers = workers;
    final Map<int, _Job> runnable = await _sortPending(pending);
    if (runnable.isEmpty || _overBudget != null) {
      return null;
    }
    final SwitchedStats stats = _stats.switched = SwitchedStats();
    final Map<String, SourceCompileSafetyGate> gates =
        <String, SourceCompileSafetyGate>{
          for (final _Job job in runnable.values) job.mutant.filePath: job.gate,
        };
    return SwitchedRunner(
      toolchain: switched.toolchain,
      root: switched.root,
      gateFor: (String file) => _gateOf(gates, file),
      temps: tempSpace,
      workers: workers,
      arguments: switched.arguments,
      testFileTimeout: baselineTimeout,
      budgetFrom: _budgetFrom,
      stats: stats,
      shouldStop: () => _overBudget != null,
      onResult:
          (SwitchedJob job, MutantResult result, int lane, Duration tests) {
            final _Job owner = runnable[job.id]!;
            owner.timing
              ..worker = lane
              ..test = tests;
            _finish(owner, result);
          },
    ).run(<SwitchedJob>[
      for (final MapEntry<int, _Job> e in runnable.entries)
        SwitchedJob(e.key, e.value.mutant, e.value.source, e.value.tests),
    ]);
  }

  /// Records [result] as [job]'s, in the journal and the statistics,
  /// reports it as progress, and checks the pace against [runBudget].
  void _finish(_Job job, MutantResult result) {
    job.result = result;
    _journal?.record(result);
    _stats.mutants.add(job.timing.build(result));
    _completed++;
    final Duration remaining = _projectedRemaining();
    onProgress?.call(
      MutantProgress(
        completed: _completed,
        total: _planned,
        result: result,
        elapsed: job.timing.gate + (job.timing.test ?? Duration.zero),
        projectedRemaining: remaining,
      ),
    );
    _checkPace(remaining);
  }

  /// What the mutants still to come cost at the pace held so far — see
  /// [MutantProgress.projectedRemaining].
  Duration _projectedRemaining() => RunBudget.projectedRemaining(
    elapsed: _mutantClock.elapsed,
    completed: _completed,
    planned: _planned,
  );

  /// Stops the run when [runBudget] cannot hold what is left of it — see
  /// [RunBudget.exceeded] for when a pace is trusted at all.
  void _checkPace(Duration remaining) {
    if (runBudget case final RunBudget b when _overBudget == null) {
      final Duration elapsed = _mutantClock.elapsed;
      if (!b.exceeded(
        elapsed: elapsed,
        completed: _completed,
        planned: _planned,
        workers: workers,
      )) {
        return;
      }
      _overBudget =
          'at the pace of its first $_completed mutants this run needs about '
          '${formatWait(elapsed + remaining)}, against a --max-minutes of '
          '${formatWait(b.limit)}. It stopped after $_completed of '
          '$_planned mutants and scored none of them: a score over part of a '
          'file is not that file\'s score. Narrow the files, add workers, '
          'select by coverage, or raise the limit.';
    }
  }

  /// One report per file of [plan], from [results] in the same order the
  /// plan lists its mutants.
  List<FileMutationReport> _fileReports(
    List<_PlannedFile> plan,
    List<MutantResult> results,
  ) {
    int start = 0;
    return <FileMutationReport>[
      for (final _PlannedFile file in plan)
        _fileReport(
          file.path,
          results.sublist(start, start += file.mutants.length),
        ),
    ];
  }

  static FileMutationReport _fileReport(
    String filePath,
    List<MutantResult> results,
  ) {
    int detected = 0;
    int undetected = 0;
    int invalid = 0;
    int timedOut = 0;
    final List<MutantResult> undetectedResults = <MutantResult>[];
    final List<MutantResult> invalidResults = <MutantResult>[];
    final List<MutantResult> timedOutResults = <MutantResult>[];

    for (final MutantResult result in results) {
      switch (result.verdict) {
        case MutantVerdict.invalid:
          invalid++;
          // Kept, not just counted — same reasoning as timedOutResults
          // below: a bare count cannot tell a caller which lines the
          // compile-safety gate rejected, or whether 27 of them share one
          // cause.
          invalidResults.add(result);
        case MutantVerdict.timeout:
          timedOut++;
          // Kept, not just counted. A timed-out mutant is real code that went
          // unmeasured, and a caller who only gets the number cannot tell
          // WHICH line, whether it is the same one across runs, or go and look
          // at it. Measured: a mutant that timed out on every round of a file
          // was therefore never scored at all — permanently invisible behind a
          // count nobody reads per-mutant.
          timedOutResults.add(result);
        case MutantVerdict.detected:
          detected++;
        case MutantVerdict.undetected:
          undetected++;
          undetectedResults.add(result);
      }
    }

    return FileMutationReport(
      filePath: filePath,
      detected: detected,
      undetected: undetected,
      invalid: invalid,
      timedOut: timedOut,
      undetectedMutants: undetectedResults,
      invalidMutants: invalidResults,
      timedOutMutants: timedOutResults,
    );
  }

  List<Mutant> _collectMutants(String filePath, String source) {
    final ParseStringResult parsed = parseString(
      content: source,
      throwIfDiagnostics: false,
    );
    final List<Mutant> mutants = <Mutant>[];
    for (final MutationOperator operator in operators) {
      final MutationVisitor visitor = operator.createVisitor(
        filePath,
        parsed.lineInfo,
        source,
      );
      parsed.unit.accept(visitor);
      mutants.addAll(visitor.mutants);
    }
    return narrowMutants(
      mutants,
      lines: lines?[_pathKey(filePath)],
      perLine: perLine,
    );
  }
}

/// The test command's options, split by what a switched run does with
/// them: [forwarded] to every compiled test file, which applies them as the
/// test runner would; ignored, because they only shape how the runner
/// reports or how many files it runs at once; or a [refusal].
class _Arguments {
  _Arguments(this.forwarded, this.refusal);

  factory _Arguments.of(TestInvocation invocation) {
    final List<String> forwarded = <String>[];
    final String? refusal =
        _collect(invocation.flags, forwarded) ?? _unparsable(forwarded);
    return refusal == null
        ? _Arguments(forwarded, null)
        : _Arguments(const <String>[], refusal);
  }

  /// Sorts [flags] into [forwarded] and the ignored; the reason one of them
  /// cannot be applied, or `null`.
  static String? _collect(List<String> flags, List<String> forwarded) {
    for (int i = 0; i < flags.length; i++) {
      final String flag = flags[i];
      final String name = flag.split('=').first;
      if (_ignoredFlags.contains(name)) {
        continue;
      }
      if (_takesValue(name)) {
        final String? value = _valueOf(flags, i, name);
        if (value == null) {
          return '$flag has no value';
        }
        if (!flag.contains('=')) {
          i++;
        }
        if (_forwardedValueOptions.contains(name)) {
          forwarded.addAll(<String>[name, value]);
        }
        continue;
      }
      if (_forwardedFlags.contains(name)) {
        forwarded.add(flag);
        continue;
      }
      return 'the test command passes $flag, which a switched run cannot '
          'apply';
    }
    return null;
  }

  static bool _takesValue(String name) =>
      _ignoredValueOptions.contains(name) ||
      _forwardedValueOptions.contains(name);

  /// The value of the option at [flags]`[i]`: after its `=`, or the next
  /// flag; `null` with neither.
  static String? _valueOf(List<String> flags, int i, String name) {
    final String flag = flags[i];
    if (flag.contains('=')) {
      return flag.substring(name.length + 1);
    }
    return i + 1 < flags.length ? flags[i + 1] : null;
  }

  /// Why the test runner would refuse [forwarded], or `null`.
  static String? _unparsable(List<String> forwarded) {
    try {
      Configuration.parse(forwarded);
    } on FormatException catch (e) {
      return 'the test command\'s options: ${e.message}';
    }
    return null;
  }

  final List<String> forwarded;
  final String? refusal;

  /// Handed to every test file: they decide which tests run, and how.
  static const Set<String> _forwardedValueOptions = <String>{
    '-n',
    '--name',
    '-N',
    '--plain-name',
    '-t',
    '--tags',
    '-x',
    '--exclude-tags',
    '--timeout',
    '-P',
    '--preset',
  };

  static const Set<String> _forwardedFlags = <String>{'--run-skipped'};

  /// How the runner reports, or how many files it runs at once.
  static const Set<String> _ignoredValueOptions = <String>{
    '-j',
    '--concurrency',
    '-r',
    '--reporter',
    '--file-reporter',
  };

  /// `--fail-fast` among them: it only ends a failing run sooner, and a
  /// failure decides the mutant either way.
  static const Set<String> _ignoredFlags = <String>{
    '--no-pub',
    '--color',
    '--no-color',
    '--fail-fast',
    '--chain-stack-traces',
    '--no-chain-stack-traces',
  };
}

/// What [MutationTestRunner] runs mutants with.
class _Switched {
  _Switched(this.invocation, this.root, this.toolchain, this.arguments);

  final TestInvocation invocation;

  /// The package's directory.
  final String root;

  final SwitchedToolchain toolchain;

  /// The test command's options every compiled test file applies.
  final List<String> arguments;

  /// A gate that only reads files from disk, wrapped once each.
  final Map<CompileSafetyGate, SourceCompileSafetyGate> copyGates =
      <CompileSafetyGate, SourceCompileSafetyGate>{};
}

/// A gate that only reads files from disk, asked about content in memory by
/// writing it into a copy of the package — so the package itself is never
/// written to. One question at a time.
class _CopyGate implements SourceCompileSafetyGate {
  _CopyGate(this._gate, this._copy);

  final CompileSafetyGate _gate;
  final WorkerSandbox _copy;
  Future<void> _previous = Future<void>.value();

  @override
  Future<bool> compiles(String filePath) => _gate.compiles(filePath);

  @override
  Future<bool> compilesSource(String filePath, String source) {
    final Future<bool> answer = _previous.then((_) async {
      final String path = _copy.pathFor(filePath);
      _copy.write(path, source);
      try {
        return await _gate.compiles(path);
      } finally {
        _copy.write(path, File(filePath).readAsStringSync());
      }
    });
    _previous = answer.then<void>((_) {}, onError: (Object _) {});
    return answer;
  }

  @override
  Future<void> close() async {}
}

/// The test command's run against unmodified code, or the one a journal
/// recorded — see [MutationTestRunner.journalPath].
class _Baseline {
  const _Baseline(this.exitCode, this.wallTime, {required this.reused});

  /// `null` when it did not finish within the baseline timeout.
  final int? exitCode;
  final Duration wallTime;
  final bool reused;
}

/// A target file as [MutationTestRunner.run] read and enumerated it, once.
class _PlannedFile {
  const _PlannedFile(this.path, this.source, this.mutants);

  final String path;
  final String source;
  final List<Mutant> mutants;
}

/// The target files read and put to their gates, or the abort that ended the
/// run because a gate rejected a file.
class _Enumerated {
  const _Enumerated(this.files, this.gates) : abort = null;

  const _Enumerated.rejected(MutationRunReport this.abort)
    : files = const <_PlannedFile>[],
      gates = const <String, SourceCompileSafetyGate>{};

  final List<_PlannedFile> files;
  final Map<String, SourceCompileSafetyGate> gates;
  final MutationRunReport? abort;
}

/// A [MutantTiming] while its mutant is still running.
class _Timing {
  _Timing({required this.selected});

  final bool selected;
  int worker = 0;
  Duration gate = Duration.zero;
  Duration? test;

  MutantTiming build(MutantResult result) => MutantTiming(
    result: result,
    worker: worker,
    elapsed: gate + (test ?? Duration.zero),
    gate: gate,
    selected: selected,
    test: test,
  );
}

/// One mutant with what it needs to run, and its result once it has one.
class _Job {
  _Job(
    this.mutant,
    this.source,
    this.gate,
    this.tests, {
    required bool selected,
  }) : timing = _Timing(selected: selected);

  final Mutant mutant;

  /// Its file's unmodified content.
  final String source;

  final SourceCompileSafetyGate gate;

  /// The test files it runs against, relative to the package — empty when
  /// no test reaches it.
  final List<String> tests;

  final _Timing timing;
  MutantResult? result;
}
