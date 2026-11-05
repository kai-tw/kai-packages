import 'dart:io';

import 'package:path/path.dart' as p;

import '../mutant.dart';
import 'compile_safety_gate.dart';
import 'flutter_sdk.dart';
import 'mutant_result.dart';
import 'mutant_verdict.dart';
import 'schemata_job.dart';
import 'schemata_stats.dart';
import 'switched_file.dart';
import 'temp_space.dart';
import 'test_compiler.dart';
import 'worker_sandbox.dart';

/// Runs mutants of a `flutter test` package as switched files: every mutant
/// of a file written in at once (see [switchMutants]), each test file
/// compiled once, and each mutant run by starting `flutter_tester` on that
/// compiled file with [mutantIdVariable] set.
///
/// `flutter test` compiles every test file it runs, every time — 2–3.5s a
/// file on a large app even when nothing changed — so a mutant that 30 test
/// files reach costs over a minute before any test runs. Here that is paid
/// once per test file for the whole run.
///
/// Everything happens in a [WorkerSandbox], so the package is never written
/// to; the sandbox goes when the run ends, or with the run's other temporary
/// directories when it is interrupted or killed.
///
/// What the result can be trusted for rests on three checks, each of which
/// sends mutants back to `flutter test` (see [run]) rather than guess:
///
/// - each switched file must pass [gate] whole, and a mutant that stops it
///   compiling is left out of it;
/// - each test file must compile with the switched files in, and pass with
///   no mutant on, before any mutant runs against it;
/// - a mutant's run must end in 0 (passed) or 1 (a test failed).
class SchemataRunner {
  SchemataRunner({
    required this.sdk,
    required this.root,
    required this.gate,
    required this.temps,
    required this.testFileTimeout,
    required this.budgetFrom,
    required this.onResult,
    required this.stats,
    this.shouldStop,
  });

  final FlutterSdk sdk;

  /// The package's directory.
  final String root;

  final SourceCompileSafetyGate gate;
  final TempSpace temps;

  /// How long one test file's compile, or its unmutated run, may take.
  final Duration testFileTimeout;

  /// A mutant's budget on a test file, from how long that file took
  /// unmutated.
  final Duration Function(Duration unmutated) budgetFrom;

  /// Called with each mutant's result as soon as it has one, and how long
  /// its own test runs took.
  final void Function(SchemataJob job, MutantResult result, Duration tests)
  onResult;

  final SchemataStats stats;

  /// Checked between runs; `true` ends the pass, leaving every mutant
  /// without a result to the caller.
  final bool Function()? shouldStop;

  /// Mutants still waiting for a result, by id.
  final Map<int, SchemataJob> _live = <int, SchemataJob>{};

  /// Each live mutant's own test time so far.
  final Map<int, Duration> _spent = <int, Duration>{};

  bool get _stopped => shouldStop?.call() ?? false;

  /// Runs [jobs] and returns the ids of those left to `flutter test`: not
  /// switched, a test file of theirs broken, a run without a verdict, or
  /// not reached before [shouldStop].
  Future<Set<int>> run(List<SchemataJob> jobs) async {
    final Stopwatch clock = Stopwatch()..start();
    final Map<String, String> sources = await _switchAll(jobs);
    stats
      ..switching = clock.elapsed
      ..switched = _live.length;
    if (_live.isNotEmpty) {
      await _inSandbox(sources);
    }
    return <int>{
      for (final SchemataJob job in jobs)
        if (!_settled.contains(job.id)) job.id,
    };
  }

  /// Ids that got a result here.
  final Set<int> _settled = <int>{};

