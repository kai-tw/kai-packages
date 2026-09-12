import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../mutant.dart';
import 'coverage_map.dart';
import 'line_range.dart';
import 'mutant_scope.dart';
import 'process_command.dart';
import 'test_invocation.dart';

/// A [CoverageMap] and the invocation it was collected through: together,
/// how to run only the tests that cover a given mutant.
class TestSelection {
  TestSelection(this.invocation, this.map)
    : _root = _resolved(p.absolute(invocation.root));

  final TestInvocation invocation;
  final CoverageMap map;
  final String _root;

  /// The command for [mutant], whose enclosing function spans [scope] (see
  /// [executableScope]), or `null` to mean no test enters that function and
  /// the mutant needs no run at all. [fullCommand] when there is no scope,
  /// or coverage says nothing about it.
  ProcessCommand? commandFor(
    Mutant mutant,
    LineRange? scope,
    ProcessCommand fullCommand,
  ) {
    if (scope == null) {
      return fullCommand;
    }
    final String file = p.posix.joinAll(
      p.split(
        p.relative(_resolved(p.absolute(mutant.filePath)), from: _root),
      ),
    );
    final Set<String>? tests = map.testsFor(file, scope.start, scope.end);
    if (tests == null) {
      return fullCommand;
    }
    if (tests.isEmpty) {
      return null;
    }
    return invocation.withTestFiles(tests.toList()..sort());
  }

  /// Whether this coverage can speak for a file whose content is [source].
  /// `flutter test` deletes lines under `// coverage:ignore-…` from its
  /// report, which can remove a function's entry line and keep zero-hit
  /// lines of its body — an unentered reading for a function that ran.
  bool speaksFor(String source) =>
      invocation.runner == TestRunner.dart ||
      !source.contains('coverage:ignore');

  /// [path] with symlinks resolved when it exists — `/tmp` against
  /// `/private/tmp` on macOS would otherwise miss every key, silently.
  static String _resolved(String path) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      return p.normalize(path);
    }
    return type == FileSystemEntityType.directory
        ? Directory(path).resolveSymbolicLinksSync()
        : File(path).resolveSymbolicLinksSync();
  }
}

/// Runs the coverage pass: every test file of [invocation], with coverage
/// on. `dart test` reports per test file from a single run; `flutter test`
/// writes one combined report per run, so it gets one run per test file.
///
/// Returns `null`, with the reason passed to [onFailure], when the pass
/// cannot give a trustworthy answer — the caller then runs every mutant
/// against the full command, which is always sound, only slower.
Future<TestSelection?> collectCoverage(
  TestInvocation invocation, {
  required Duration timeout,
  required void Function(String reason) onFailure,
}) async {
  final String? packageName = _packageName(invocation.root);
  final List<String> testFiles = invocation.testFiles();
  final String? problem = _refusal(invocation, packageName, testFiles);
  if (problem != null) {
    onFailure(problem);
    return null;
  }
  final Directory out = Directory.systemTemp.createTempSync(
    'dart_mutants_cov_',
  );
  try {
    final CoverageMapBuilder builder = CoverageMapBuilder(invocation.root);
    final String? failure = switch (invocation.runner) {
      TestRunner.dart => await _collectDart(
        invocation,
        testFiles,
        out,
        packageName!,
        builder,
        timeout,
      ),
      TestRunner.flutter => await _collectFlutter(
        invocation,
        testFiles,
        out,
        builder,
        timeout,
      ),
    };
    if (failure != null) {
      onFailure(failure);
      return null;
    }
    return TestSelection(invocation, builder.build());
    // A report in a shape this does not expect is a reason to fall back,
    // not to crash after the baseline and print no report at all.
  } on FormatException catch (e) {
    onFailure('its coverage report could not be read ($e)');
    return null;
  } finally {
    out.deleteSync(recursive: true);
  }
}

/// Why this invocation cannot be selected from at all, or `null`. Every
/// refusal is a shape in which the coverage pass could see different tests
/// than the full command runs — and a selected run could then detect a
/// mutant the full command misses, or read a reached function as unentered.
String? _refusal(
  TestInvocation invocation,
  String? packageName,
  List<String> testFiles,
) {
  if (packageName == null) {
    return 'no pubspec.yaml with a name in ${invocation.root}';
  }
  if (testFiles.isEmpty) {
    return 'the test command names no *_test.dart files';
  }
  return _commandRefusal(invocation) ??
      _configRefusal(invocation) ??
      (invocation.runner == TestRunner.flutter &&
              _importsLibByPath(invocation.root, testFiles)
          ? 'a test imports lib/ by relative path, whose coverage '
                '`flutter test` does not report'
          : null);
}

String? _commandRefusal(TestInvocation invocation) {
  if (invocation.hasOptionTerminator) {
    return 'the test command uses `--`';
  }
  if (invocation.setsCoverage) {
    return 'the test command already collects coverage';
  }
  if (invocation.runsOffTheVm) {
    return 'the test command runs on a platform other than the VM';
  }
  if (invocation.unrecognised.isNotEmpty) {
    return 'the test command has arguments this cannot place: '
        '${invocation.unrecognised.join(' ')}';
  }
  return null;
}

