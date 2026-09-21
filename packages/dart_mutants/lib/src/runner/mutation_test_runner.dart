import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;

import '../generated_file_filter.dart';
import '../mutant.dart';
import '../mutation_operator.dart';
import '../mutation_visitor.dart';
import '../operators.dart';
import '../version.dart';
import 'compile_safety_gate.dart';
import 'file_mutation_report.dart';
import 'host_load.dart';
import 'mutant_progress.dart';
import 'mutant_result.dart';
import 'mutant_scope.dart';
import 'mutant_timing.dart';
import 'mutant_verdict.dart';
import 'mutated_file_registry.dart';
import 'mutation_run_report.dart';
import 'process_command.dart';
import 'run_budget.dart';
import 'run_plan.dart';
import 'run_stats.dart';
import 'temp_space.dart';
import 'test_compilation_cache.dart';
import 'test_invocation.dart';
import 'test_selection.dart';
import 'wait_span.dart';
import 'worker_sandbox.dart';

/// Runs every operator's mutants against [testCommand], one at a time, and
/// scores the result.
///
/// The contract this whole package exists to serve: hand it a file list and
/// a test command, get back per-file totals and the actual survivors. Which
/// files to pass, whether the score is good enough, and what to do about a
/// surviving mutant are all outside this class on purpose — that is policy,
/// decided by whoever calls this, not by the engine running the mutants.
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
    this.onSelectionFallback,
    this.onPlan,
    this.onProgress,
    TempSpace? tempSpace,
    this.workers = 1,
    this.onWorkersFallback,
    this.runBudget,
  }) : tempSpace = tempSpace ?? TempSpace(),
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
  ///
  /// Selecting fewer tests can lose a detection, never invent one: a test
  /// that fails when selected runs, and fails, in the full command too. A
  /// selected exit that is neither a pass nor a failed test — 79 when the
  /// chosen files ran no test at all, or a tool error — is re-asked of the
  /// full command. So a selected score can only err low, and the known ways
  /// it does are: a mutant that changes a declaration's inferred type can
  /// break the compilation of a test file that never enters its function (in
  /// full, that reads as `detected`); code reached only from a subprocess or
  /// `Isolate.spawnUri`, whose coverage the test runner does not collect; and
  /// code whose execution depends on timing or randomness, which one coverage
  /// pass can miss.
  ///
  /// A selected command also gets its own budget. The first mutant that
  /// needs one runs that command once against unmodified code, and the
  /// budget is derived from that time the same way the full command's is
  /// from the baseline — never more than the full command's budget. Without
  /// it, a mutant that hangs a two-second selection waits out a budget sized
  /// for the whole suite. When the selection does not pass unmodified (79,
  /// no test ran), it keeps the full command's budget.
  ///
  /// Needs a `dart test …` or `flutter test …` [testCommand] whose test
  /// files this package can list the same way the runner does. Anything
  /// else — see `collectCoverage` for every refusal — or a coverage pass that
  /// fails, runs every mutant against the full command and says so through
  /// [onSelectionFallback].
  final bool selectByCoverage;

  /// Called with the reason coverage selection was asked for and not used.
  final void Function(String reason)? onSelectionFallback;

  /// Called once, before the first mutant runs, with what the run holds.
  final void Function(RunPlan plan)? onPlan;

  /// Called after every mutant, in the order they run.
  final void Function(MutantProgress progress)? onProgress;

  final List<MutationOperator> operators;

  /// Where the run's temporary directories go. [run] deletes every one it
  /// made before it returns, and on `SIGINT`/`SIGTERM`; it also deletes the
  /// ones a run that was killed outright left behind — see [TempSpace].
  final TempSpace tempSpace;

  /// How many mutants run at once.
  ///
  /// With 1, the default, each mutant is written into the package itself
  /// and put back afterwards. With more, each worker gets a [WorkerSandbox]
  /// — a copy of the package made of links, where only the target files are
  /// real — and the package itself is never written to. The baseline and the
  /// coverage pass still run once, in the package, before any worker starts.
  ///
  /// What bounds this is memory more than processors: every worker runs its
  /// own test command, and a `flutter test` process can take a gigabyte or
  /// two.
  final int workers;

  /// Called with the reason [workers] was more than 1 and the run went on
  /// with one, in place.
  final void Function(String reason)? onWorkersFallback;

  /// How long the mutants may take, after which the run stops without
  /// scoring anything. `null`, the default, lets a run take as long as it
  /// takes.
  ///
  /// Two checks, because only one of them can be made before the cost is
  /// paid. [RunPlan.floor] — every worker busy, nothing rejected, no
  /// selection — is a bound nothing can beat, so a plan already over the
  /// limit is refused before a single file is written. Past that the only
  /// honest reading is the pace the run is holding, which [RunBudget]
  /// decides when to trust; a run that will not fit stops between mutants.
  ///
  /// It buys what a dry run would and costs less: the count and the pace
  /// both need the baseline, which is the run's own first step, so
  /// measuring them separately would mean running the suite twice over.
  final RunBudget? runBudget;

  /// The least time a mutant's test run gets before it is killed and scored
  /// as [MutantVerdict.timeout] instead of waited on forever. A slow suite
  /// gets more — see [baselineFactor].
  final Duration mutantTimeout;

  /// Each mutant's budget is the larger of [mutantTimeout] and this many
  /// times the baseline's own wall time in this run. `0` turns it off.
  ///
  /// The baseline is one sample, taken once. Under `dart test` the kernel
  /// cache is cleared before the baseline and before every mutant (see
  /// [TestCompilationCache]), so every run compiles from scratch and the
  /// multiple is not there to cover a cold-versus-warm compile. It is there
  /// for load: the same unmodified suite on a workstation running several
  /// sessions at once was measured at 9s at its quietest and 29s at its
  /// busiest.
  ///
  /// Too small a budget does not fail safe. A mutant that would have
  /// survived and instead timed out leaves the score and the undetected list
  /// both, which is the survivor a caller most needed to see.
  final double baselineFactor;

  /// How long the baseline gets. Separate from [mutantTimeout] because the
  /// baseline has one job, telling a suite that finishes from one that
  /// hangs, and the mutant budget is derived from it: a suite whose green
  /// run took longer than one mutant's floor used to abort the whole run as
  /// if it had hung. An already-hanging test command is exactly as unusable
  /// a baseline as an already-failing one. Defaults to ten times
  /// [mutantTimeout].
  final Duration baselineTimeout;

  final MutatedFileRegistry _registry = MutatedFileRegistry();

  /// A selected command's budget, keyed by [_keyOf] — see
  /// [selectByCoverage]. A future, so lanes asking at once share one
  /// measurement.
  final Map<String, Future<Duration>> _selectedBudgets =
      <String, Future<Duration>>{};

  int _completed = 0;
  int _planned = 0;

  /// Wall time over the mutants alone — started when the first one does, so
  /// the baseline, the coverage pass and the sandbox check stay out of the
  /// pace they are used to project. See [runBudget].
  final Stopwatch _mutantClock = Stopwatch();

  /// Why the run stopped between mutants, once [runBudget] says the pace
  /// will not fit it. Non-null means no lane takes another job.
  String? _overBudget;

  /// The current run's — see [run].
  late RunStats _stats;

  /// See [TestCompilationCache]'s own doc for why this exists at all — in
  /// short, `dart test`'s incremental kernel cache does not reliably notice
  /// the fast, repeated, small rewrites this class makes to one file.
  late final TestCompilationCache _testCache = TestCompilationCache(
    testCommand.workingDirectory,
  );

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

    // Armed before the baseline runs, not after. The baseline is a full test
    // command like any other, so a Ctrl-C during it orphans a subprocess tree
    // exactly the same way — and it is the longest single run of the session,
    // being the cold one. There is nothing to restore yet at this point; the
    // restore half is simply a no-op until the first mutant is written.
    //
    // Processes before directories: a test run killed mid-write would
    // otherwise be writing into a directory being deleted.
    _registry.armSignalRestore(
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
      _testCache.clear();
      final Stopwatch baselineClock = Stopwatch()..start();
      final int? baselineExitCode = await testCommand.run(
        timeout: baselineTimeout,
      );
      final Duration baseline = baselineClock.elapsed;
      if (baselineExitCode == null) {
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
      stats.baseline = baseline;
      if (baselineExitCode != 0) {
        return MutationRunReport.aborted(
          stats: await _finished(stats),
          AbortKind.baselineFailed,
          'the test command failed against unmodified code (exit '
          '$baselineExitCode) — refusing to score mutants against a baseline '
          'that was already red',
          baselineDuration: baseline,
        );
      }
      final Duration budget = _budgetFrom(baseline);

      // Every target is read and enumerated once, here, and the same lists
      // are what runs — the plan's count is the count that runs.
      final List<_PlannedFile> plan = <_PlannedFile>[];
      final Map<String, CompileSafetyGate> gates =
          <String, CompileSafetyGate>{};
      final Stopwatch gateClock = Stopwatch()..start();
      for (final String filePath in targets) {
        final String source = await File(filePath).readAsString();
        final List<Mutant> mutants = _collectMutants(filePath, source);
        plan.add(_PlannedFile(filePath, source, mutants));
        if (mutants.isEmpty) {
          gates[filePath] = compileSafetyGate;
          continue;
        }
        final CompileSafetyGate? gate = await _gateFor(filePath);
        if (gate == null) {
          stats.gateCheck = gateClock.elapsed;
          return MutationRunReport.aborted(
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
            mutantTimeout: budget,
          );
        }
        gates[filePath] = gate;
      }
      stats.gateCheck = gateClock.elapsed;

      final TestSelection? selection = await _selection();

      _completed = 0;
      _planned = plan.fold(
        0,
        (int sum, _PlannedFile file) => sum + file.mutants.length,
      );
      // The lanes first, so the plan says how many workers the run actually
      // got rather than how many were asked for — a run that fell back to
      // one is a run that will take as long as one, and the plan is where
      // anyone waiting reads that.
      final List<_Lane> lanes = await _lanes(plan);
      final RunPlan runPlan = RunPlan(
        fileCount: targets.length,
        mutantCount: _planned,
        baseline: baseline,
        budget: budget,
        workers: lanes.length,
      );
      onPlan?.call(runPlan);
      return await _scoreOrRefuse(
        plan: plan,
        gates: gates,
        selection: selection,
        lanes: lanes,
        runPlan: runPlan,
        stats: stats,
      );
    } finally {
      // A safety net, not the primary mechanism — _runOne already restores
      // after every individual mutant. This only fires if something escaped
      // before that: at most one file's worth of cleanup, never a whole
      // run's worth.
      _registry.restoreAll();
      tempSpace.deleteAll();
      await _registry.disarm();
    }
  }

  /// Runs [runPlan]'s mutants and scores them — or, where [runBudget] says
  /// the run will not fit, returns the refusal instead.
  ///
  /// Both refusals score nothing at all, and that is deliberate: part of a
  /// file's mutants is not that file's score, and a number that looks like
  /// one would be read as one.
  Future<MutationRunReport> _scoreOrRefuse({
    required List<_PlannedFile> plan,
    required Map<String, CompileSafetyGate> gates,
    required TestSelection? selection,
    required List<_Lane> lanes,
    required RunPlan runPlan,
    required RunStats stats,
  }) async {
    if (runBudget case final RunBudget b when runPlan.floor > b.limit) {
      return MutationRunReport.aborted(
        stats: await _finished(stats),
        AbortKind.overBudget,
        'this run needs at least ${formatWait(runPlan.floor)} — '
        '${runPlan.mutantCount} mutants at a ${runPlan.baseline.inSeconds}s '
        'baseline across ${lanes.length} worker(s), and nothing makes it '
        'faster than that — against a --max-minutes of '
        '${formatWait(b.limit)}. '
        'Nothing was mutated. Narrow the files, add workers, select by '
        'coverage, or raise the limit.',
        baselineDuration: runPlan.baseline,
        mutantTimeout: runPlan.budget,
      );
    }
    final List<MutantResult> results = await _execute(
      _jobsFor(plan, gates, selection),
      lanes,
      runPlan.budget,
    );
    if (_overBudget case final String reason) {
      return MutationRunReport.aborted(
        stats: await _finished(stats),
        AbortKind.overBudget,
        reason,
        baselineDuration: runPlan.baseline,
        mutantTimeout: runPlan.budget,
      );
    }
    return MutationRunReport.completed(
      _fileReports(plan, results),
      baselineDuration: runPlan.baseline,
      mutantTimeout: runPlan.budget,
      selectedByCoverage: selection != null,
      stats: await _finished(stats),
    );
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
  /// asks for it. `null` when it does not, and — with the reason reported —
  /// when the test command cannot be taken apart or the pass fails; every
  /// mutant then runs the full command.
  Future<TestSelection?> _selection() async {
    if (!selectByCoverage) {
      return null;
    }
    final Stopwatch clock = Stopwatch()..start();
    try {
      return await _collectSelection();
    } finally {
      _stats.coveragePass = clock.elapsed;
    }
  }

  Future<TestSelection?> _collectSelection() async {
    final TestInvocation? invocation = TestInvocation.parse(testCommand);
    if (invocation == null) {
      onSelectionFallback?.call(
        'the test command is not `dart test …` or `flutter test …`',
      );
      return null;
    }
    _testCache.clear();
    return collectCoverage(
      invocation,
      timeout: baselineTimeout,
      onFailure: (String reason) => onSelectionFallback?.call(reason),
      temps: tempSpace,
    );
  }

  /// A budget derived from a run's wall time against unmodified code — see
  /// [baselineFactor].
  Duration _budgetFrom(Duration baseline) {
    final Duration derived = baseline * baselineFactor;
    return derived > mutantTimeout ? derived : mutantTimeout;
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

  /// Where the mutants run: the package itself with one worker, or one
  /// [WorkerSandbox] per worker. A run that cannot use sandboxes says why
  /// through [onWorkersFallback] and runs with one worker in place.
  Future<List<_Lane>> _lanes(List<_PlannedFile> plan) async {
    final _Lane inPlace = _Lane(testCommand, null, flutter: false);
    if (workers <= 1) {
      return <_Lane>[inPlace];
    }
    final List<_Lane>? lanes = await _sandboxLanes(plan);
    if (lanes != null) {
      return lanes;
    }
    onWorkersFallback?.call(_noSandboxes ?? 'no sandbox could be made');
    return <_Lane>[inPlace];
  }

  /// Why the last [_sandboxLanes] returned `null`.
  String? _noSandboxes;

  /// One lane per worker, each in a new sandbox of the package — or `null`,
  /// with the reason in [_noSandboxes], when the package cannot be
  /// sandboxed or the first sandbox fails its check. Sandboxes that go
  /// unused stay until the run ends, with every other temporary directory.
  Future<List<_Lane>?> _sandboxLanes(List<_PlannedFile> plan) async {
    final String root = p.normalize(
      p.absolute(testCommand.workingDirectory ?? Directory.current.path),
    );
    final List<String> targets = <String>[
      for (final _PlannedFile file in plan)
        if (file.mutants.isNotEmpty) file.path,
    ];
    _noSandboxes = _sandboxRefusal(root, targets);
    if (_noSandboxes != null) {
      return null;
    }
    final bool flutter =
        TestInvocation.parse(testCommand)?.runner == TestRunner.flutter;
    final Stopwatch clock = Stopwatch()..start();
    final List<_Lane> lanes = <_Lane>[
      for (int id = 0; id < workers; id++)
        _Lane(
          testCommand,
          WorkerSandbox.create(
            id: id,
            root: root,
            targets: targets,
            temps: tempSpace,
            flutter: flutter,
          ),
          flutter: flutter,
        ),
    ];
    _noSandboxes = await _sandboxBaseline(lanes.first);
    _stats.sandboxSetup = clock.elapsed;
    return _noSandboxes == null ? lanes : null;
  }

  /// Why [lane]'s sandbox cannot be trusted, or `null` when the full test
  /// command passes in it against unmodified code.
  ///
  /// The baseline vouches for the package, not for a copy of it. A copy the
  /// tools cannot work in fails every test command run there, and a failed
  /// command reads as `detected`: without this, a broken sandbox would score
  /// every mutant it ran as caught. One sandbox is asked, since all are made
  /// the same way.
  Future<String?> _sandboxBaseline(_Lane lane) async {
    lane.cache.clear();
    final int? exitCode = await lane
        .commandFor(testCommand)
        .run(timeout: baselineTimeout);
    return switch (exitCode) {
      0 => null,
      null =>
        'the test command did not finish in a worker\'s copy of the package '
            'within ${baselineTimeout.inSeconds}s',
      _ =>
        'the test command failed in a worker\'s copy of the package '
            '(exit $exitCode), though it passed in the package itself',
    };
  }

  static String? _sandboxRefusal(String root, List<String> targets) {
    if (!File(p.join(root, 'pubspec.yaml')).existsSync()) {
      return 'the test command does not run in a package directory ($root)';
    }
    for (final String target in targets) {
      if (!p.isWithin(root, p.absolute(target))) {
        return '$target is outside the package the test command runs in';
      }
    }
    return null;
  }

  /// Every mutant of [plan], in order, with what it needs to run.
  List<_Job> _jobsFor(
    List<_PlannedFile> plan,
    Map<String, CompileSafetyGate> gates,
    TestSelection? selection,
  ) => <_Job>[
    for (final _PlannedFile file in plan)
      ..._jobsForFile(file, gates[file.path]!, selection),
  ];

  List<_Job> _jobsForFile(
    _PlannedFile file,
    CompileSafetyGate gate,
    TestSelection? selection,
  ) {
    // No parse, and so no scope, where the selection cannot speak for this
    // file — every mutant in it then runs the full command.
    final ParseStringResult? parsed =
        selection == null || !selection.speaksFor(file.source)
        ? null
        : parseString(content: file.source, throwIfDiagnostics: false);
    return <_Job>[
      for (final Mutant mutant in file.mutants)
        _Job(mutant, file.source, gate, _commandFor(mutant, selection, parsed)),
    ];
  }

  /// Runs [jobs] across [lanes], each lane taking the next job as it
  /// finishes one, and returns the results in [jobs]' order.
  ///
  /// When one lane fails, the others stop taking jobs and every test command
  /// still running is killed before the failure goes on.
  Future<List<MutantResult>> _execute(
    List<_Job> jobs,
    List<_Lane> lanes,
    Duration budget,
  ) async {
    _stats.workers = lanes.length;
    _overBudget = null;
    _mutantClock
      ..reset()
      ..start();
    final List<MutantResult?> results = List<MutantResult?>.filled(
      jobs.length,
      null,
    );
    int next = 0;
    bool stopping = false;
    Future<void> drain(_Lane lane) async {
      while (!stopping && _overBudget == null && next < jobs.length) {
        final int index = next++;
        results[index] = await _runTimed(jobs[index], lane, budget);
      }
    }

    bool finished = false;
    try {
      await Future.wait(lanes.map(drain), eagerError: true);
      finished = true;
    } finally {
      if (!finished) {
        stopping = true;
        ProcessCommand.killAllRunning();
      }
    }
    _stats.workerDiskBytes = <int>[
      for (final _Lane lane in lanes)
        if (lane.sandbox case final WorkerSandbox sandbox) sandbox.diskBytes(),
    ];
    return results.whereType<MutantResult>().toList();
  }

  /// [_runOne], timed, recorded in the run's statistics and reported as
  /// progress.
  Future<MutantResult> _runTimed(_Job job, _Lane lane, Duration budget) async {
    final Stopwatch clock = Stopwatch()..start();
    final _Timing timing = _Timing(lane.id);
    final MutantResult result = await _runOne(job, lane, budget, timing);
    final Duration elapsed = clock.elapsed;
    _stats.mutants.add(timing.build(result, elapsed));
    _completed++;
    final Duration remaining = _projectedRemaining();
    onProgress?.call(
      MutantProgress(
        completed: _completed,
        total: _planned,
        result: result,
        elapsed: elapsed,
        projectedRemaining: remaining,
      ),
    );
    _checkPace(remaining);
    return result;
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
        // What the run got, not what it asked for: a run that fell back to
        // one worker sets its pace like one.
        workers: _stats.workers ?? workers,
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
    return mutants;
  }

  /// What [mutant] runs: [testCommand] without a selection or a parse to
  /// scope it by, otherwise whatever the selection says — `null` for "no
  /// test enters it".
  ProcessCommand? _commandFor(
    Mutant mutant,
    TestSelection? selection,
    ParseStringResult? parsed,
  ) {
    if (selection == null || parsed == null) {
      return testCommand;
    }
    return selection.commandFor(
      mutant,
      executableScope(parsed.unit, parsed.lineInfo, mutant.offset),
      testCommand,
    );
  }

  /// Whether a finished run's exit code is a verdict: 0, the tests passed,
  /// or 1, a test failed. Anything else from a selected run — 79 when it ran
  /// no test at all, or a usage or tool error — is not.
  static bool _isVerdict(int? exitCode) =>
      exitCode == null || exitCode == 0 || exitCode == 1;

  /// Checks [job]'s mutant for compile-safety, runs its command in [lane] if
  /// it passed — for at most [budget], the full command's, or a selected
  /// command's own (see [selectByCoverage]) — and puts the file back before
  /// returning, whichever branch was taken, so a thrown exception here still
  /// leaves the file clean. Where the time went is written to [timing]. A
  /// `null` command means no test reaches the mutant: it is scored
  /// undetected, and marked so, unrun.
  ///
  /// The gate comes first on purpose: a mutant that does not compile is
  /// `invalid` whether or not anything covers it. A gate that can judge
  /// content in memory does so, and such a mutant is never written at all;
  /// any other gate reads the mutant from the lane's copy of the file.
  Future<MutantResult> _runOne(
    _Job job,
    _Lane lane,
    Duration budget,
    _Timing timing,
  ) async {
    final Mutant mutant = job.mutant;
    final String path = lane.pathFor(mutant.filePath);
    final String mutated = mutant.applyTo(job.source);
    final CompileSafetyGate gate = job.gate;
    try {
      final Stopwatch clock = Stopwatch()..start();
      final bool compiles;
      if (gate is SourceCompileSafetyGate) {
        compiles = await gate.compilesSource(mutant.filePath, mutated);
      } else {
        _write(lane, path, mutated, job.source);
        compiles = await gate.compiles(path);
      }
      timing.gate = clock.elapsed;
      if (!compiles) {
        return MutantResult(mutant: mutant, verdict: MutantVerdict.invalid);
      }
      final ProcessCommand? command = job.command;
      if (command == null) {
        return MutantResult(
          mutant: mutant,
          verdict: MutantVerdict.undetected,
          uncovered: true,
        );
      }
      _write(lane, path, mutated, job.source);
      return await _test(job, lane, command, budget, timing);
    } finally {
      _registry.restore(path);
    }
  }

  /// Writes [content] to [path] in [lane], having recorded [original] for
  /// the restore.
  void _write(_Lane lane, String path, String content, String original) {
    _registry.track(path, original);
    lane.write(path, content);
  }

  /// Runs [command] against the mutant already written for [job] in [lane]
  /// and reads the verdict.
  Future<MutantResult> _test(
    _Job job,
    _Lane lane,
    ProcessCommand command,
    Duration budget,
    _Timing timing,
  ) async {
    timing.selected = !identical(command, testCommand);
    Duration ranAgainst = timing.selected
        ? await _selectedBudget(job, lane, command, budget, timing)
        : budget;
    lane.cache.clear();
    final Stopwatch clock = Stopwatch()..start();
    int? exitCode = await lane.commandFor(command).run(timeout: ranAgainst);
    timing.test = clock.elapsed;
    if (timing.selected && !_isVerdict(exitCode)) {
      // Neither a pass nor a failed test: 79 when the selected files ran
      // no test at all — a file that reaches the function while declaring
      // its tests, whose tests a filter skips, or that declares none — and
      // the usage and tool errors besides. None is a failed assertion, and
      // reading one as `detected` would invent a detection the full command
      // does not make. Ask the full command.
      lane.cache.clear();
      ranAgainst = budget;
      clock.reset();
      exitCode = await lane.commandFor(testCommand).run(timeout: budget);
      timing.retry = clock.elapsed;
    }
    if (exitCode == null) {
      // A mutant that hangs the suite is not neutral evidence — it often
      // means the mutation introduced a genuine infinite loop, which is
      // arguably the mutation actually changing behaviour. But counting it
      // as "detected" would let a hang inflate the score in exactly the
      // wrong direction the compile-safety gate exists to prevent for
      // invalid mutants: a number that looks better while representing a
      // test that never actually ran to a real assertion. Kept as its own
      // bucket, excluded from the score like `invalid`, rather than
      // guessed into either side.
      return MutantResult(
        mutant: job.mutant,
        verdict: MutantVerdict.timeout,
        timeout: ranAgainst,
      );
    }
    return MutantResult(
      mutant: job.mutant,
      verdict: exitCode == 0
          ? MutantVerdict.undetected
          : MutantVerdict.detected,
      timeout: ranAgainst,
    );
  }

  /// [command]'s budget — see [selectByCoverage]. Measured the first time a
  /// mutant needs it, so a selection whose mutants are all `invalid` costs
  /// nothing, and once however many lanes need it at the same moment.
  Future<Duration> _selectedBudget(
    _Job job,
    _Lane lane,
    ProcessCommand command,
    Duration fullBudget,
    _Timing timing,
  ) {
    // Already the floor: no measurement could lower it.
    if (fullBudget <= mutantTimeout) {
      return Future<Duration>.value(fullBudget);
    }
    return _selectedBudgets[_keyOf(command)] ??= _measure(
      job,
      lane,
      command,
      fullBudget,
      timing,
    );
  }

  /// Runs [command] in [lane] against [job]'s unmodified file, and derives a
  /// budget from how long it took. The lane's copy holds the mutant on entry
  /// and on return; the original is put back only for the measurement,
  /// while the registry still tracks the file.
  Future<Duration> _measure(
    _Job job,
    _Lane lane,
    ProcessCommand command,
    Duration fullBudget,
    _Timing timing,
  ) async {
    final String path = lane.pathFor(job.mutant.filePath);
    lane.write(path, job.source);
    try {
      lane.cache.clear();
      final Stopwatch clock = Stopwatch()..start();
      final int? exitCode = await lane
          .commandFor(command)
          .run(timeout: fullBudget);
      timing.measurement = clock.elapsed;
      final Duration derived = _budgetFrom(clock.elapsed);
      return exitCode == 0 && derived < fullBudget ? derived : fullBudget;
    } finally {
      lane.write(path, job.mutant.applyTo(job.source));
    }
  }

  /// [ProcessCommand] has no value equality, and a selection builds a new
  /// one for every mutant.
  static String _keyOf(ProcessCommand command) => <String>[
    command.workingDirectory ?? '',
    command.executable,
    ...command.arguments,
  ].join('\u0000');
}

/// A target file as [MutationTestRunner.run] read and enumerated it, once.
class _PlannedFile {
  const _PlannedFile(this.path, this.source, this.mutants);

  final String path;
  final String source;
  final List<Mutant> mutants;
}

/// A [MutantTiming] while [MutationTestRunner._runOne] is still filling it
/// in.
class _Timing {
  _Timing(this.worker);

  final int worker;
  Duration gate = Duration.zero;
  bool selected = false;
  Duration? measurement;
  Duration? test;
  Duration? retry;

  MutantTiming build(MutantResult result, Duration elapsed) => MutantTiming(
    result: result,
    worker: worker,
    elapsed: elapsed,
    gate: gate,
    selected: selected,
    measurement: measurement,
    test: test,
    retry: retry,
  );
}

/// One mutant with what it needs to run.
class _Job {
  const _Job(this.mutant, this.source, this.gate, this.command);

  final Mutant mutant;

  /// Its file's unmodified content.
  final String source;

  final CompileSafetyGate gate;

  /// What it runs, rooted in the package — `null` when no test reaches it.
  final ProcessCommand? command;
}

/// Where one worker runs mutants: the package itself when [sandbox] is
/// `null`, or that sandbox.
class _Lane {
  _Lane(ProcessCommand testCommand, this.sandbox, {required this.flutter})
    : cache = TestCompilationCache(
        sandbox?.directory ?? testCommand.workingDirectory,
      );

  final WorkerSandbox? sandbox;
  final bool flutter;

  /// This lane's own — see [TestCompilationCache].
  final TestCompilationCache cache;

  int get id => sandbox?.id ?? 0;

  String pathFor(String filePath) => sandbox?.pathFor(filePath) ?? filePath;

  ProcessCommand commandFor(ProcessCommand command) =>
      sandbox?.commandFor(command, flutter: flutter) ?? command;

  void write(String path, String content) {
    final WorkerSandbox? box = sandbox;
    if (box == null) {
      File(path).writeAsStringSync(content);
    } else {
      box.write(path, content);
    }
  }
}
