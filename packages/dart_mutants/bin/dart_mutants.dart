import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_mutants/src/runner/compile_safety_gate.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_progress.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:dart_mutants/src/runner/mutation_test_runner.dart';
import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:dart_mutants/src/runner/run_budget.dart';
import 'package:dart_mutants/src/runner/run_plan.dart';
import 'package:dart_mutants/src/runner/wait_span.dart';

/// The CLI contract: a file list and a test command in, per-file
/// total/undetected out. Which files to pass and what to do with the report
/// is deliberately not this binary's concern — that is `plan-mutation`'s
/// job, one layer up.
Future<void> main(List<String> arguments) async {
  final ArgParser parser = ArgParser()
    ..addOption(
      'test-command',
      mandatory: true,
      help:
          'The command that runs the relevant tests, e.g. '
          '"flutter test test/foo_test.dart". Split on whitespace — quoting '
          'an argument that itself contains a space is not supported yet.',
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
          'The least number of seconds a single mutant\'s test run gets '
          'before it is killed and scored as a timeout instead of waited on '
          'forever. A slow suite gets more: see --baseline-factor.',
    )
    ..addOption(
      'baseline-factor',
      defaultsTo: _formatFactor(MutationTestRunner.defaultBaselineFactor),
      help:
          'Each mutant\'s budget is the larger of --mutant-timeout and this '
          'many times the baseline\'s own wall time in this run. The headroom '
          'is for machine load changing mid-run. 0 turns it off.',
    )
    ..addOption(
      'baseline-timeout',
      help:
          'Seconds the test command gets against unmodified code before the '
          'run aborts as hanging. Defaults to ten times --mutant-timeout.',
    )
    ..addFlag(
      'select-by-coverage',
      negatable: false,
      help:
          'Collect per-test-file coverage once, then run each mutant against '
          'only the test files that enter the function it is in, and score a '
          'mutant in a function no test enters as undetected (marked '
          'uncovered) without running anything. Needs a "dart test ..." or '
          '"flutter test ..." --test-command; otherwise every mutant runs the '
          'full command.',
    )
    ..addOption(
      'workers',
      abbr: 'j',
      defaultsTo: '1',
      help:
          'How many mutants run at once. Above 1, each worker runs in a copy '
          'of the package made of links, a few megabytes each plus what the '
          'test command builds, and the package itself is never written to. '
          'Memory is the usual limit: each worker runs its own test command.',
    )
    ..addOption(
      'max-minutes',
      valueHelp: 'minutes',
      help:
          'Stop without scoring anything if the mutants would take longer '
          'than this. Refused before the first one is written when the plan '
          'alone is already over; otherwise stopped as soon as the pace the '
          'run is holding says it will not fit. The baseline and the '
          'coverage pass are what measure that pace, so they do not count '
          'against it.',
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
      'history',
      valueHelp: 'path',
      help:
          'Append this run\'s report, statistics included, as one JSON line '
          'to this file, so runs can be compared later. Aborted runs are '
          'appended too.',
    )
    ..addFlag(
      'json',
      help:
          'Print the report as JSON to stdout instead of text, with no '
          'progress. Prefer --output, which keeps the progress.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults? args = _parseAndValidate(arguments, parser);
  if (args == null) {
    return;
  }

  // With no --analyze-command: the in-process gate, backed by `dart analyze`
  // for any file it cannot judge (see MutationTestRunner.run). With one: that
  // command alone — a caller who named their judge gets no substitute.
  final String? analyzeCommand = args['analyze-command'] as String?;
  final CompileSafetyGate gate = analyzeCommand == null
      ? InProcessAnalyzerGate(args.rest)
      : AnalyzerProcessGate(_parseCommand(analyzeCommand));
  final CompileSafetyGate? fallback = analyzeCommand == null
      ? const AnalyzerProcessGate(ProcessCommand('dart', <String>['analyze']))
      : null;

  // stdout is the JSON report's under --json, and nothing else may share it.
  final bool jsonOnStdout = args['json'] as bool;
  final String? outputPath = args['output'] as String?;
  final String? historyPath = args['history'] as String?;

  final MutationTestRunner runner = MutationTestRunner(
    testCommand: _parseCommand(args['test-command'] as String),
    compileSafetyGate: gate,
    fallbackCompileSafetyGate: fallback,
    onGateFallback: (String filePath) => stderr.writeln(
      'note: the in-process analyzer rejects $filePath before it has been '
      'mutated, so its mutants are judged by `dart analyze` instead — one '
      'process per mutant, much slower. One known cause: the file uses '
      'language features newer than the analyzer package this was built with '
      'understands.',
    ),
    // Already validated by _parseAndValidate — safe to parse again here
    // rather than thread the number through as a second return value.
    mutantTimeout: Duration(
      seconds: int.parse(args['mutant-timeout'] as String),
    ),
    baselineFactor: double.parse(args['baseline-factor'] as String),
    baselineTimeout: _optionalSeconds(args['baseline-timeout'] as String?),
    selectByCoverage: args['select-by-coverage'] as bool,
    onSelectionFallback: (String reason) => stderr.writeln(
      'note: --select-by-coverage was not applied ($reason), so every '
      'mutant runs the full test command.',
    ),
    workers: int.parse(args['workers'] as String),
    runBudget: _optionalBudget(args['max-minutes'] as String?),
    onWorkersFallback: (String reason) => stderr.writeln(
      'note: --workers was not applied ($reason), so mutants run one at a '
      'time in the package itself.',
    ),
    onPlan: _planPrinter(quiet: jsonOnStdout),
    onProgress: _progressPrinter(quiet: jsonOnStdout),
  );

  final MutationRunReport report;
  try {
    report = await runner.run(args.rest);
  } finally {
    // The runner is handed the gates, so it does not close them; this is
    // where they were made.
    await gate.close();
    await fallback?.close();
  }

  // The report is always printed here, before exitCode is touched below —
  // a non-zero exit (an aborted run, or any file with undetected mutants)
  // must never suppress it. A caller scoring per-file at a threshold other
  // than "zero undetected" depends on reading the JSON even when this
  // process's own exit code disagrees with their verdict.
  final bool written = _emitReport(
    report,
    jsonOnStdout: jsonOnStdout,
    outputPath: outputPath,
    historyPath: historyPath,
  );

  if (!written || report.aborted) {
    exitCode = 1;
    return;
  }
  final bool anyUndetected = report.files.any(
    (FileMutationReport f) => f.undetected > 0,
  );
  exitCode = anyUndetected ? 1 : 0;
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
    stdout.writeln(parser.usage);
    return null;
  }

  if (args.rest.isEmpty) {
    stderr.writeln('no files given — nothing to mutate');
    stderr.writeln(parser.usage);
    exitCode = 64;
    return null;
  }

  final String? optionError =
      _timeoutOptionError(args) ??
      _maxMinutesOptionError(args) ??
      _outputOptionError(args) ??
      _workersOptionError(args);
  if (optionError != null) {
    stderr.writeln(optionError);
    exitCode = 64;
    return null;
  }

  return args;
}

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
  for (final String option in <String>['output', 'history']) {
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
  final int? workers = int.tryParse(args['workers'] as String);
  return workers == null || workers < 1
      ? '--workers must be a whole number, 1 or more'
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
    'each mutant given at most ${_formatSeconds(budget)}';

void _printPlan(RunPlan plan) {
  stdout.writeln(
    '${_count(plan.mutantCount, 'mutant')} in '
    '${_count(plan.fileCount, 'file')} — baseline '
    '${_formatSeconds(plan.baseline)}, ${_budgetPhrase(plan.budget)}',
  );
  // Both ends, because one number alone would be read as the answer and
  // neither is: the floor assumes every worker busy on a mutant that costs
  // a full baseline, the top assumes one worker doing all of them. What the
  // run actually costs depends on how many candidates the gate rejects for
  // free and how much a selected command saves, and nothing knows that
  // until mutants have run — which the `left` on each progress line then
  // reports from measurement rather than assumption.
  final String span = plan.workers > 1
      ? '${formatWait(plan.floor)} to ${formatWait(plan.estimate)}'
      : 'about ${formatWait(plan.estimate)}';
  stdout.writeln(
    'at one baseline per mutant across ${_count(plan.workers, 'worker')} '
    'that is $span — an upper bound; the per-mutant `left` below measures '
    'the real pace',
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
