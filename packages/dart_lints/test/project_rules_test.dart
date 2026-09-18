import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:dart_lints/dart_lints.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A rule of a project's own, of the shape one would really write: it lives
/// outside this package and reaches the run only by being handed in.
class _NoShouting extends LintRule {
  @override
  String get name => 'no_shouting';

  @override
  String get description => 'A class name must not be written in capitals.';

  @override
  LintVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _ShoutingVisitor(filePath, lineInfo, source);
}

class _ShoutingVisitor extends LintVisitor {
  _ShoutingVisitor(super.filePath, super.lineInfo, super.source);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final String name = node.name.lexeme;
    if (name == name.toUpperCase()) {
      report(
        ruleName: 'no_shouting',
        message: '$name is shouting.',
        offset: node.name.offset,
      );
    }
  }
}

RuleDescriptor _descriptor({String name = 'no_shouting'}) => RuleDescriptor(
  name: name,
  bundle: 'app',
  create: (Map<String, Object?> options) => _NoShouting(),
);

const String _config = '''
analyzer:
  command: none
exclude: []
coverageIgnore: []
bundles: [app]
areas:
  production:
    paths: ["lib/**"]
''';

void main() {
  test('[partition] a project rule is registered, enabled by its own bundle, '
      'and reports on the project\'s files', () async {
    final Directory root = Directory.systemTemp.createTempSync(
      'dart_lints_project_rules_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    File(p.join(root.path, 'lib', 'fixture.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('class HTML {}\nclass Quiet {}\n');
    final String configPath = p.join(root.path, 'dart_lints.yaml');
    File(configPath).writeAsStringSync(_config);

    final RuleRegistry registry = RuleRegistry(
      extraRules: <RuleDescriptor>[_descriptor()],
    );
    expect(registry.bundleNames, contains('app'));
    expect(registry.byName('no_shouting'), isNotNull);

    final DartLintsConfig config = DartLintsConfigLoader(
      registry,
      const SystemFileSystemProbe(),
    ).load(configPath);
    final StringBuffer sink = StringBuffer();
    final LintRunResult result = await LintRunner(
      config: config,
      registry: registry,
      resolver: AreaResolver(config.areas, rootDirectory: config.rootDirectory),
      analyzer: StockAnalyzerRunner(
        const SystemProcessRunner(),
        out: sink,
        err: sink,
      ),
      reporter: ViolationReporter(sink, err: sink),
    ).run(paths: const <String>[], fix: false, skipAnalyze: true);

    expect(
      result.violations.map((LintViolation v) => v.ruleName),
      <String>['no_shouting'],
    );
    expect(result.violations.single.message, contains('HTML'));
  });

  test('[error] a project rule may not take a built-in rule\'s name', () {
    expect(
      () => RuleRegistry(
        extraRules: <RuleDescriptor>[_descriptor(name: 'avoid_bare_catch')],
      ),
      throwsA(
        isA<DartLintsConfigException>().having(
          (DartLintsConfigException e) => e.message,
          'message',
          contains('avoid_bare_catch'),
        ),
      ),
    );
  });

  test('[state] without the project rule, its bundle is not a bundle at all '
      '— a config naming it fails rather than passing inert', () {
    final RuleRegistry registry = RuleRegistry();
    expect(registry.bundleNames, isNot(contains('app')));
    expect(registry.byName('no_shouting'), isNull);
  });
}
