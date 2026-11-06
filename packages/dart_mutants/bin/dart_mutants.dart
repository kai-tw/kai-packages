import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_mutants/src/review/diff_scope.dart';
import 'package:dart_mutants/src/review/review_comments.dart';
import 'package:dart_mutants/src/runner/compile_safety_gate.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/line_selection.dart';
import 'package:dart_mutants/src/runner/mutant_progress.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:dart_mutants/src/runner/mutation_test_runner.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:dart_mutants/src/runner/run_budget.dart';
import 'package:dart_mutants/src/runner/run_plan.dart';
import 'package:dart_mutants/src/runner/run_record.dart';
import 'package:dart_mutants/src/runner/test_slots.dart';
import 'package:dart_mutants/src/runner/wait_span.dart';
import 'package:dart_mutants/src/version_check.dart';
import 'package:path/path.dart' as p;

/// The CLI contract: a file list and a test command in, per-file
/// total/undetected out. Which files to pass and what to do with the report
/// is deliberately not this binary's concern — that is the caller's job,
/// one layer up.
Future<void> main(List<String> arguments) async {
  if (_RunSignalCommand.parse(arguments) case final _RunSignalCommand command) {
    exitCode = command.send(arguments.skip(1).toList());
    return;
  }
  final ArgResults? args = _parseAndValidate(arguments, _buildParser());
  if (args == null) {
    return;
  }
  final TestSlots slots;
  try {
    slots = await TestSlots.fromEnvironment();
  } on FormatException catch (e) {
    stderr.writeln('dart_mutants: ${e.message}, not "${e.source}".');
    exitCode = 64; // EX_USAGE
    return;
  }

  try {
    await VersionCheck().check();
  } on OutdatedEngineException catch (e) {
    stderr.writeln('dart_mutants: $e');
    exitCode = 2;
    return;
  }

  final DiffScope? scope;
  try {
    scope = await _diffScope(args);
  } on DiffScopeException catch (e) {
    stderr.writeln('--diff: $e — nothing was measured.');
    exitCode = 2;
    return;
  }
  if (scope != null && scope.lines.isEmpty) {
    exitCode = _nothingToMutate(args);
    return;
  }
  exitCode = await _runAndReport(args, scope, slots);
}

/// `dart_mutants pause|resume|stop [<pid>]`: the signal each sends to a run
/// in progress — see [RunRecord] for how one is found.
enum _RunSignalCommand {
  pause(ProcessSignal.sigusr1),
  resume(ProcessSignal.sigusr2),
  stop(ProcessSignal.sigterm);

  const _RunSignalCommand(this.signal);

  final ProcessSignal signal;

  /// The command [arguments] start with, or `null` for a run's arguments.
  static _RunSignalCommand? parse(List<String> arguments) {
    for (final _RunSignalCommand command in values) {
      if (arguments.isNotEmpty && arguments.first == command.name) {
        return command;
      }
    }
    return null;
  }

  /// Sends [signal] to the run [rest] names by pid, or else to the one run
  /// in the current directory's package; the exit code — 2 when there is no
  /// single such run.
  int send(List<String> rest) {
    final int? pid = rest.length == 1 ? int.tryParse(rest.single) : null;
    if (rest.length > 1 || (rest.isNotEmpty && pid == null)) {
      stderr.writeln('usage: dart_mutants $name [<pid>]');
      return 64; // EX_USAGE
    }
    final RunRecord? run = _target(pid);
    if (run == null) {
      return 2;
    }
    if (!Process.killPid(run.pid, signal)) {
      stderr.writeln('dart_mutants $name: run ${run.pid} has already ended.');
      return 2;
    }
    return 0;
  }

  /// The run with [pid], or without one the single run in the current
  /// directory's package — or `null`, having said on stderr why there is no
  /// single one.
  RunRecord? _target(int? pid) {
    final String package = RunRecord.packageOf(Directory.current.path);
    final List<RunRecord> runs = RunRecord.live()
        .where(
          (RunRecord r) =>
              pid == null ? r.packagePath == package : r.pid == pid,
        )
        .toList();
    if (runs.length == 1) {
      return runs.single;
    }
    final String where = pid == null ? 'in $package' : 'with pid $pid';
    stderr.writeln(
      runs.isEmpty
          ? 'dart_mutants $name: no run $where is going.'
          : 'dart_mutants $name: ${runs.length} runs are going $where (pids '
                '${runs.map((RunRecord r) => r.pid).join(', ')}) — name one: '
                'dart_mutants $name <pid>.',
    );
    return null;
  }
}

