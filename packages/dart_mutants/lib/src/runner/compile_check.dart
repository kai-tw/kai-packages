import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/analysis_options.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/error_processor.dart';
import 'package:path/path.dart' as p;

import 'process_command.dart';

/// Whether a mutated file still compiles, checked before a mutant is ever
/// handed to the real test command.
///
/// This is the one thing this package cannot skip. An AST-legal edit is not
/// a type-legal one — swapping two ternary branches of different static
/// types, or borrowing a switch-expression arm's result whose type does not
/// fit the switch's own inferred type, both parse fine and both can fail to
/// compile. A test command that fails to even load a broken file still
/// exits non-zero, which — read naively as "the mutant was detected" —
/// makes the score go *up* for a file the mutation could not actually
/// exercise at all. That is the most dangerous failure shape this package
/// can have: a better-looking number sitting on top of nothing.
///
/// Failing closed is deliberate in every implementation: the cost of
/// wrongly discarding a valid mutant is a little lost coverage, but the cost
/// of wrongly accepting an invalid one is the inflated-score failure mode
/// above.
///
/// Two implementations, because the question has two honest answers with
/// very different costs. [InProcessAnalyzerCheck] is the default and asks the
/// analyzer directly, once per mutant, against an element model it keeps for
/// the whole run. [AnalyzerProcessCheck] shells out to a full analyzer
/// invocation per mutant and exists for a caller who needs the project's own
/// command to be the judge.
abstract interface class CompileCheck {
  /// Whether [filePath], as it is on disk, compiles.
  Future<bool> compiles(String filePath);

  /// Releases whatever the check holds for the run. Safe to call when
  /// [compiles] never ran, and safe to call twice.
  Future<void> close();
}

/// A check that can judge a file's would-be content without it being on
/// disk.
///
/// The runner prefers this where a check offers it: a mutant that does not
/// compile is then never written anywhere, and parallel workers can share
/// one check — the files they write sit in their own directories, which a
/// disk-reading check would each have to be pointed at.
abstract interface class SourceCompileCheck implements CompileCheck {
  /// Whether [filePath] would compile with [source] as its content. The file
  /// on disk is neither read for this nor changed.
  Future<bool> compilesSource(String filePath, String source);
}

/// A compile check that can also tell when a mutant deletes a call the
/// analyzer requires: a `super` call in an override of a `@mustCallSuper`
/// method.
///
/// Take `super.didChangeDependencies();` in a Flutter `State`. The method it
/// calls has an empty body, so deleting the call changes nothing a test can
/// observe, and the mutant survives every suite. The deletion still can't
/// ship: the analyzer reports `must_call_super`, which is a warning, and
/// `dart analyze` and `flutter analyze` both fail on warnings by default. The
/// same holds for `super.dispose()`, which does real work: the analyzer is
/// what guards that call, not a test. So these mutants are scored `invalid`,
/// like one that doesn't compile, instead of being run.
abstract interface class RequiredSuperCallCheck implements SourceCompileCheck {
  /// Whether [source], as [filePath]'s content, gets more `must_call_super`
  /// diagnostics than the file on disk. The file on disk isn't changed.
  ///
  /// A project that turns the diagnostic off in `analysis_options.yaml`, or
  /// with an `// ignore:` comment, gets `false`: its analyzer no longer
  /// guards the call, so the mutant is left for the tests.
  Future<bool> dropsRequiredSuperCall(String filePath, String source);
}

/// Asks the analyzer in this process whether a mutated file still compiles,
/// reusing one [AnalysisContextCollection] across every mutant of a run.
///
/// The subprocess this replaces rebuilt the whole package's element model
/// from scratch for every single mutant, only to type-check one file. Kept
/// alive here, each mutant costs a re-resolve of the file that changed and
/// whatever depends on it; files judged earlier in the run are re-read from
/// disk whenever the run moves on to a new file (see [compiles]). Measured against
/// `dart analyze` over 384 mutants — 264 across three pure-Dart packages in
/// this repository, 120 across two Flutter ones, where `dart:ui` and
/// `package:flutter` resolve like any other dependency — the two checks
/// agreed on every single verdict, at 9-89ms per mutant in process against
/// 1.2-2.2s for the subprocess.
///
/// "Compiles" means no diagnostic at [DiagnosticSeverity.ERROR], judged on
/// each diagnostic's own severity rather than on what `analysis_options.yaml`
/// says to report it as. That is the line `dart analyze` draws with its exit
/// code, except where a project re-rates a diagnostic, and there the two
/// differ in both directions — each time with this check on the side of what
/// the compiler actually does:
///
/// - a lint **promoted** to an error does not make a mutant invalid here. It
///   is a rule about the code, not a compile failure; the mutant still runs,
///   so it is still measured.
/// - a real compile error **downgraded** to a warning still makes a mutant
///   invalid here. `dart analyze` accepts that file, the compiler does not,
///   and the test command's resulting failure would read as `detected`.
///
/// Only the mutated file is checked, which matches the scope of the
/// subprocess check this replaces (`dart analyze <file>`).
///
/// The collection keeps the analyzer's default in-memory byte store for the
/// whole run, and nothing evicts from it. Measured over `clock_anchor`
/// (430 mutants, 26 files, one check for the whole session), this process's
/// RSS was 768MB before the check had analysed anything, peaked at 896MB
/// (the highest file boundary sampled was 887MB, after the sixth file), fell
/// to 222MB by 318 mutants, and stayed between 129MB and 165MB at every
/// file boundary from 371 mutants to the end. It finished far below where it
/// started — but over the last 16 mutants it only rose, 129MB to 158MB, and
/// a run of 430 mutants is too short to say whether that levels off. A large
/// Flutter app has not been measured.
///
/// This check resolves with the `package:analyzer` it was built against, not
/// with the SDK's own analyzer, so it can lag the language the SDK accepts:
/// a file using syntax newer than that analyzer knows reads as broken even
/// unmodified. That is caught one level up rather than here — the runner
/// runs every target through the check before mutating anything, and a file the
/// check rejects unmodified is judged by a fallback instead (see
/// `MutationTestRunner.run`).
class InProcessAnalyzerCheck implements RequiredSuperCallCheck {
  /// [includedPaths] must cover every file [compiles] will be asked about —
  /// the analyzer refuses a file outside them. Passing the run's own target
  /// files is enough; each is resolved within its enclosing package.
  InProcessAnalyzerCheck(List<String> includedPaths)
    : _includedPaths = includedPaths.map(_normalize).toList();

