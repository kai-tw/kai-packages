import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';

import '../generated_file_filter.dart';
import '../mutant.dart';
import '../mutation_operator.dart';
import '../mutation_visitor.dart';
import '../operators.dart';
import 'compile_safety_gate.dart';
import 'file_mutation_report.dart';
import 'mutant_result.dart';
import 'mutant_verdict.dart';
import 'mutated_file_registry.dart';
import 'mutation_run_report.dart';
import 'process_command.dart';
import 'test_compilation_cache.dart';

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
  }) : operators = operators ?? defaultOperators(),
       baselineTimeout = baselineTimeout ?? mutantTimeout * 10 {
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

  final List<MutationOperator> operators;

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
    _registry.armSignalRestore(beforeExit: ProcessCommand.killAllRunning);
    try {
      _testCache.clear();
      final Stopwatch baselineClock = Stopwatch()..start();
      final int? baselineExitCode = await testCommand.run(
        timeout: baselineTimeout,
      );
      final Duration baseline = baselineClock.elapsed;
      if (baselineExitCode == null) {
        return MutationRunReport.aborted(
          AbortKind.baselineTimeout,
          'the test command did not finish against unmodified code within '
          'the timeout (${baselineTimeout.inSeconds}s) — refusing to score '
          'mutants against a baseline that never even completes. If the '
          'suite is merely slow rather than hanging, raise the baseline '
          'timeout (--baseline-timeout).',
        );
      }
      if (baselineExitCode != 0) {
        return MutationRunReport.aborted(
          AbortKind.baselineFailed,
          'the test command failed against unmodified code (exit '
          '$baselineExitCode) — refusing to score mutants against a baseline '
          'that was already red',
          baselineDuration: baseline,
        );
      }
      final Duration derived = baseline * baselineFactor;
      final Duration budget = derived > mutantTimeout ? derived : mutantTimeout;

      final Map<String, CompileSafetyGate> gates =
          <String, CompileSafetyGate>{};
      for (final String filePath in targets) {
        final String source = await File(filePath).readAsString();
        if (_collectMutants(filePath, source).isEmpty) {
          gates[filePath] = compileSafetyGate;
          continue;
        }
        final CompileSafetyGate? gate = await _gateFor(filePath);
        if (gate == null) {
          return MutationRunReport.aborted(
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

      final List<FileMutationReport> fileReports = <FileMutationReport>[];
      for (final String filePath in targets) {
        fileReports.add(await _runFile(filePath, gates[filePath]!, budget));
      }
      return MutationRunReport.completed(
        fileReports,
        baselineDuration: baseline,
        mutantTimeout: budget,
      );
    } finally {
      // A safety net, not the primary mechanism — _runOne already restores
      // after every individual mutant. This only fires if something escaped
      // before that: at most one file's worth of cleanup, never a whole
      // run's worth.
      _registry.restoreAll();
      await _registry.disarm();
    }
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

  Future<FileMutationReport> _runFile(
    String filePath,
    CompileSafetyGate gate,
    Duration budget,
  ) async {
    final String originalSource = await File(filePath).readAsString();
    final List<Mutant> mutants = _collectMutants(filePath, originalSource);

    int detected = 0;
    int undetected = 0;
    int invalid = 0;
    int timedOut = 0;
    final List<MutantResult> undetectedResults = <MutantResult>[];
    final List<MutantResult> invalidResults = <MutantResult>[];
    final List<MutantResult> timedOutResults = <MutantResult>[];

    for (final Mutant mutant in mutants) {
      final MutantVerdict verdict = await _runOne(
        mutant,
        originalSource,
        gate,
        budget,
      );
      switch (verdict) {
        case MutantVerdict.invalid:
          invalid++;
          // Kept, not just counted — same reasoning as timedOutResults
          // below: a bare count cannot tell a caller which lines the
          // compile-safety gate rejected, or whether 27 of them share one
          // cause.
          invalidResults.add(MutantResult(mutant: mutant, verdict: verdict));
        case MutantVerdict.timeout:
          timedOut++;
          // Kept, not just counted. A timed-out mutant is real code that went
          // unmeasured, and a caller who only gets the number cannot tell
          // WHICH line, whether it is the same one across runs, or go and look
          // at it. Measured: a mutant that timed out on every round of a file
          // was therefore never scored at all — permanently invisible behind a
          // count nobody reads per-mutant.
          timedOutResults.add(MutantResult(mutant: mutant, verdict: verdict));
        case MutantVerdict.detected:
          detected++;
        case MutantVerdict.undetected:
          undetected++;
          undetectedResults.add(
            MutantResult(mutant: mutant, verdict: verdict),
          );
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

  /// Applies [mutant] to disk, checks compile-safety, runs [testCommand] for
  /// at most [budget] if it passed that gate, then restores the file before
  /// returning — regardless of which branch was taken, so a thrown exception
  /// here still leaves the file clean.
  Future<MutantVerdict> _runOne(
    Mutant mutant,
    String originalSource,
    CompileSafetyGate gate,
    Duration budget,
  ) async {
    _registry.track(mutant.filePath, originalSource);
    await File(mutant.filePath).writeAsString(mutant.applyTo(originalSource));
    try {
      if (!await gate.compiles(mutant.filePath)) {
        return MutantVerdict.invalid;
      }
      _testCache.clear();
      final int? exitCode = await testCommand.run(timeout: budget);
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
        return MutantVerdict.timeout;
      }
      return exitCode == 0 ? MutantVerdict.undetected : MutantVerdict.detected;
    } finally {
      _registry.restore(mutant.filePath);
    }
  }
}