/// The scope --diff names, or `null` without --diff.
Future<DiffScope?> _diffScope(ArgResults args) async {
  final String? diffRef = args['diff'] as String?;
  if (diffRef == null) {
    return null;
  }
  return DiffScope.of(
    diffRef,
    packageRoot: Directory.current.path,
    files: args.rest.isEmpty ? null : args.rest,
  );
}

/// Says there is nothing to mutate, and writes the empty review a --review
/// caller is waiting for; the exit code, 1 only when that could not be
/// written.
int _nothingToMutate(ArgResults args) {
  stdout.writeln(
    'the change since ${args['diff']} only deletes lines, or touches no Dart '
    'file under lib/ — nothing new to mutate.',
  );
  final String? reviewPath = args['review'] as String?;
  return reviewPath != null && !_writeReport(reviewPath, '[]\n') ? 1 : 0;
}

/// The analyzers that judge whether a mutant compiles, and the closing of
/// them: the runner is handed them, so it does not close them.
class _Gates {
  const _Gates(this.gate, this.fallback);

  /// With no --analyze-command: the in-process gate, backed by `dart analyze`
  /// for any file it cannot judge (see MutationTestRunner.run). With one:
  /// that command alone — a caller who named their judge gets no substitute.
  factory _Gates.of(String? analyzeCommand, List<String> targets) =>
      analyzeCommand == null
      ? _Gates(
          InProcessAnalyzerGate(targets),
          const AnalyzerProcessGate(
            ProcessCommand('dart', <String>['analyze']),
          ),
        )
      : _Gates(AnalyzerProcessGate(_parseCommand(analyzeCommand)), null);

  final CompileSafetyGate gate;
  final CompileSafetyGate? fallback;

  Future<void> close() async {
    await gate.close();
    await fallback?.close();
  }
}

/// Runs [scope] (or the files given) and prints the report; the exit code.
Future<int> _runAndReport(
  ArgResults args,
  DiffScope? scope,
  TestSlots slots,
) async {
  final List<String> targets = scope?.files ?? args.rest;
  final _Gates gates = _Gates.of(args['analyze-command'] as String?, targets);
  // stdout is the JSON report's under --json, and nothing else may share it.
  final bool jsonOnStdout = args['json'] as bool;

  bool emit(MutationRunReport report) => _emitReport(
    report,
    jsonOnStdout: jsonOnStdout,
    outputPath: args['output'] as String?,
    historyPath: args['history'] as String?,
  );

  RunRecord? record;
  final MutationTestRunner runner = _runner(
    args,
    scope,
    gates,
    slots,
    quiet: jsonOnStdout,
    onStopped: (MutationRunReport stopped) {
      emit(stopped);
      record?.delete();
    },
  );
  final MutationRunReport report;
  try {
    // Announced right before run(), which catches the signals the record
    // invites before it first waits on anything.
    record = _announce();
    report = await runner.run(targets);
  } finally {
    record?.delete();
    await gates.close();
  }

  // The report is always printed here, before the exit code is chosen — a
  // non-zero exit (an aborted run, or any file with undetected mutants) must
  // never suppress it. A caller scoring per-file at a threshold other than
  // "zero undetected" depends on reading the JSON even when this process's
  // own exit code disagrees with their verdict.
  final bool written = emit(report);
  if (!written || report.aborted) {
    return 1;
  }
  return _verdict(report, args, quiet: jsonOnStdout);
}

/// This run's [RunRecord], or `null` when it cannot be written — the run
/// goes on, said to be out of reach of pause, resume and stop.
RunRecord? _announce() {
  try {
    return RunRecord.start(RunRecord.packageOf(Directory.current.path));
  } on FileSystemException catch (e) {
    stderr.writeln(
      'note: could not record this run for dart_mutants pause, resume and '
      'stop (${e.message}: ${e.path}). `kill -USR1 $pid` still pauses it, '
      '`kill -USR2 $pid` resumes it and `kill $pid` stops it.',
    );
    return null;
  }
}