  final List<String> _includedPaths;
  AnalysisContextCollection? _collection;

  /// The disk, with a [compilesSource] question's content laid over it for
  /// as long as that question takes.
  final OverlayResourceProvider _files = OverlayResourceProvider(
    PhysicalResourceProvider.INSTANCE,
  );
  int _stamp = 0;

  /// The question before the latest one. Questions are answered one at a
  /// time: an overlay set for one would otherwise be seen by another that
  /// imports its file.
  Future<void> _previous = Future<void>.value();

  /// Every file this check has told the analyzer about, and the one it was
  /// last asked to judge.
  final Set<String> _touched = <String>{};
  String? _lastPath;

  static String _normalize(String path) => p.normalize(p.absolute(path));

  /// How many `must_call_super` diagnostics each file has on disk, by its
  /// normalized path. The runner never writes a target, so one count per
  /// file holds for the whole run.
  final Map<String, int> _requiredSuperCallsOnDisk = <String, int>{};

  @override
  Future<bool> compiles(String filePath) =>
      _serially(() => _judge(_normalize(filePath)));

  @override
  Future<bool> compilesSource(String filePath, String source) {
    final String path = _normalize(filePath);
    return _serially(() => _withContent(path, source, () => _judge(path)));
  }

  @override
  Future<bool> dropsRequiredSuperCall(String filePath, String source) {
    final String path = _normalize(filePath);
    return _serially(() async {
      final int onDisk = _requiredSuperCallsOnDisk[path] ??=
          _requiredSuperCalls(path, await _diagnostics(path));
      final int mutated = await _withContent(
        path,
        source,
        () async => _requiredSuperCalls(path, await _diagnostics(path)),
      );
      return mutated > onDisk;
    });
  }

  /// Answers [question] with [source] laid over [path].
  Future<TAnswer> _withContent<TAnswer>(
    String path,
    String source,
    Future<TAnswer> Function() question,
  ) async {
    _files.setOverlay(path, content: source, modificationStamp: ++_stamp);
    try {
      return await question();
    } finally {
      _files.removeOverlay(path);
      // Applied with the next question, which then reads the file — and
      // anything importing it — from disk again.
      _collection?.contextFor(path).changeFile(path);
    }
  }

  /// How many of [diagnostics], [path]'s, are `must_call_super` diagnostics
  /// the project still reports.
  ///
  /// The analyzer already drops one an `// ignore:` comment turns off, but
  /// not one `analysis_options.yaml` turns off: that is applied later, by
  /// whatever reports the diagnostics. So it's applied here.
  int _requiredSuperCalls(String path, List<Diagnostic>? diagnostics) {
    final AnalysisOptions? options = _collection
        ?.contextFor(path)
        .getAnalysisOptionsForFile(_files.getFile(path));
    return (diagnostics ?? const <Diagnostic>[])
        .where(
          (Diagnostic d) =>
              d.diagnosticCode.lowerCaseName == 'must_call_super' &&
              !_turnedOff(options, d),
        )
        .length;
  }

  /// Whether [options] turn [diagnostic] off: `ignore` in `errors:`.
  static bool _turnedOff(AnalysisOptions? options, Diagnostic diagnostic) {
    final ErrorProcessor? processor = ErrorProcessor.getProcessor(
      options,
      diagnostic,
    );
    return processor != null && processor.severity == null;
  }

  Future<TAnswer> _serially<TAnswer>(Future<TAnswer> Function() question) {
    final Future<TAnswer> answer = _previous.then((_) => question());
    _previous = answer.then<void>((_) {}, onError: _ignoreForOrdering);
    return answer;
  }

