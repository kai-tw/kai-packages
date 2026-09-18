import 'dart:io';

import 'package:dart_lints/dart_lints.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Regression test for the exact bug report: `avoid_layer_violation` never
/// fired on any project that requires `package:` imports, because comparing
/// an import URI (which never contains a literal `lib/`) against a
/// `lib/features/.../layer/` pattern always failed — silently, so the rule
/// looked like it was passing rather than never engaging.
///
/// This drives the real loader against a real `pubspec.yaml` and a real
/// `package:` import, the same path a consuming project's CI takes, rather
/// than constructing [AvoidLayerViolation] directly with the fix already
/// wired in — a unit test of the visitor could pass while the config loader
/// still failed to supply [AvoidLayerViolation.packageName], which is
/// exactly the gap that let the original bug ship unnoticed.
void main() {
  test(
    'a package: import crossing layers is caught with no packageName '
    'configured by hand — DartLintsConfigLoader reads it from pubspec.yaml',
    () async {
      final Directory root = Directory.systemTemp.createTempSync(
        'dart_lints_layer_violation_',
      );
      addTearDown(() => root.deleteSync(recursive: true));

      File(
        p.join(root.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: myapp\n');

      final Directory domainDir = Directory(
        p.join(root.path, 'lib', 'features', 'x', 'domain'),
      )..createSync(recursive: true);
      File(p.join(domainDir.path, 'x_repository.dart')).writeAsStringSync(
        "import 'package:myapp/features/x/data/x_dto.dart';\n",
      );

      const String config = '''
analyzer:
  command: none

enable: [avoid_layer_violation]

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
        contains('avoid_layer_violation'),
      );
    },
  );
}