MutationTestRunner _runner(
  ArgResults args,
  DiffScope? scope,
  _Gates gates,
  TestSlots slots, {
  required bool quiet,
  required void Function(MutationRunReport stopped) onStopped,
}) => MutationTestRunner(
  onStopped: onStopped,
  testCommand: _parseCommand(args['test-command'] as String),
  compileSafetyGate: gates.gate,
  fallbackCompileSafetyGate: gates.fallback,
  onGateFallback: (String filePath) => stderr.writeln(
    'note: the in-process analyzer rejects $filePath before it has been '
    'mutated, so its mutants are judged by `dart analyze` instead — one '
    'process per mutant, much slower. One known cause: the file uses '
    'language features newer than the analyzer package this was built with '
    'understands.',
  ),
  // Already validated by _parseAndValidate — safe to parse again here
  // rather than thread the number through as a second return value.
  mutantTimeout: Duration(seconds: int.parse(args['mutant-timeout'] as String)),
  baselineFactor: double.parse(args['baseline-factor'] as String),
  baselineTimeout: _optionalSeconds(args['baseline-timeout'] as String?),
  selectByCoverage: args['select-by-coverage'] as bool,
  // `auto` is the one value that is not a number: null opens a lane per
  // free slot.
  workers: int.tryParse(args['workers'] as String),
  slots: slots,
  runBudget: _optionalBudget(args['max-minutes'] as String?),
  journalPath: args['journal'] as String?,
  lines: scope?.lines ?? _lines(args),
  perLine: _perLine(args) ?? (scope == null ? null : 1),
  onJournalDiscarded: (String reason) => stderr.writeln(
    'note: the journal at ${args['journal']} was started over — $reason — '
    'so every mutant runs.',
  ),
  onPlan: _planPrinter(quiet: quiet),
  onProgress: _progressPrinter(quiet: quiet),
);

/// The exit code of a run that finished and whose report was written: 1 for
/// any undetected mutant. In review mode the comments are the finding, so
/// the run passes once they are written — unless the caller asked for any
/// survivor to fail it.
int _verdict(MutationRunReport report, ArgResults args, {required bool quiet}) {
  final bool anyUndetected = report.files.any(
    (FileMutationReport f) => f.undetected > 0,
  );
  final String? reviewPath = args['review'] as String?;
  if (reviewPath == null) {
    return anyUndetected ? 1 : 0;
  }
  final List<Map<String, Object>> comments = reviewComments(
    report,
    repoRoot: _repoRoot(),
  );
  if (!_writeReport(
    reviewPath,
    '${const JsonEncoder.withIndent('  ').convert(comments)}\n',
  )) {
    return 1;
  }
  if (!quiet) {
    stdout.writeln(
      'review: ${_count(comments.length, 'survivor')} to comment on, written '
      'to $reviewPath',
    );
  }
  return args['fail-on-survivors'] as bool && anyUndetected ? 1 : 0;
}

