import 'dart:io';

import 'package:dart_lints/dart_lints.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Drives `exemptFlatDispatch` through the real `dart_lints.yaml` loader,
/// not just the rule's own unit tests — `avoid_high_cyclomatic_complexity_test.dart`
/// constructs the rule directly, which never exercises `OptionKind.boolean`'s
/// coercion in `DartLintsConfigLoader`. A typo'd YAML value for a boolean
/// option is exactly the shape `RuleDescriptor.options` exists to catch
/// loudly instead of silently miscoercing.
void main() {
  const String flatSwitchFixture = '''
enum E { a, b, c, d, e, f, g, h }

String label(E x) {
  return switch (x) {
    E.a => 'a',
    E.b => 'b',
    E.c => 'c',
    E.d => 'd',
    E.e => 'e',
    E.f => 'f',
    E.g => 'g',
    E.h => 'h',
  };
}
''';

  Directory tempRoot(String prefix) {
    final Directory root = Directory.systemTemp.createTempSync(prefix);
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: myapp\n');
    final Directory libDir = Directory(p.join(root.path, 'lib'))
      ..createSync(recursive: true);
    File(
      p.join(libDir.path, 'fixture.dart'),
    ).writeAsStringSync(flatSwitchFixture);
    return root;
  }

  test(
    'exemptFlatDispatch: true, read from real YAML, suppresses a flat '
    'switch that would otherwise violate maxComplexity',
    () async {
      final Directory root = tempRoot('dart_lints_flat_dispatch_on_');
      addTearDown(() => root.deleteSync(recursive: true));

      const String config = '''
analyzer:
  command: none

enable: [avoid_high_cyclomatic_complexity]

options:
  avoid_high_cyclomatic_complexity:
    maxComplexity: 2
    exemptFlatDispatch: true

areas:
  production:
    paths: ["lib/**"]
''';
      final String configPath = p.join(root.path, 'dart_lints.yaml');
      File(configPath).writeAsStringSync(config);

      final RuleRegistry registry = RuleRegistry();
      final DartLintsConfig loadedConfig = DartLintsConfigLoader(
        registry,
        const SystemFileSystemProbe(),
      ).load(configPath);

      final StringBuffer sink = StringBuffer();
      final LintRunner runner = LintRunner(
        config: loadedConfig,
        registry: registry,
        resolver: AreaResolver(
          loadedConfig.areas,
          rootDirectory: loadedConfig.rootDirectory,
        ),
        analyzer: StockAnalyzerRunner(
          const SystemProcessRunner(),
          out: sink,
          err: sink,
        ),
        reporter: ViolationReporter(sink),
      );

      final List<LintViolation> violations = (await runner.run(
        skipAnalyze: true,
      )).violations;

      expect(
        violations.map((LintViolation v) => v.ruleName),
        isNot(contains('avoid_high_cyclomatic_complexity')),
      );
    },
  );

  test(
    'exemptFlatDispatch defaulting to false (option omitted), read from '
    'real YAML, still reports the same flat switch',
    () async {
      final Directory root = tempRoot('dart_lints_flat_dispatch_default_');
      addTearDown(() => root.deleteSync(recursive: true));

      const String config = '''
analyzer:
  command: none

enable: [avoid_high_cyclomatic_complexity]

options:
  avoid_high_cyclomatic_complexity:
    maxComplexity: 2

areas:
  production:
    paths: ["lib/**"]
''';
      final String configPath = p.join(root.path, 'dart_lints.yaml');
      File(configPath).writeAsStringSync(config);

      final RuleRegistry registry = RuleRegistry();
      final DartLintsConfig loadedConfig = DartLintsConfigLoader(
        registry,
        const SystemFileSystemProbe(),
      ).load(configPath);

      final StringBuffer sink = StringBuffer();
      final LintRunner runner = LintRunner(
        config: loadedConfig,
        registry: registry,
        resolver: AreaResolver(
          loadedConfig.areas,
          rootDirectory: loadedConfig.rootDirectory,
        ),
        analyzer: StockAnalyzerRunner(
          const SystemProcessRunner(),
          out: sink,
          err: sink,
        ),
        reporter: ViolationReporter(sink),
      );

      final List<LintViolation> violations = (await runner.run(
        skipAnalyze: true,
      )).violations;

      expect(
        violations.map((LintViolation v) => v.ruleName),
        contains('avoid_high_cyclomatic_complexity'),
      );
    },
  );

  test(
    'a non-boolean exemptFlatDispatch value is rejected while loading, '
    'naming the option rather than miscoercing',
    () {
      final Directory root = tempRoot('dart_lints_flat_dispatch_bad_type_');
      addTearDown(() => root.deleteSync(recursive: true));

      const String config = '''
analyzer:
  command: none

enable: [avoid_high_cyclomatic_complexity]

options:
  avoid_high_cyclomatic_complexity:
    maxComplexity: 2
    exemptFlatDispatch: "yes"

areas:
  production:
    paths: ["lib/**"]
''';
      final String configPath = p.join(root.path, 'dart_lints.yaml');
      File(configPath).writeAsStringSync(config);

      final RuleRegistry registry = RuleRegistry();
      expect(
        () => DartLintsConfigLoader(
          registry,
          const SystemFileSystemProbe(),
        ).load(configPath),
        throwsA(
          isA<DartLintsConfigException>().having(
            (DartLintsConfigException e) => e.message,
            'message',
            allOf(
              contains('exemptFlatDispatch'),
              contains('must be true or false'),
            ),
          ),
        ),
      );
    },
  );
}
