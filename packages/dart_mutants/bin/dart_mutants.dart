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
          'Seconds a single mutant\'s test run gets before it is killed and '
          'scored as a timeout instead of waited on forever. Applied to the '
          'baseline check too.',
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
/// syntax, `--help`, no files, a malformed `--mutant-timeout` — having
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

  final int? timeoutSeconds = int.tryParse(args['mutant-timeout'] as String);
  if (timeoutSeconds == null || timeoutSeconds <= 0) {
    stderr.writeln('--mutant-timeout must be a positive number of seconds');
    exitCode = 64;
    return null;
  }

  return args;
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
        '  undetected: ${r.mutant.operatorName} at '
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