ArgParser _buildParser() {
  return ArgParser()
    ..addOption(
      'test-command',
      mandatory: true,
      help:
          'The "dart test ..." or "flutter test ..." command that runs the '
          'relevant tests, e.g. "flutter test test/foo_test.dart". It runs '
          'once unmodified; each mutant then runs against its test files '
          'compiled once for the whole run, applying the command\'s '
          'dart_test.yaml and its --name, --plain-name, --tags, '
          '--exclude-tags, --timeout, --preset and --run-skipped. Split on '
          'whitespace — quoting an argument that itself contains a space is '
          'not supported yet.',
    )
    ..addOption(
      'analyze-command',
      help:
          'Judge compile-safety by running this analyzer command once per '
          'mutant instead of the default in-process analyzer. Much slower: a '
          'fresh analyzer process per mutant. "dart analyze" works as-is; '
          '"flutter analyze" needs --no-fatal-infos --no-fatal-warnings, or '
          'it rejects valid mutants that merely trip a lint.',
    )
    ..addOption(
      'mutant-timeout',
      defaultsTo: '30',
      help:
          'The least number of seconds a mutant gets on one test file before '
          'it is killed and scored as a timeout instead of waited on forever. '
          'A slow test file gets more: see --baseline-factor.',
    )
    ..addOption(
      'baseline-factor',
      defaultsTo: _formatFactor(MutationTestRunner.defaultBaselineFactor),
      help:
          'A mutant\'s budget on a test file is the larger of --mutant-timeout '
          'and this many times that file\'s own unmutated run. The headroom '
          'is for machine load changing mid-run. 0 turns it off.',
    )
    ..addOption(
      'baseline-timeout',
      help:
          'Seconds the test command gets against unmodified code before the '
          'run aborts as hanging, and one test file gets to compile or to run '
          'unmutated. Defaults to ten times --mutant-timeout.',
    )
    ..addFlag(
      'select-by-coverage',
      negatable: false,
      help:
          'Collect per-test-file coverage once, then run each mutant against '
          'only the test files that enter the function it is in, and score a '
          'mutant in a function no test enters as undetected (marked '
          'uncovered) without running anything. Without it, every mutant runs '
          'against every test file. A command the coverage pass refuses, or a '
          'pass that fails, aborts the run before the first mutant (abortKind '
          'selection-unavailable).',
    )
    ..addMultiOption(
      'lines',
      valueHelp: 'file:ranges',
      splitCommas: false,
      help:
          'Mutate only these lines of this file, e.g. lib/a.dart:3-7,12 — a '
          'diff\'s changed lines, so a review sees mutants in what it changed. '
          'Repeat it per file; a file given without it is mutated whole.',
    )
    ..addOption(
      'per-line',
      valueHelp: 'n',
      help:
          'At most this many mutants on any one line. Which ones a line keeps '
          'is fixed by the code, so a resumed run keeps the same ones.',
    )
    ..addOption(
      'workers',
      abbr: 'j',
      defaultsTo: '1',
      valueHelp: 'n|auto',
      help:
          'How many test files run at once. Each worker has its own copy of '
          'the package made of links, a few megabytes, plus its own compiler '
          'and test process; the package itself is never written to. Each '
          'worker also waits for a test slot, which every dart_mutants run on '
          'this machine shares, before it compiles or runs a test file — see '
          r'$DART_MUTANTS_SLOTS in the README. `auto` opens one worker per '
          'slot free when the mutants start, and at least one.',
    )
    ..addOption(
      'max-minutes',
      valueHelp: 'minutes',
      help:
          'Stop without scoring anything as soon as the pace the mutants are '
          'holding says they will take longer than this. The baseline and the '
          'coverage pass do not count against it.',
    )
    ..addOption(
      'output',
      abbr: 'o',
      valueHelp: 'path',
      help:
          'Also write the report as JSON to this file, replacing it. Written '
          'on every run, aborted ones included. stdout keeps the progress and '
          'the text report.',
    )
    ..addOption(
      'journal',
      valueHelp: 'path',
      help:
          'Record the baseline, the coverage map and each mutant\'s result in '
          'this file as they finish. A run started again with the same file '
          'reuses all of them, except timeouts, and runs only the rest — as '
          'long as the test command, gate, operators, --select-by-coverage '
          'and the content of pubspec.yaml, pubspec.lock, lib/, test/ and the '
          'files given are unchanged, and no release since changed how a '
          'verdict is reached; otherwise the file is started over.',
    )
    ..addOption(
      'history',
      valueHelp: 'path',
      help:
          'Append this run\'s report, statistics included, as one JSON line '
          'to this file, so runs can be compared later. Aborted runs are '
          'appended too.',
    )
    ..addOption(
      'diff',
      valueHelp: 'ref',
      help:
          'Review mode: mutate only the lines changed since the merge base of '
          'this ref and HEAD, uncommitted edits to tracked files included, at '
          'most --per-line mutants a line (default 1). With no files given, '
          'every Dart file under the package\'s lib/ that the change touched, '
          'generated files left out; a file whose change only deleted lines '
          'is skipped.',
    )
    ..addOption(
      'review',
      valueHelp: 'path',
      help:
          'With --diff: write each survivor that a test runs past without '
          'failing to this file, as a JSON list of {path, line, body} ready to '
          'post on a pull request. A survivor on a line no test executes is '
          'left out (that is line coverage\'s finding). The run then exits 0 '
          'whatever the scores, unless --fail-on-survivors.',
    )
    ..addFlag(
      'fail-on-survivors',
      negatable: false,
      help:
          'With --review: exit 1 if any mutant survived, on a covered line or '
          'not, once the review file is written.',
    )
    ..addFlag(
      'json',
      help:
          'Print the report as JSON to stdout instead of text, with no '
          'progress. Prefer --output, which keeps the progress.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);
}

/// The repository the review's paths are relative to: the git top level
/// above the working directory, or the working directory itself.
String _repoRoot() {
  final ProcessResult result = Process.runSync('git', <String>[
    'rev-parse',
    '--show-toplevel',
  ]);
  return result.exitCode == 0
      ? (result.stdout as String).trim()
      : Directory.current.path;
}

/// Parses [arguments] against [parser] and validates them. Returns `null`
/// if something was already wrong enough to handle right here — bad
/// syntax, `--help`, no files, a malformed timeout option — having
/// already printed whatever was needed and set [exitCode]; the caller
/// should just return in that case.
ArgResults? _parseAndValidate(List<String> arguments, ArgParser parser) {
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(parser.usage);
    exitCode = 64; // EX_USAGE
    return null;
  }

  if (args['help'] as bool) {
    stdout
      ..writeln('dart_mutants --test-command "<command>" [options] <files>')
      ..writeln(
        'dart_mutants pause|resume|stop [<pid>]   pause a run between test '
        'file runs, resume it, or stop it scoring nothing; without a pid, the '
        'one run in this package',
      )
      ..writeln()
      ..writeln(parser.usage);
    return null;
  }

  if (args.rest.isEmpty && args['diff'] == null) {
    stderr.writeln('no files given — nothing to mutate');
    stderr.writeln(parser.usage);
    exitCode = 64;
    return null;
  }

  final String? optionError = _optionError(args);
  if (optionError != null) {
    stderr.writeln(optionError);
    exitCode = 64;
    return null;
  }

  return args;
}

