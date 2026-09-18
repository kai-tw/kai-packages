import 'package:dart_lints/dart_lints.dart';

/// This package's own entry point, with only the rules it ships. A project
/// that owns rules writes its own — see [DartLintsCli].
Future<void> main(List<String> args) => DartLintsCli().run(args);
