import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_command.dart';

/// The two test runners this package knows how to run a chosen subset of
/// test files with, and collect per-file coverage from.
enum TestRunner { dart, flutter }

/// A `--test-command` taken apart into what selecting tests needs: which
/// runner, which flags to keep, and which test files it covers.
///
/// Only `dart test …` and `flutter test …` are understood. Anything else — a
/// wrapper script, `fvm flutter test` — is left alone: [parse] returns
/// `null`, and the caller runs the command as given, as it always has.
class TestInvocation {
  TestInvocation._(this.runner, this._command) {
    _split();
  }

  /// `null` when [command] is not a recognisable `dart test` or
  /// `flutter test`.
  ///
  /// An argument counts as a test path when it does not start with `-`, is
  /// not the value of an option known to take one, and exists under the
  /// working directory. The option list is what `dart test` and
  /// `flutter test` document; an unlisted option whose value happens to name
  /// an existing path would be misread as one.
  static TestInvocation? parse(ProcessCommand command) {
    final TestRunner? runner = _runnerOf(command);
    return runner == null ? null : TestInvocation._(runner, command);
  }

  static TestRunner? _runnerOf(ProcessCommand command) {
    if (command.arguments.isEmpty || command.arguments.first != 'test') {
      return null;
    }
    return switch (p.basename(command.executable)) {
      'dart' => TestRunner.dart,
      'flutter' => TestRunner.flutter,
      _ => null,
    };
  }

  static const Set<String> _valueOptions = <String>{
    '-n',
    '--name',
    '-N',
    '--plain-name',
    '-t',
    '--tags',
    '-x',
    '--exclude-tags',
    '-j',
    '--concurrency',
    '-p',
    '--platform',
    '-r',
    '--reporter',
    '--file-reporter',
    '--timeout',
    '--total-shards',
    '--shard-index',
    '-P',
    '--preset',
    '--test-randomize-ordering-seed',
    '--coverage-path',
    '--dart-define',
    '--dart-define-from-file',
    '--flavor',
    '-d',
    '--device-id',
    '-c',
    '--compiler',
    '--packages',
    '--enable-experiment',
    '--dds-port',
    '--local-engine',
    '--local-engine-src-path',
    '--local-engine-host',
    // A value option for `dart test`, a flag for `flutter test` — either
    // way [setsCoverage] refuses the command, so the difference never
    // matters here.
    '--coverage',
    '--coverage-package',
  };

  static const Set<String> _coverageOptions = <String>{
    '--coverage',
    '--coverage-path',
    '--coverage-package',
    '--merge-coverage',
    '--branch-coverage',
  };

  /// Whether the command collects coverage itself — which the coverage pass
  /// cannot add to without the two fighting over where it goes.
  bool get setsCoverage => _command.arguments.any(
    (String arg) => _coverageOptions.contains(arg.split('=').first),
  );

  /// Whether the command uses `--` to end its options, after which this
  /// class cannot tell what anything means.
  bool get hasOptionTerminator => _command.arguments.contains('--');

  /// Whether the command runs on any platform but the VM — whose suites
  /// write no VM coverage, so lines only they reach would read as unhit.
  bool get runsOffTheVm {
    final List<String> args = _command.arguments;
    for (int i = 0; i < args.length; i++) {
      final String arg = args[i];
      final String? value = arg == '-p' || arg == '--platform'
          ? (i + 1 < args.length ? args[i + 1] : null)
          : arg.startsWith('--platform=')
          ? arg.substring('--platform='.length)
          : null;
      if (value != null && value.split(',').any((String v) => v != 'vm')) {
        return true;
      }
    }
    return false;
  }

  final TestRunner runner;
  final ProcessCommand _command;

  /// Everything after `test` that is not a test path, in order.
  final List<String> flags = <String>[];

  /// As given, relative to the working directory. Empty means the runner's
  /// own default, `test/`.
  final List<String> paths = <String>[];

  /// Positional arguments that are neither a known option's value nor an
  /// existing path — `test/a_test.dart?name=x`, or the value of an option
  /// missing from the known list. Nothing can be selected from a command
  /// this class does not fully understand.
  final List<String> unrecognised = <String>[];

  String get root => _command.workingDirectory ?? Directory.current.path;

  void _split() {
    bool valueExpected = false;
    for (final String arg in _command.arguments.skip(1)) {
      if (valueExpected || arg.startsWith('-')) {
        flags.add(arg);
      } else if (FileSystemEntity.typeSync(p.join(root, arg)) ==
          FileSystemEntityType.notFound) {
        flags.add(arg);
        unrecognised.add(arg);
      } else {
        paths.add(arg);
      }
      valueExpected =
          !valueExpected && !arg.contains('=') && _valueOptions.contains(arg);
    }
  }

  /// Every `*_test.dart` file this invocation runs, relative to [root],
  /// sorted.
  List<String> testFiles() {
    final Set<String> files = <String>{};
    for (final String path in paths.isEmpty ? const <String>['test'] : paths) {
      final String absolute = p.normalize(p.join(root, path));
      if (!FileSystemEntity.isDirectorySync(absolute)) {
        // Relative even when given absolute: the coverage pass finds each
        // file's report under this same relative path.
        files.add(p.relative(absolute, from: root));
        continue;
      }
      // `flutter test` does not follow symlinked directories when it looks
      // for tests; walking into one would select a file it never runs.
      for (final FileSystemEntity e in Directory(absolute).listSync(
        recursive: true,
        followLinks: runner == TestRunner.dart,
      )) {
        if (e is File && e.path.endsWith('_test.dart')) {
          files.add(p.relative(e.path, from: root));
        }
      }
    }
    return files.toList()..sort();
  }

  /// The same command, restricted to [testFiles], with [extra] flags added.
  ProcessCommand withTestFiles(
    Iterable<String> testFiles, {
    List<String> extra = const <String>[],
  }) => ProcessCommand(
    _command.executable,
    <String>['test', ...flags, ...extra, ...testFiles],
    workingDirectory: _command.workingDirectory,
  );
}