/// The first thing wrong with any option's value, or `null` if nothing is.
String? _optionError(ArgResults args) =>
    _reviewOptionError(args) ??
    _timeoutOptionError(args) ??
    _maxMinutesOptionError(args) ??
    _outputOptionError(args) ??
    _workersOptionError(args) ??
    _perLineOptionError(args) ??
    _linesOptionError(args);

/// What is wrong with how --diff, --review, --fail-on-survivors and --lines
/// are combined, or `null` if nothing is.
String? _reviewOptionError(ArgResults args) {
  final bool diff = args['diff'] != null;
  if (args['review'] != null && !diff) {
    return '--review needs --diff <ref>: a review comments on changed lines';
  }
  if (args['fail-on-survivors'] as bool && args['review'] == null) {
    return '--fail-on-survivors needs --review <file>';
  }
  if (diff && (args['lines'] as List<String>).isNotEmpty) {
    return '--diff and --lines both choose the lines; give one';
  }
  return null;
}

String? _perLineOptionError(ArgResults args) {
  final String? perLine = args['per-line'] as String?;
  return perLine != null && (int.tryParse(perLine) ?? 0) < 1
      ? '--per-line must be a positive whole number'
      : null;
}

/// What is wrong with --lines, or `null` if nothing is. A --lines file that
/// is not among the files given would silently narrow nothing, so it is
/// refused.
String? _linesOptionError(ArgResults args) {
  final Set<String> targets = args.rest.map(_absolute).toSet();
  for (final String value in args['lines'] as List<String>) {
    try {
      final String file = LineSelection.parse(value).file;
      if (!targets.contains(_absolute(file))) {
        return '--lines names $file, which is not among the files given';
      }
    } on FormatException catch (e) {
      return '--lines: ${e.message} (${e.source})';
    }
  }
  return null;
}

String _absolute(String path) => p.normalize(p.absolute(path));

/// --lines as the runner takes it, or `null` when none was given.
Map<String, Set<int>>? _lines(ArgResults args) {
  final List<String> values = args['lines'] as List<String>;
  if (values.isEmpty) {
    return null;
  }
  final Map<String, Set<int>> lines = <String, Set<int>>{};
  for (final String value in values) {
    final LineSelection selection = LineSelection.parse(value);
    lines.putIfAbsent(selection.file, () => <int>{}).addAll(selection.lines);
  }
  return lines;
}

int? _perLine(ArgResults args) =>
    int.tryParse(args['per-line'] as String? ?? '');