  /// Every file of [jobs] switched, by path; the switched mutants become
  /// [_live].
  Future<Map<String, String>> _switchAll(List<SchemataJob> jobs) async {
    final Map<String, List<SchemataJob>> byFile = <String, List<SchemataJob>>{};
    for (final SchemataJob job in jobs) {
      byFile.putIfAbsent(job.mutant.filePath, () => <SchemataJob>[]).add(job);
    }
    final Map<String, String> sources = <String, String>{};
    for (final MapEntry<String, List<SchemataJob>> file in byFile.entries) {
      final SwitchedFile switched = await _verified(file.key, file.value);
      for (final SchemataJob job in file.value) {
        if (switched.switched.contains(job.id)) {
          _live[job.id] = job;
        } else {
          stats.notSwitchedFor(switched.skipped[job.id] ?? 'not switched');
        }
      }
      if (switched.switched.isNotEmpty) {
        sources[file.key] = switched.source;
      }
    }
    return sources;
  }

  /// Writes [sources] into a sandbox of the package and runs [_live] there.
  Future<void> _inSandbox(Map<String, String> sources) async {
    final WorkerSandbox box = WorkerSandbox.create(
      id: 0,
      root: root,
      targets: sources.keys.toList(),
      temps: temps,
      flutter: true,
    );
    final Directory work = temps.create('schemata');
    final TestCompiler compiler = TestCompiler(
      sdk,
      packageConfig: p.join(box.directory, '.dart_tool', 'package_config.json'),
      workingDirectory: box.directory,
      outputDill: p.join(work.path, 'test.dill'),
    );
    try {
      sources.forEach(
        (String file, String source) => box.write(box.pathFor(file), source),
      );
      await _runAll(compiler, _Tester(sdk, box, work.path, root), box);
    } finally {
      await compiler.close();
      temps
        ..delete(work)
        ..delete(Directory(box.directory));
    }
  }

  /// Every test file in turn: compiled, run unmutated, then run once per
  /// mutant still waiting on it.
  Future<void> _runAll(
    TestCompiler compiler,
    _Tester tester,
    WorkerSandbox box,
  ) async {
    final List<String> files = <String>{
      for (final SchemataJob job in _live.values) ...job.tests,
    }.toList()..sort();
    for (final String file in files) {
      if (_stopped) {
        return;
      }
      final List<SchemataJob> waiting = <SchemataJob>[
        for (final SchemataJob job in _live.values)
          if (job.tests.contains(file)) job,
      ];
      if (waiting.isNotEmpty) {
        await _runFile(file, waiting, compiler, tester, box);
      }
    }
  }

  /// [file] compiled and run unmutated, then once per mutant in [waiting].
  Future<void> _runFile(
    String file,
    List<SchemataJob> waiting,
    TestCompiler compiler,
    _Tester tester,
    WorkerSandbox box,
  ) async {
    final Duration? unmutated = await _prepare(file, compiler, tester, box);
    if (unmutated != null) {
      await _runMutants(file, waiting, tester, budgetFrom(unmutated));
      return;
    }
    // Its mutants go back to `flutter test`, which may still score them.
    stats.brokenTestFiles.add(file);
    for (final SchemataJob job in waiting) {
      _live.remove(job.id);
    }
  }

  /// Compiles [file] and runs it unmutated: how long that run took, or
  /// `null` when either failed.
  Future<Duration?> _prepare(
    String file,
    TestCompiler compiler,
    _Tester tester,
    WorkerSandbox box,
  ) async {
    final String test = box.pathFor(p.join(root, file));
    final String entry = p.join(box.directory, 'dart_mutants_test_entry.dart');
    File(entry).writeAsStringSync(
      testEntry(test, config: testConfigFor(test, box.directory)),
    );
    final Stopwatch clock = Stopwatch()..start();
    final bool compiled = await compiler.compile(entry, testFileTimeout);
    stats
      ..compiling += clock.elapsed
      ..compiledTestFiles += 1;
    if (!compiled) {
      return null;
    }
    clock.reset();
    final int? exitCode = await tester.run(null, testFileTimeout);
    stats.unmutated += clock.elapsed;
    return exitCode == 0 ? clock.elapsed : null;
  }