  /// The failure still reaches whoever asked, through the answer itself;
  /// the queue only needs to know it is over.
  static void _ignoreForOrdering(Object error) => error;

  Future<bool> _judge(String path) async {
    final List<Diagnostic>? diagnostics = await _diagnostics(path);
    return diagnostics != null &&
        !diagnostics.any(
          (Diagnostic d) =>
              d.diagnosticCode.severity == DiagnosticSeverity.ERROR,
        );
  }

  /// What the analyzer reports for [path], or `null` when it can't judge the
  /// file at all, which counts as not compiling.
  Future<List<Diagnostic>?> _diagnostics(String path) async {
    // The analyzer resolves a missing file as an empty one — which has no
    // errors, and would read as compiling. Checked here, before anything
    // below can be asked about it.
    if (!File(path).existsSync()) {
      return null;
    }
    final AnalysisContextCollection collection = _collection ??=
        AnalysisContextCollection(
          includedPaths: _includedPaths,
          resourceProvider: _files,
        );

    // The mutant was written to disk by the caller, behind the analyzer's
    // back. Without this the collection answers from the version it last
    // read — which for every mutant after the first is a different mutant.
    //
    // And the caller restores each file behind the analyzer's back too, so
    // moving on to a new file is not enough on its own: a file judged
    // earlier would still be held in whatever mutated state the analyzer
    // last saw, and anything importing it would be resolved against that.
    // Measured: `b.dart` importing a `final limit = maybe() ?? 10;` that had
    // been mutated earlier in the run read `invalid` here and `detected`
    // under `dart analyze`. So on every switch of file, every file touched
    // so far is re-read from disk. Consecutive mutants of one file — the
    // common case by far — still pay for one.
    if (path != _lastPath) {
      for (final String touched in _touched) {
        collection.contextFor(touched).changeFile(touched);
      }
      _lastPath = path;
    }
    _touched.add(path);
    final AnalysisContext context = collection.contextFor(path)
      ..changeFile(path);
    // Every context, not just this file's: a re-read file above may belong to
    // another package in the same run, and a change is only applied by the
    // context it was reported to.
    for (final AnalysisContext c in collection.contexts) {
      await c.applyPendingFileChanges();
    }

    final SomeErrorsResult result = await context.currentSession.getErrors(
      path,
    );
    // Anything but a real errors result — not a Dart file, not analyzable —
    // is treated as not compiling, for the reason the interface doc gives.
    // (A missing file never gets this far; see the check at the top.)
    if (result is! ErrorsResult) {
      return null;
    }
    return result.diagnostics;
  }

  @override
  Future<void> close() async {
    final AnalysisContextCollection? collection = _collection;
    _collection = null;
    await collection?.dispose();
  }
}

/// Runs a full analyzer invocation per mutant and reads its exit code.
///
/// The cost is a fresh analyzer process — the whole package's element model
/// rebuilt from nothing — for every mutant; see [InProcessAnalyzerCheck] for
/// what that measured at. It is kept for a caller who wants the project's own
/// analyzer command, with its own configuration, to be what decides.
///
/// `dart analyze`'s exit code is the signal, empirically confirmed (not
/// assumed) against Dart's own SDK: `0` clean, `2` warnings only, `3` at
/// least one error. `2` is accepted — a mutation is not obliged to be
/// lint-clean, only to actually compile and run — and anything other than
/// `0`/`2` (`3`, or an unexpected code from a crashed/misconfigured
/// analyzer) is treated as *not* compiling.
class AnalyzerProcessCheck implements CompileCheck {
  const AnalyzerProcessCheck(this.analyzeCommand);

  /// The project's analyzer invocation. `dart analyze` works as-is, for a
  /// Flutter package too.
  ///
  /// `flutter analyze` does **not** work as-is, and fails in the quiet
  /// direction. Its exit code treats infos and warnings as fatal by default,
  /// so it exits `1` for a mutant that compiles perfectly well, and this check
  /// reads that as invalid. `statement_deletion` hits it almost every time:
  /// it leaves a bare `;`, which trips `empty_statements` wherever that lint
  /// is on. Measured over 120 mutants of two Flutter packages here, bare
  /// `flutter analyze` disagreed with `dart analyze` on 42 of them, every one
  /// a valid mutant thrown out of the score. With
  /// `--no-fatal-infos --no-fatal-warnings` it exits `1` only for an error
  /// and disagreed on none.
  final ProcessCommand analyzeCommand;

  static const Set<int> _compilingExitCodes = <int>{0, 2};

  @override
  Future<bool> compiles(String filePath) async {
    final ProcessCommand withTarget = ProcessCommand(
      analyzeCommand.executable,
      <String>[...analyzeCommand.arguments, filePath],
      workingDirectory: analyzeCommand.workingDirectory,
    );
    // No timeout is passed, so `run()` cannot actually return null here —
    // static analysis over already-parsed source cannot hang. `exitCode` is
    // still nullable at the type level because `run()` is shared with the
    // test command, which does need one.
    final int? exitCode = await withTarget.run();
    return exitCode != null && _compilingExitCodes.contains(exitCode);
  }

  @override
  Future<void> close() async {}
}
