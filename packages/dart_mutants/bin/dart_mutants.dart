import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_mutants/src/runner/compile_safety_gate.dart';
import 'package:dart_mutants/src/runner/file_mutation_report.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutation_run_report.dart';
import 'package:dart_mutants/src/runner/mutation_test_runner.dart';
import 'package:dart_mutants/src/runner/process_command.dart';

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
    ..addFlag('json', help: 'Emit the report as JSON instead of text.')
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
  if (args['json'] as bool) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  } else {
    _printText(report);
  }

  if (report.aborted) {
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

  final String? timeoutError = _timeoutOptionError(args);
  if (timeoutError != null) {
    stderr.writeln(timeoutError);
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

bool _isPositiveSeconds(String value) {
  final int? seconds = int.tryParse(value);
  return seconds != null && seconds > 0;
}

Duration? _optionalSeconds(String? value) =>
    value == null ? null : Duration(seconds: int.parse(value));

/// `4`, not `4.0`, in `--help`.
String _formatFactor(double factor) => factor == factor.truncateToDouble()
    ? factor.toInt().toString()
    : factor.toString();

String _formatSeconds(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

/// What every mutant's timeout was measured against — see
/// MutationTestRunner.baselineFactor.
void _printBudget(MutationRunReport report) {
  final Duration? baseline = report.baselineDuration;
  final Duration? budget = report.mutantTimeout;
  if (baseline != null && budget != null) {
    stdout.writeln(
      'baseline ${_formatSeconds(baseline)}, each mutant given '
      '${_formatSeconds(budget)}',
    );
  }
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
    for (final MutantResult r in f.timedOutMutants) {
      stdout.writeln(
        '  timed out (NOT scored): ${r.mutant.operatorName} at '
        '${f.filePath}:${r.mutant.line}:${r.mutant.column} — '
        '${r.mutant.description}',
      );
    }
  }
}