  Future<void> _runMutants(
    String file,
    List<SchemataJob> waiting,
    _Tester tester,
    Duration budget,
  ) async {
    for (final SchemataJob job in waiting) {
      if (_stopped) {
        return;
      }
      final Stopwatch clock = Stopwatch()..start();
      final int? exitCode = await tester.run(job.id, budget);
      _spent[job.id] = (_spent[job.id] ?? Duration.zero) + clock.elapsed;
      _settle(job, exitCode, budget, last: file == job.tests.last);
    }
  }

  /// Gives [job] its result when [exitCode] decides one; a pass on any but
  /// its [last] test file decides nothing yet.
  void _settle(
    SchemataJob job,
    int? exitCode,
    Duration budget, {
    required bool last,
  }) {
    if (exitCode != null && exitCode != 0 && exitCode != 1) {
      stats.noVerdict++;
      _live.remove(job.id);
      return;
    }
    final MutantVerdict? verdict = switch (exitCode) {
      null => MutantVerdict.timeout,
      1 => MutantVerdict.detected,
      _ => last ? MutantVerdict.undetected : null,
    };
    if (verdict == null) {
      return;
    }
    _live.remove(job.id);
    _settled.add(job.id);
    onResult(
      job,
      MutantResult(mutant: job.mutant, verdict: verdict, timeout: budget),
      _spent[job.id]!,
    );
  }

  /// [jobs]' file switched with as many of them as still compile together:
  /// all at once when that compiles, or else each added in turn and kept
  /// only when the file still compiles with it — a mutant that, switched,
  /// hides a null check flow analysis relied on further down, say.
  Future<SwitchedFile> _verified(String file, List<SchemataJob> jobs) async {
    final String source = jobs.first.source;
    final SwitchedFile all = switchMutants(source, <int, Mutant>{
      for (final SchemataJob job in jobs) job.id: job.mutant,
    });
    if (all.switched.isEmpty || await gate.compilesSource(file, all.source)) {
      return all;
    }
    final Map<int, Mutant> kept = <int, Mutant>{};
    final Map<int, String> skipped = <int, String>{...all.skipped};
    for (final SchemataJob job in jobs.where(
      (SchemataJob j) => all.switched.contains(j.id),
    )) {
      final Map<int, Mutant> tried = <int, Mutant>{...kept, job.id: job.mutant};
      if (await gate.compilesSource(
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

/// `flutter_tester` on the compiled test file, from inside the sandbox.
class _Tester {
  _Tester(this._sdk, this._box, String work, String root)
    : _dill = p.join(work, 'test.dill'),
      _fontConfig = p.join(work, 'fonts.conf'),
      _assets = _assetsFor(root, work),
      _appName = _nameOf(root) {
    File(_fontConfig).writeAsStringSync(_sdk.fontConfig());
  }

  final FlutterSdk _sdk;
  final WorkerSandbox _box;
  final String _dill;
  final String _fontConfig;
  final String _assets;
  final String _appName;

  Future<int?> run(int? mutantId, Duration timeout) => _sdk
      .testerCommand(
        _dill,
        workingDirectory: _box.directory,
        packageConfig: p.join(
          _box.directory,
          '.dart_tool',
          'package_config.json',
        ),
        assets: _assets,
        fontConfig: _fontConfig,
        appName: _appName,
        mutantId: mutantId,
      )
      .run(timeout: timeout);

  /// The assets `flutter test` built for the package, which its baseline
  /// run left behind; an empty directory when there are none, and a test
  /// that needs them then fails unmutated and goes back to `flutter test`.
  static String _assetsFor(String root, String work) {
    final String built = p.join(root, 'build', 'unit_test_assets');
    if (Directory(built).existsSync()) {
      return built;
    }
    return (Directory(p.join(work, 'assets'))..createSync()).path;
  }

  static String _nameOf(String root) {
    final File pubspec = File(p.join(root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      return '';
    }
    return RegExp(
          r'^name:\s*(\S+)',
          multiLine: true,
        ).firstMatch(pubspec.readAsStringSync())?[1] ??
        '';
  }
}