/// What is wrong with the three timeout options, or `null` if nothing is.
String? _timeoutOptionError(ArgResults args) {
  if (!_isPositiveSeconds(args['mutant-timeout'] as String)) {
    return '--mutant-timeout must be a positive number of seconds';
  }
  final String? baselineTimeout = args['baseline-timeout'] as String?;
  if (baselineTimeout != null && !_isPositiveSeconds(baselineTimeout)) {
    return '--baseline-timeout must be a positive number of seconds';
  }
  final double? factor = double.tryParse(
    args['baseline-factor'] as String,
  );
  if (factor == null || !factor.isFinite || factor < 0) {
    return '--baseline-factor must be a number, 0 or more';
  }
  return null;
}

/// What is wrong with --max-minutes, or `null`. Its own check rather than a
/// fourth branch of [_timeoutOptionError]: those three bound one command
/// each, this one bounds the whole run.
String? _maxMinutesOptionError(ArgResults args) {
  final String? maxMinutes = args['max-minutes'] as String?;
  return maxMinutes != null && !_isPositiveNumber(maxMinutes)
      ? '--max-minutes must be a positive number of minutes'
      : null;
}

/// What is wrong with --output or --history that can be seen before the
/// run, or `null`.
/// Checked up front: a run can take hours, and finding out at the end that
/// the report has nowhere to go loses all of it.
String? _outputOptionError(ArgResults args) {
  for (final String option in <String>['output', 'history', 'journal']) {
    final String? path = args[option] as String?;
    if (path != null &&
        (path.isEmpty || FileSystemEntity.isDirectorySync(path))) {
      return '--$option must name a file, not a directory';
    }
  }
  return null;
}

/// Prints [report] — as JSON when [jsonOnStdout], as text otherwise — writes
/// it to [outputPath] and appends it to [historyPath], each when given.
/// Returns whether every write worked; both are attempted either way.
bool _emitReport(
  MutationRunReport report, {
  required bool jsonOnStdout,
  required String? outputPath,
  required String? historyPath,
}) {
  final Map<String, Object?> data = report.toJson();
  final String json = const JsonEncoder.withIndent('  ').convert(data);
  if (jsonOnStdout) {
    stdout.writeln(json);
  } else {
    _printText(report);
  }
  final bool written = outputPath == null || _writeReport(outputPath, json);
  final bool appended =
      historyPath == null || _appendHistory(historyPath, jsonEncode(data));
  return written && appended;
}

/// Appends [line] to [path], creating it and its directory if needed.
/// Returns whether it worked, having said why on stderr when it did not.
bool _appendHistory(String path, String line) {
  try {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    return true;
  } on FileSystemException catch (e) {
    stderr.writeln('could not append the report to $path: $e');
    return false;
  }
}

/// Writes [json] to [path] through a sibling temporary file and a rename,
/// so a reader never sees half a report. Returns whether it worked, having
/// said why on stderr when it did not.
bool _writeReport(String path, String json) {
  final File target = File(path);
  final File partial = File('$path.partial');
  try {
    target.parent.createSync(recursive: true);
    partial.writeAsStringSync('$json\n', flush: true);
    partial.renameSync(target.path);
    return true;
  } on FileSystemException catch (e) {
    stderr.writeln('could not write the report to $path: $e');
    return false;
  }
}

String? _workersOptionError(ArgResults args) {
  final String given = args['workers'] as String;
  final int? workers = int.tryParse(given);
  return given != 'auto' && (workers == null || workers < 1)
      ? '--workers must be a whole number, 1 or more, or auto'
      : null;
}

bool _isPositiveSeconds(String value) {
  final int? seconds = int.tryParse(value);
  return seconds != null && seconds > 0;
}

/// Minutes take a fraction — half an hour of mutants is a plausible cap,
/// and `--max-minutes 0.5` should mean it rather than be a usage error.
bool _isPositiveNumber(String value) {
  final double? number = double.tryParse(value);
  return number != null && number.isFinite && number > 0;
}

Duration? _optionalSeconds(String? value) =>
    value == null ? null : Duration(seconds: int.parse(value));

RunBudget? _optionalBudget(String? value) => value == null
    ? null
    : RunBudget(
        Duration(milliseconds: (double.parse(value) * 60000).round()),
      );

/// `4`, not `4.0`, in `--help`.
String _formatFactor(double factor) => factor == factor.truncateToDouble()
    ? factor.toInt().toString()
    : factor.toString();

