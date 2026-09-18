import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:dart_lints/src/lint_rule_base.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A throwaway package named `subject` to run a naming rule against, so a rule
/// can be asked about real source rather than a hand-built AST.
///
/// The package config is written by hand, which is what makes `lib/` files
/// resolve as `package:subject/…` without a `pub get`; the fixtures import
/// nothing outside `dart:core`, and declare stand-ins for any framework type a
/// rule looks up by name.
class NamingFixture {
  NamingFixture() : root = Directory.systemTemp.createTempSync('naming_') {
    addTearDown(() => root.deleteSync(recursive: true));
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync(
      'name: subject\nenvironment:\n  sdk: ^3.8.0\n',
    );
    File(p.join(root.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"configVersion": 2, "packages": [{"name": "subject", '
        '"rootUri": "../", "packageUri": "lib/", "languageVersion": "3.8"}]}',
      );
  }

  final Directory root;

  /// What [rule] reports on [source], written to [path] under the package.
  Future<List<LintViolation>> resolved(
    ResolvedLintRule rule,
    String source, {
    String path = 'lib/subject.dart',
  }) async {
    final String file = _write(path, source);
    final AnalysisContextCollection collection = AnalysisContextCollection(
      includedPaths: <String>[root.path],
    );
    addTearDown(collection.dispose);
    final SomeResolvedUnitResult result = await collection
        .contextFor(file)
        .currentSession
        .getResolvedUnit(file);
    if (result is! ResolvedUnitResult) {
      fail('fixture did not resolve — the rule would report nothing');
    }
    final List<String> errors = <String>[
      for (final Diagnostic d in result.diagnostics)
        if (d.diagnosticCode.severity == DiagnosticSeverity.ERROR) d.message,
    ];
    if (errors.isNotEmpty) {
      fail('fixture does not compile: $errors');
    }
    final ResolvedLintVisitor visitor = rule.createResolvedVisitor(
      path,
      result,
    );
    result.unit.accept(visitor);
    return visitor.violations;
  }

  /// What [rule] reports on [source], parsed as if it sat at [path].
  List<LintViolation> parsed(
    LintRule rule,
    String source, {
    String path = 'lib/subject.dart',
  }) {
    final ParseStringResult result = parseString(content: source);
    final LintVisitor visitor = rule.createVisitor(
      path,
      result.lineInfo,
      source,
    );
    result.unit.accept(visitor);
    return visitor.violations;
  }

  String _write(String path, String source) {
    final File file = File(p.join(root.path, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(source);
    return file.path;
  }
}

/// The names reported, as the line each report points at reads: the lint
/// anchors every report on a declaration's name, so the declared name is on
/// that line.
Set<String> reportedNames(List<LintViolation> violations, String source) {
  final List<String> lines = source.split('\n');
  return <String>{
    for (final LintViolation v in violations)
      RegExp(
        r'[A-Za-z_$][A-Za-z0-9_$]*',
      ).allMatches(lines[v.line - 1].substring(v.column - 1)).first[0]!,
  };
}
