import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../../lint_rule_base.dart';

/// Requires every Flutter test file under `test/` to be covered by a
/// `flutter_test_config.dart` that calls `limitMemory()` from
/// `package:test_memory_limit`.
///
/// A test stuck in a loop that keeps allocating can take its
/// `flutter_tester` to tens of gigabytes. `limitMemory()` kills the process
/// once it goes over a limit, but only for the test files it's wired into,
/// and `flutter test` wires in only the `flutter_test_config.dart` nearest to
/// each test file: one in the file's own directory, or the closest one above
/// it up to the package root. A nearer config that doesn't call
/// `limitMemory()` hides one further up that does.
///
/// **Good:**
/// ```dart
/// // test/flutter_test_config.dart
/// import 'dart:async';
///
/// import 'package:test_memory_limit/test_memory_limit.dart';
///
/// Future<void> testExecutable(FutureOr<void> Function() testMain) async {
///   await limitMemory();
///   await testMain();
/// }
/// ```
///
/// Only `*_test.dart` files that import `package:flutter_test` and sit under
/// the package's `test/` directory are checked. `integration_test/` runs on a
/// device, where killing the app's process isn't the fix, and `dart test`
/// doesn't read `flutter_test_config.dart` at all.
///
/// It reads the config files from disk, so a test file is checked against
/// the config as it is now, even on a run over that one file.
class RequireTestMemoryLimit extends ResolvedLintRule {
  @override
  String get name => 'require_test_memory_limit';

  @override
  String get description =>
      'Every Flutter test file under test/ is covered by a '
      'flutter_test_config.dart that calls limitMemory().';

  /// The nearest config for each directory looked at, or `null` for none.
  final Map<String, String?> _configFor = <String, String?>{};

  /// Whether each config read calls `limitMemory()`.
  final Map<String, bool> _limits = <String, bool>{};

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(filePath, resolvedUnit, this);

  /// The `flutter_test_config.dart` that `flutter test` would use for a test
  /// in [directory]: the nearest one at or above it, up to and including
  /// [packageRoot].
  String? nearestConfig(String directory, String packageRoot) =>
      _configFor.putIfAbsent(directory, () {
        final String candidate = p.join(directory, _configName);
        if (File(candidate).existsSync()) {
          return candidate;
        }
        if (p.equals(directory, packageRoot)) {
          return null;
        }
        return nearestConfig(p.dirname(directory), packageRoot);
      });

  /// Whether the config at [path] imports `package:test_memory_limit` and
  /// calls `limitMemory()` in its `testExecutable`.
  bool limitsMemory(String path) => _limits.putIfAbsent(path, () {
    final ParseStringResult parsed = parseString(
      content: File(path).readAsStringSync(),
      path: path,
      throwIfDiagnostics: false,
    );
    final CompilationUnit unit = parsed.unit;
    final bool imported = unit.directives.whereType<ImportDirective>().any(
      (ImportDirective d) =>
          d.uri.stringValue?.startsWith('package:test_memory_limit/') ?? false,
    );
    if (!imported) {
      return false;
    }
    for (final FunctionDeclaration function
        in unit.declarations.whereType<FunctionDeclaration>()) {
      if (function.name.lexeme != 'testExecutable') {
        continue;
      }
      final _LimitMemoryCall finder = _LimitMemoryCall();
      function.accept(finder);
      return finder.found;
    }
    return false;
  });

  static const String _configName = 'flutter_test_config.dart';
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(super.filePath, super.resolvedUnit, this.rule);

  final RequireTestMemoryLimit rule;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final String path = resolvedUnit.path;
    if (!path.endsWith('_test.dart')) {
      return;
    }
    final ImportDirective? flutterTest = node.directives
        .whereType<ImportDirective>()
        .where(
          (ImportDirective d) =>
              d.uri.stringValue?.startsWith('package:flutter_test/') ?? false,
        )
        .firstOrNull;
    if (flutterTest == null) {
      return;
    }
    final String? packageRoot = _packageRoot(p.dirname(path));
    if (packageRoot == null || !p.isWithin(p.join(packageRoot, 'test'), path)) {
      return;
    }
    final String? config = rule.nearestConfig(p.dirname(path), packageRoot);
    if (config == null) {
      report(
        ruleName: rule.name,
        message:
            'No flutter_test_config.dart covers this test file, so nothing '
            'stops it if it keeps allocating memory. Add '
            'test/flutter_test_config.dart with a testExecutable that calls '
            "limitMemory() from 'package:test_memory_limit' before "
            'testMain().',
        offset: flutterTest.offset,
      );
    } else if (!rule.limitsMemory(config)) {
      report(
        ruleName: rule.name,
        message:
            '${p.relative(config, from: packageRoot)} is the config '
            "flutter test uses for this file, and it doesn't call "
            "limitMemory() from 'package:test_memory_limit' in its "
            'testExecutable, so nothing stops this test if it keeps '
            'allocating memory.',
        offset: flutterTest.offset,
      );
    }
  }

  /// The nearest directory at or above [directory] with a `pubspec.yaml`.
  static String? _packageRoot(String directory) {
    String current = directory;
    while (!File(p.join(current, 'pubspec.yaml')).existsSync()) {
      final String parent = p.dirname(current);
      if (parent == current) {
        return null;
      }
      current = parent;
    }
    return current;
  }
}

/// Finds a `limitMemory(...)` call, with or without an import prefix.
class _LimitMemoryCall extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'limitMemory') {
      found = true;
    }
    super.visitMethodInvocation(node);
  }
}
