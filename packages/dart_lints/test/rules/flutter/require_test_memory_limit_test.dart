import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:dart_lints/src/lint_rule_base.dart';
import 'package:dart_lints/src/rules/flutter/require_test_memory_limit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _flutterTest = '''
import 'package:flutter_test/flutter_test.dart';

void main() {}
''';

const String _limitingConfig = '''
import 'dart:async';

import 'package:test_memory_limit/test_memory_limit.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await limitMemory();
  await testMain();
}
''';

/// A package on disk: [files] maps a path relative to the package root to
/// its contents. A `pubspec.yaml` is added.
Directory _package(Map<String, String> files) {
  final Directory root = Directory.systemTemp.createTempSync(
    'require_test_memory_limit_',
  );
  addTearDown(() => root.deleteSync(recursive: true));
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: subject\n');
  for (final MapEntry<String, String> file in files.entries) {
    File(p.join(root.path, file.key))
      ..createSync(recursive: true)
      ..writeAsStringSync(file.value);
  }
  return root;
}

/// Lints each of [paths] in [root] with one rule instance, as the runner
/// does for an area.
Future<List<LintViolation>> _lint(Directory root, List<String> paths) async {
  final AnalysisContextCollection collection = AnalysisContextCollection(
    includedPaths: <String>[root.path],
  );
  final RequireTestMemoryLimit rule = RequireTestMemoryLimit();
  final List<LintViolation> violations = <LintViolation>[];
  for (final String path in paths) {
    final String subject = p.join(root.path, path);
    final SomeResolvedUnitResult result = await collection
        .contextFor(subject)
        .currentSession
        .getResolvedUnit(subject);
    if (result is! ResolvedUnitResult) {
      fail('$path did not resolve, so the rule would report nothing');
    }
    final ResolvedLintVisitor visitor = rule.createResolvedVisitor(
      path,
      result,
    );
    result.unit.accept(visitor);
    violations.addAll(visitor.violations);
  }
  return violations;
}

void main() {
  test('reports a Flutter test file with no config above it', () async {
    final Directory root = _package(<String, String>{
      'test/a/widget_test.dart': _flutterTest,
    });

    final List<LintViolation> violations = await _lint(root, <String>[
      'test/a/widget_test.dart',
    ]);

    expect(violations, hasLength(1));
    expect(violations.single.ruleName, 'require_test_memory_limit');
    expect(violations.single.line, 1);
    expect(violations.single.message, contains('No flutter_test_config.dart'));
  });

  test('passes a test file covered by a config further up', () async {
    final Directory root = _package(<String, String>{
      'test/flutter_test_config.dart': _limitingConfig,
      'test/a/b/widget_test.dart': _flutterTest,
    });

    expect(
      await _lint(root, <String>['test/a/b/widget_test.dart']),
      isEmpty,
    );
  });

  test('accepts limitMemory through an import prefix', () async {
    final Directory root = _package(<String, String>{
      'test/flutter_test_config.dart': _limitingConfig
          .replaceFirst("limit.dart';", "limit.dart' as memory;")
          .replaceFirst('await limitMemory()', 'await memory.limitMemory()'),
      'test/widget_test.dart': _flutterTest,
    });

    expect(await _lint(root, <String>['test/widget_test.dart']), isEmpty);
  });

  test('reports when the nearest config does not call limitMemory', () async {
    // flutter test uses only the nearest config, so the one in test/ that
    // does call it never runs for test/a/.
    final Directory root = _package(<String, String>{
      'test/flutter_test_config.dart': _limitingConfig,
      'test/a/flutter_test_config.dart': '''
import 'dart:async';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await testMain();
}
''',
      'test/a/widget_test.dart': _flutterTest,
      'test/other_test.dart': _flutterTest,
    });

    final List<LintViolation> violations = await _lint(root, <String>[
      'test/a/widget_test.dart',
      'test/other_test.dart',
    ]);

    expect(violations.map((LintViolation v) => v.filePath), <String>[
      'test/a/widget_test.dart',
    ]);
    expect(
      violations.single.message,
      contains(
        'test/a/flutter_test_config.dart is the config flutter test '
        "uses for this file, and it doesn't call limitMemory()",
      ),
    );
  });

  test(
    'reports a config that calls limitMemory without importing it',
    () async {
      final Directory root = _package(<String, String>{
        'test/flutter_test_config.dart': _limitingConfig.replaceFirst(
          "import 'package:test_memory_limit/test_memory_limit.dart';",
          "import 'helpers.dart';",
        ),
        'test/widget_test.dart': _flutterTest,
      });

      expect(
        await _lint(root, <String>['test/widget_test.dart']),
        hasLength(1),
      );
    },
  );

  test(
    'reports a config that calls limitMemory outside testExecutable',
    () async {
      final Directory root = _package(<String, String>{
        'test/flutter_test_config.dart': '''
import 'dart:async';

import 'package:test_memory_limit/test_memory_limit.dart';

Future<void> unused() => limitMemory();

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await testMain();
}
''',
        'test/widget_test.dart': _flutterTest,
      });

      expect(
        await _lint(root, <String>['test/widget_test.dart']),
        hasLength(1),
      );
    },
  );

  test(
    'leaves alone what flutter_test_config.dart does not apply to',
    () async {
      final Directory root = _package(<String, String>{
        // Runs under `dart test`, which never reads the config.
        'test/pure_test.dart': '''
import 'package:test/test.dart';

void main() {}
''',
        // Runs on a device.
        'integration_test/app_test.dart': _flutterTest,
        // Not a test file.
        'test/helpers.dart': _flutterTest,
      });

      expect(
        await _lint(root, <String>[
          'test/pure_test.dart',
          'integration_test/app_test.dart',
          'test/helpers.dart',
        ]),
        isEmpty,
      );
    },
  );
}
