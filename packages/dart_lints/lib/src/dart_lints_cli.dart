import 'dart:io';

import 'area_resolver.dart';
import 'config/area.dart';
import 'config/dart_lints_config.dart';
import 'config/dart_lints_config_exception.dart';
import 'config/dart_lints_config_loader.dart';
import 'config/file_system_probe.dart';
import 'lint_run_result.dart';
import 'lint_runner.dart';
import 'process_runner.dart';
import 'rule_descriptor.dart';
import 'rule_registry.dart';
import 'stock_analyzer_runner.dart';
import 'violation_reporter.dart';

/// The whole command, as a class a project can call with rules of its own.
///
/// `bin/dart_lints.dart` is one line over this. A project that owns rules
/// writes its own entry point — Dart links what it compiles, so a rule
/// outside this package cannot be loaded into this package's binary — and
/// passes them in:
///
/// ```dart
/// // tool/lint.dart, in the project
/// import 'package:dart_lints/dart_lints.dart';
/// import 'lint_rules/analytics_param_namespace.dart';
///
/// Future<void> main(List<String> args) => DartLintsCli(
///   extraRules: <RuleDescriptor>[
///     RuleDescriptor(
///       name: 'analytics_param_namespace',
///       bundle: 'app',
///       create: (Map<String, Object?> o) => AnalyticsParamNamespace(),
///     ),
///   ],
/// ).run(args);
/// ```
///
/// Run as `dart run tool/lint.dart`, with the same arguments and the same
/// `dart_lints.yaml`; the project's rules are enabled by their bundle or by
/// name, and their options are validated like any other rule's.
class DartLintsCli {
  DartLintsCli({
    List<RuleDescriptor> extraRules = const <RuleDescriptor>[],
    this.name = 'dart_lints',
  }) : registry = RuleRegistry(extraRules: extraRules);

  final RuleRegistry registry;

  /// How the command calls itself in `--help` and in its errors. A project's
  /// own entry point is not run as `dart run dart_lints`, so saying so would
  /// send a reader to a command that does not have their rules.
  final String name;

  /// Runs the command and ends the process, the way a `main` does.
  Future<void> run(List<String> args) async {
    if (args.contains('--help') || args.contains('-h')) {
      stdout.write(usage);
      return;
    }

    final String? areaArg = _valueOf(args, '--area=');
    final DartLintsConfig config = _load(_valueOf(args, '--config='));
    if (areaArg != null && !config.areas.any((Area a) => a.name == areaArg)) {
      stderr.writeln(
        '$name: unknown area "$areaArg" — declared areas are '
        '${config.areas.map((Area a) => a.name).join(', ')}.',
      );
      exit(2);
    }

    final bool skipAnalyze = args.contains('--skip-analyze');
    final ViolationReporter reporter = ViolationReporter(stdout, err: stderr);
    final LintRunResult result =
        await LintRunner(
          config: config,
          registry: registry,
          resolver: AreaResolver(
            config.areas,
            rootDirectory: config.rootDirectory,
          ),
          analyzer: StockAnalyzerRunner(const SystemProcessRunner()),
          reporter: reporter,
        ).run(
          paths: args.where((String a) => !a.startsWith('-')).toList(),
          areaName: areaArg,
          fix: args.contains('--fix'),
          skipAnalyze: skipAnalyze,
        );

    // Violations are printed by the runner as each pass completes, so a
    // project rule that throws cannot take the per-file findings down with it.
    reporter
      ..reportFixes(result.fixedCount)
      ..reportUnresolved(result.unresolvedPaths)
      ..summarise(
        analyzerIssues: result.analyzerIssues,
        customIssues: result.violations.length,
        analyzerRan: !skipAnalyze,
      );

    // An unresolved file is a failure, not a quiet skip: it produced no
    // violations because nothing looked at it, which reads exactly like
    // passing.
    exit(result.isClean ? 0 : 1);
  }

  DartLintsConfig _load(String? configArg) {
    const FileSystemProbe probe = SystemFileSystemProbe();
    final DartLintsConfigLoader loader = DartLintsConfigLoader(registry, probe);
    try {
      return loader.load(configArg ?? loader.discover(Directory.current.path));
    } on DartLintsConfigException catch (e) {
      stderr.writeln(e);
      exit(2);
    }
  }

  String get usage =>
      '''
Usage: dart run $name [path...] [options]

With no path, every area declared in dart_lints.yaml is scanned. A path
restricts the scan; each file's area — and therefore its rules — still comes
from its own location.

Options:
  --config=PATH   Config file to use (default: nearest dart_lints.yaml at or
                  above the working directory)
  --area=NAME     Restrict to one area declared in the config
  --fix           Apply auto-fixes where a rule offers one
  --skip-analyze  Skip the stock analyzer, run custom rules only
  -h, --help      Show this message

Examples:
  dart run $name
  dart run $name --area=test
  dart run $name lib --fix
  dart run $name lib --skip-analyze
''';

  static String? _valueOf(List<String> args, String prefix) => args
      .where((String a) => a.startsWith(prefix))
      .map((String a) => a.substring(prefix.length))
      .firstOrNull;
}
