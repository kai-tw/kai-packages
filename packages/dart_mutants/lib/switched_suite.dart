/// What a compiled test entry calls to run one test file the way
/// `dart test` or `flutter test` would, inside the program dart_mutants
/// compiled for it. Not meant to be imported by anything else.
///
/// It reads the same configuration the test runner does — the global file,
/// the package's `dart_test.yaml` and the test command's own filtering
/// options — and the test file's suite-level annotations (`@Tags`,
/// `@Timeout`, `@Skip`, `@TestOn`, `@OnPlatform`), so a test skipped or
/// filtered out under the test command is skipped or filtered out here too.
/// A mutant scored here is scored against the tests the command would run,
/// no more and no fewer.
///
/// It reaches into `package:test_core`'s and `package:test_api`'s own
/// libraries, which are not a public interface. A release of either that
/// changes them breaks the compile of every entry, and the run stops before
/// the first mutant saying so; it never scores against the wrong tests.
library;

import 'dart:async';
import 'dart:io';

import 'package:test_api/backend.dart';
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/invoker.dart';
import 'package:test_api/src/backend/test.dart';
import 'package:test_core/src/runner/configuration.dart';
import 'package:test_core/src/runner/engine.dart';
import 'package:test_core/src/runner/parse_metadata.dart';
import 'package:test_core/src/runner/plugin/environment.dart';
import 'package:test_core/src/runner/runner_suite.dart';
import 'package:test_core/src/runner/suite.dart';
import 'package:test_core/src/util/os.dart';

/// Runs [testMain], the `main` of the test file at [path] (relative to the
/// working directory, the package), and exits: 0 when every test that ran
/// passed, 1 when one did not. [arguments] are the test command's own
/// filtering options, such as `--tags` or `--plain-name`.
Future<Never> runSwitchedSuite(
  FutureOr<void> Function() testMain, {
  required String path,
  List<String> arguments = const <String>[],
}) async {
  final bool passed = await switchedSuitePasses(
    testMain,
    path: path,
    arguments: arguments,
  );
  exit(passed ? 0 : 1);
}

/// [runSwitchedSuite] without the exit: whether every test that ran passed.
Future<bool> switchedSuitePasses(
  FutureOr<void> Function() testMain, {
  required String path,
  List<String> arguments = const <String>[],
}) async {
  final Configuration config = switchedConfiguration(arguments);
  final SuitePlatform platform = SuitePlatform(
    Runtime.vm,
    compiler: null,
    os: currentOSGuess,
  );
  final Set<String> variables = <String>{
    for (final Runtime runtime in Runtime.builtIn) runtime.identifier,
  };
  final SuiteConfiguration suite = config.suiteDefaults.merge(
    SuiteConfiguration.fromMetadata(
      parseMetadata(path, File(path).readAsStringSync(), variables),
    ),
  );
  // As the test runner's loader decides whether to load a file at all.
  if (config.excludeTags.evaluate(suite.metadata.tags.contains) ||
      !suite.metadata.testOn.evaluate(platform)) {
    return true;
  }
  final SuiteConfiguration onPlatform = suite.forPlatform(platform);
  if (onPlatform.metadata.skip && !onPlatform.runSkipped) {
    return true;
  }
  final Declarer declarer = Declarer(
    metadata: onPlatform.metadata,
    platformVariables: variables,
    noRetry: config.noRetry,
    allowDuplicateTestNames: onPlatform.allowDuplicateTestNames,
  );
  await declarer.declare(testMain);
  final RunnerSuite runnable = RunnerSuite(
    const PluginEnvironment(),
    onPlatform,
    declarer.build(),
    platform,
    path: path,
  ).filter((Test test) => _selected(config, test));
  // No reporter: only the exit code is read, and the reporters' own
  // constructors are what changes most between releases.
  final Engine engine = Engine()
    ..suiteSink.add(runnable)
    ..suiteSink.close();
  final Future<bool?>? running = runZoned<Future<bool?>?>(
    () => Invoker.guard<Future<bool?>>(engine.run),
    zoneValues: <Object, Object>{#test.declarer: declarer},
  );
  return (await running) ?? false;
}

/// The configuration `dart test` would run with in the working directory:
/// the global file, then `dart_test.yaml`, then [arguments] over both.
Configuration switchedConfiguration(List<String> arguments) {
  final Configuration given = Configuration.parse(arguments);
  Configuration files = Configuration.empty;
  final String global =
      Platform.environment['DART_TEST_CONFIG'] ??
      '${Platform.environment['HOME']}/.dart_test.yaml';
  if (File(global).existsSync()) {
    files = files.merge(Configuration.load(global, global: true));
  }
  if (File(given.configurationPath).existsSync()) {
    files = files.merge(Configuration.load(given.configurationPath));
  }
  return files.merge(given);
}

/// Whether [test] runs under [config]'s name and tag filters, as the test
/// runner decides it.
bool _selected(Configuration config, Test test) =>
    config.globalPatterns.every(
      (Pattern pattern) => test.name.contains(pattern),
    ) &&
    config.includeTags.evaluate(test.metadata.tags.contains) &&
    !config.excludeTags.evaluate(test.metadata.tags.contains);
