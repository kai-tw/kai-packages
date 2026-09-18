/// Configurable custom Dart lint rules.
///
/// Areas and enabled rules come from a per-repo `dart_lints.yaml`, so adding or
/// removing a rule in a project is a line of configuration rather than a change
/// to this package.
library;

export 'src/area_resolver.dart';
export 'src/built_rules.dart';
export 'src/config/analyzer_spec.dart';
export 'src/config/area.dart';
export 'src/config/area_coverage_check.dart';
export 'src/config/dart_lints_config.dart';
export 'src/config/dart_lints_config_exception.dart';
export 'src/config/dart_lints_config_loader.dart';
export 'src/config/file_system_probe.dart';
export 'src/dart_lints_cli.dart';
export 'src/lint_rule_base.dart';
export 'src/lint_run_result.dart';
export 'src/lint_runner.dart';
export 'src/process_runner.dart';
export 'src/rule_descriptor.dart';
export 'src/rule_registry.dart';
export 'src/stock_analyzer_runner.dart';
export 'src/violation_reporter.dart';