String _formatSeconds(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

/// What a full-command mutant's timeout was measured against — see
/// MutationTestRunner.baselineFactor.
void _printBudget(MutationRunReport report) {
  final Duration? baseline = report.baselineDuration;
  final Duration? budget = report.mutantTimeout;
  if (baseline != null && budget != null) {
    stdout.writeln(
      'baseline ${_formatSeconds(baseline)}, ${_budgetPhrase(budget)}',
    );
  }
}

String _budgetPhrase(Duration budget) =>
    'each mutant given at least ${_formatSeconds(budget)} a test file';

void _printPlan(RunPlan plan) {
  final String reused = plan.reused == 0
      ? ''
      : ' (${plan.reused} more reused from the journal)';
  final String fromJournal = <String>[
    if (plan.baselineReused) 'baseline',
    if (plan.coverageReused) 'coverage map',
  ].join(' and ');
  stdout.writeln(
    '${_count(plan.mutantCount, 'mutant')} in '
    '${_count(plan.fileCount, 'file')}$reused — baseline '
    '${_formatSeconds(plan.baseline)}, ${_budgetPhrase(plan.budget)}'
    '${fromJournal.isEmpty ? '' : ' ($fromJournal from the journal)'}',
  );
}

/// Nothing when [quiet]: under --json, stdout is the report's alone.
void Function(RunPlan)? _planPrinter({required bool quiet}) =>
    quiet ? null : _printPlan;

void Function(MutantProgress)? _progressPrinter({required bool quiet}) =>
    quiet ? null : _printProgress;

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

/// One line per mutant, `[completed/total] verdict path:line:column
/// operator (elapsed, ~left)`, written as it finishes.
void _printProgress(MutantProgress progress) {
  final MutantResult r = progress.result;
  final String verdict = r.uncovered ? 'uncovered' : r.verdict.name;
  final String left = progress.completed == progress.total
      ? ''
      : ', ~${formatWait(progress.projectedRemaining)} left';
  stdout.writeln(
    '[${progress.completed}/${progress.total}] $verdict '
    '${r.mutant.filePath}:${r.mutant.line}:${r.mutant.column} '
    '${r.mutant.operatorName} (${_formatSeconds(progress.elapsed)}$left)',
  );
}

ProcessCommand _parseCommand(String command) {
  final List<String> parts = command.trim().split(RegExp(r'\s+'));
  return ProcessCommand(parts.first, parts.skip(1).toList());
}

void _printText(MutationRunReport report) {
  if (report.aborted) {
    stdout.writeln('aborted: ${report.abortReason}');
    return;
  }
  _printBudget(report);
  for (final FileMutationReport f in report.files) {
    final String rate = f.detectionRate == null
        ? 'n/a'
        : '${(f.detectionRate! * 100).toStringAsFixed(0)}%';
    stdout.writeln(
      '${f.filePath}: $rate (${f.detected}/${f.total} detected, '
      '${f.invalid} invalid, ${f.timedOut} timed out)',
    );
    for (final MutantResult r in f.undetectedMutants) {
      stdout.writeln(
        '  ${r.uncovered ? 'undetected (no test enters it)' : 'undetected'}: '
        '${r.mutant.operatorName} at '
        '${f.filePath}:${r.mutant.line}:${r.mutant.column} — '
        '${r.mutant.description}',
      );
    }
    // Printed with the same weight as an undetected one — see
    // FileMutationReport.invalidMutants for why a bare `invalid` count is
    // not something a caller can act on.
    for (final MutantResult r in f.invalidMutants) {
      stdout.writeln(
        '  invalid (NOT scored): ${r.mutant.operatorName} at '
        '${f.filePath}:${r.mutant.line}:${r.mutant.column} — '
        '${r.mutant.description}',
      );
    }
    // Printed with the same weight as an undetected one. A timed-out mutant is
    // real code that went unmeasured, and the count on the line above says so
    // without saying which — so on its own it is a number nobody acts on.
    // A timed-out mutant always ran, so it always has a budget.
    for (final MutantResult r in f.timedOutMutants) {
      stdout.writeln(
        '  timed out at ${_formatSeconds(r.timeout!)} '
        '(NOT scored): ${r.mutant.operatorName} at '
        '${f.filePath}:${r.mutant.line}:${r.mutant.column} — '
        '${r.mutant.description}',
      );
    }
  }
}