/// `dart_test.yaml` keys that change which files run, or where. `paths`
/// only matters when the command names none of its own.
String? _configRefusal(TestInvocation invocation) {
  final File config = File(p.join(invocation.root, 'dart_test.yaml'));
  if (!config.existsSync()) {
    return null;
  }
  final String keys = invocation.paths.isEmpty
      ? 'paths|filename|include|platforms|override_platforms|define_platforms'
      : 'filename|include|platforms|override_platforms|define_platforms';
  final RegExpMatch? match = RegExp(
    '^\\s*($keys)\\s*:',
    multiLine: true,
  ).firstMatch(config.readAsStringSync());
  return match == null ? null : 'dart_test.yaml sets ${match.group(1)}';
}

/// Whether any test file, or anything under `test/`, imports or exports a
/// file in `lib/` by path rather than as `package:`. Such a library loads
/// under a `file:` URI, which a `--coverage-package` filter drops — and if the
/// same file also loads as `package:`, that copy reports zero and the
/// function reads as unentered.
bool _importsLibByPath(String root, List<String> testFiles) {
  final String lib = p.join(p.normalize(p.absolute(root)), 'lib');
  return _testSideDartFiles(
    root,
    testFiles,
  ).any((String file) => _importsInto(file, lib));
}

/// The given test files, and every Dart file under `test/` — a helper there
/// can import `lib/` on a test's behalf.
Set<String> _testSideDartFiles(String root, List<String> testFiles) {
  final Directory testDir = Directory(p.join(root, 'test'));
  return <String>{
    for (final String f in testFiles) p.normalize(p.absolute(root, f)),
    if (testDir.existsSync())
      for (final FileSystemEntity e in testDir.listSync(recursive: true))
        if (e is File && e.path.endsWith('.dart')) p.normalize(e.absolute.path),
  };
}

final RegExp _directive = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Whether [file] imports or exports anything inside [dir] by path.
bool _importsInto(String file, String dir) =>
    _directive.allMatches(File(file).readAsStringSync()).any((RegExpMatch m) {
      final String uri = m.group(1)!;
      return !uri.contains(':') &&
          p.isWithin(dir, p.normalize(p.join(p.dirname(file), uri)));
    });

/// One `dart test --coverage` run; `null` on success, else why not.
///
/// Scoped with `--coverage-package` where the installed `package:test`
/// supports it — without it every loaded library of every dependency is
/// collected, per suite — and retried without it where it does not. Not
/// scoped at all when a test imports `lib/` by path: the filter would drop
/// that `file:` copy's hits (see [_importsLibByPath]).
Future<String?> _collectDart(
  TestInvocation invocation,
  List<String> testFiles,
  Directory out,
  String packageName,
  CoverageMapBuilder builder,
  Duration timeout,
) async {
  final bool scoped = !_importsLibByPath(invocation.root, testFiles);
  int? exit = await invocation
      .withTestFiles(
        testFiles,
        extra: <String>[
          '--coverage=${out.path}',
          if (scoped) '--coverage-package=^$packageName\$',
        ],
      )
      .run(timeout: timeout);
  if (scoped && exit == 64) {
    exit = await invocation
        .withTestFiles(testFiles, extra: <String>['--coverage=${out.path}'])
        .run(timeout: timeout);
  }
  if (exit != 0) {
    return _failed(exit, 'dart test --coverage');
  }
  int read = 0;
  for (final String testFile in testFiles) {
    // A suite that never loads on this platform (`@TestOn`, `@Skip`) writes
    // no report. It does not run under the full command either, so leaving
    // it out can only ever leave lines unanswered, never make one uncovered.
    final File report = File(p.join(out.path, '$testFile.vm.json'));
    if (report.existsSync()) {
      builder.addDartSuite(
        testFile,
        jsonDecode(report.readAsStringSync()),
        packageName,
      );
      read++;
    }
  }
  // None at all means the reports went somewhere this does not look, and
  // every mutant would run in full while the report claimed selection.
  return read == 0
      ? 'dart test wrote no coverage reports where expected'
      : null;
}

/// One `flutter test --coverage` run per test file; `null` on success, else
/// why not.
Future<String?> _collectFlutter(
  TestInvocation invocation,
  List<String> testFiles,
  Directory out,
  CoverageMapBuilder builder,
  Duration timeout,
) async {
  for (int i = 0; i < testFiles.length; i++) {
    final File lcov = File(p.join(out.path, '$i.info'));
    final int? exit = await invocation
        .withTestFiles(
          <String>[testFiles[i]],
          extra: <String>['--coverage', '--coverage-path=${lcov.path}'],
        )
        .run(timeout: timeout);
    if (exit == _noTestsRan) {
      // Declares no test, or none the command's filters keep: it cannot
      // fail a test in the full command either, so it reaches nothing.
      continue;
    }
    if (exit != 0 || !lcov.existsSync()) {
      return _failed(exit, 'flutter test --coverage ${testFiles[i]}');
    }
    builder.addLcov(testFiles[i], lcov.readAsStringSync());
  }
  return null;
}

/// `dart test` and `flutter test` both exit with this when no test ran.
const int _noTestsRan = 79;

String _failed(int? exit, String what) => exit == null
    ? '$what did not finish within the baseline timeout — raise '
          '--baseline-timeout if the suite is merely slow with coverage on'
    : '$what exited $exit';

String? _packageName(String root) {
  final File pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    return null;
  }
  return RegExp(
    r'^name:\s*([A-Za-z0-9_]+)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync())?.group(1);
}
