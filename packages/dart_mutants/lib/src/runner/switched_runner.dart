import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../mutant.dart';
import 'compile_safety_gate.dart';
import 'mutant_result.dart';
import 'mutant_verdict.dart';
import 'switched_file.dart';
import 'switched_job.dart';
import 'switched_stats.dart';
import 'switched_toolchain.dart';
import 'temp_space.dart';
import 'test_compiler.dart';
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
/// A test file has to compile and pass with no mutant on before any mutant
/// runs against it. One that does not means this run would not run what the
/// test command runs, so the whole run stops, naming the file — scoring
/// mutants against it would read every one of them as detected.
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
    this.workers = 1,
    this.arguments = const <String>[],
    this.shouldStop,
  });

  final SwitchedToolchain toolchain;

  /// The package's directory.
  final String root;

  /// The gate that judges a target file, by its path.
  final SourceCompileSafetyGate Function(String file) gateFor;
  final TempSpace temps;
  final int workers;

  /// The test command's own filtering options, handed to every test file.
  final List<String> arguments;

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

  /// The test files each mutant still has to pass on, by id. A mutant whose
  /// set empties survived.
  final Map<int, Set<String>> _remaining = <int, Set<String>>{};

  /// Each mutant's own test time so far, by id.
  final Map<int, Duration> _spent = <int, Duration>{};

  final Set<int> _settled = <int>{};

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

  /// Why the run cannot be trusted, once a lane finds out.
  String? _failure;

  bool get _stopped => _failure != null || (shouldStop?.call() ?? false);

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

  /// [lanes] closed and their directories deleted, their disk use kept.
  Future<void> _closeLanes(List<_Lane> lanes) async {
    for (final _Lane lane in lanes) {
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
  Future<void> _drain(_Lane lane) async {
    while (!_stopped) {
      if (_nextFile < _files.length) {
        await _runFile(lane, _files[_nextFile++]);
      } else if (_nextAlone < _alone.length) {
        await _runAlone(lane, _alone[_nextAlone++]);
      } else {
        return;
      }
    }
  }

  /// [file] compiled and run unmutated, then once per switched mutant still
  /// waiting on it.
  Future<void> _runFile(_Lane lane, String file) async {
    final Duration? unmutated = await _prepare(lane, file);
    _unmutated[file]!.complete(unmutated);
    if (unmutated == null) {
      return;
    }
    final Duration budget = budgetFrom(unmutated);
    for (final SwitchedJob job in _switched.values.toList()) {
      if (_stopped) {
        return;
      }
      if (_settled.contains(job.id) || !_remaining[job.id]!.contains(file)) {
        continue;
      }
      final int? exitCode = await _timed(
        job,
        () => lane.run(toolchain, job.id, budget),
      );
      _settle(job, file, exitCode, budget, lane.id);
    }
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
      _failure ??=
          '$file does not compile in a switched run, though the test command '
          'passed with it';
      return null;
    }
    clock.reset();
    final int? exitCode = await lane.run(toolchain, null, testFileTimeout);
    stats.unmutated += clock.elapsed;
    if (exitCode != 0) {
      _failure ??=
          '$file ${exitCode == null ? 'did not finish within '
                    '${testFileTimeout.inSeconds}s' : 'failed (exit $exitCode)'} '
          'unmutated in a switched run, though the test command passed with '
          'it';
      return null;
    }
    return clock.elapsed;
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
    return lane.compile(toolchain, root, testFile, arguments, testFileTimeout);
  }

  /// [job]'s mutant written into its file as it is, and each test file it
  /// has not yet passed on compiled around it and run until one decides it.
  Future<void> _runAlone(_Lane lane, SwitchedJob job) async {
    final String file = job.mutant.filePath;
    lane.hold(file, job.mutant.applyTo(job.source));
    try {
      for (final String test in _remaining[job.id]!.toList()..sort()) {
        final Duration? unmutated = await _unmutated[test]!.future;
        if (unmutated == null || _stopped || _settled.contains(job.id)) {
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
    final Set<String> remaining = _remaining[job.id]!..remove(file);
    final MutantVerdict? verdict = switch (exitCode) {
      null => MutantVerdict.timeout,
      0 => remaining.isEmpty ? MutantVerdict.undetected : null,
      _ => MutantVerdict.detected,
    };
    if (verdict == null) {
      return;
    }
    _settled.add(job.id);
    onResult(
      job,
      MutantResult(mutant: job.mutant, verdict: verdict, timeout: budget),
      lane,
      _spent[job.id] ?? Duration.zero,
    );
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
    Duration timeout,
  ) async {
    File(_entry).writeAsStringSync(
      toolchain.entry(
        box.pathFor(p.join(root, testFile)),
        root: box.directory,
        arguments: arguments,
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

  /// The last compiled program, run with [mutantId] on — `null` none — for
  /// at most [timeout]: its exit code, or `null` when it did not finish.
  Future<int?> run(
    SwitchedToolchain toolchain,
    int? mutantId,
    Duration timeout,
  ) => toolchain
      .command(
        _dill,
        workingDirectory: box.directory,
        packageConfig: packageConfig,
        work: workPath,
        mutantId: mutantId,
      )
      .run(timeout: timeout);
}
