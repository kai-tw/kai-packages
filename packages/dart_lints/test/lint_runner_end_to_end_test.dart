import 'dart:io';

import 'package:dart_lints/dart_lints.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// End-to-end: a written `dart_lints.yaml` plus violating source, through the
/// real loader, area resolver, registry and runner, to a violation list.
///
/// Every other test in this package holds one rule and hands it a fixture
/// directly. That leaves the part between the configuration and the rule —
/// which area a file resolves to, which rules that area builds, which options
/// they are built with — covered by nothing, and it is the part a consuming
/// project actually configures. A rule can be listed as enabled and still
/// contribute nothing, which is the one failure a linter cannot detect about
/// itself.
///
/// The same source is written into three areas that disable different rules.
/// The differences between the three results ARE the per-area behaviour, so
/// they are asserted rather than the totals.
///
/// No package imports: like the per-rule tests, everything the fixture
/// references is stubbed so it resolves against `dart:core` alone. That is what
/// lets a pure-Dart package exercise rules whose real subjects are Flutter and
/// bloc types.
const String _stubs = r'''
class Widget {}

class BuildContext {}

class MediaQueryData {
  const MediaQueryData();
}

class MediaQuery {
  static MediaQueryData of(BuildContext context) => const MediaQueryData();
}

class StatelessWidget extends Widget {
  const StatelessWidget();
}

class Color {
  const Color(int value);
  const Color.fromARGB(int a, int r, int g, int b);
}

class Cubit<T> {
  Cubit(this.state);
  final T state;
}

class LogSystem {
  static void error(String m, {Object? error, StackTrace? stackTrace}) {}
}
''';

/// Deliberately-violating code. Each line is here to trip exactly one rule; do
/// not "fix" anything.
const String _violations = r'''
const int topLevelConstant = 1;

(int, String) recordReturn() => (1, 'a');

class SampleView extends StatelessWidget {
  const SampleView();

  Widget build(BuildContext context) {
    MediaQuery.of(context);
    return Widget();
  }
}

class Counter extends Cubit<int> {
  Counter() : super(0);
}

Future<void> doWork() async {
  try {
    await Future<void>.delayed(Duration.zero);
  } catch (e) {
    // Intentionally empty.
  }

  while (true) {
    break;
  }

  await Future<void>.value().then((void _) {});
}

void boom() {
  throw Exception('nope');
}

void log(Object value) {
  LogSystem.error('failed for $value');
}

int classify(int x) {
  if (x < 0) return -1;
  if (x == 0) return 0;
  if (x < 10) return 1;
  if (x < 100) return 2;
  return 3;
}
''';

const String _config = '''
analyzer:
  command: none

bundles: [core, flutter, bloc, log_system]

options:
  avoid_high_cyclomatic_complexity:
    maxComplexity: 4

areas:
  production:
    paths: ["lib/**"]

  test:
    paths: ["test/**"]
    disable:
      - avoid_record_types
      - avoid_empty_catch
      - avoid_media_query_of
      - avoid_top_level_identifiers

  tool:
    paths: ["tool/**"]
    disable:
      - avoid_top_level_identifiers
      - avoid_throwing_generic_exception
''';

/// Rule names reported for files under [area], as a set.
Set<String> _rulesIn(List<LintViolation> violations, String area) => violations
    .where((LintViolation v) => v.filePath.startsWith('$area/'))
    .map((LintViolation v) => v.ruleName)
    .toSet();

void main() {
  late Directory root;
  late List<LintViolation> violations;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('dart_lints_e2e_');

    for (final String area in <String>['lib', 'test', 'tool']) {
      final Directory dir = Directory(p.join(root.path, area))
        ..createSync(recursive: true);
      File(
        p.join(dir.path, 'fixture.dart'),
      ).writeAsStringSync('$_stubs\n$_violations');
    }
    final String configPath = p.join(root.path, 'dart_lints.yaml');
    File(configPath).writeAsStringSync(_config);

    final RuleRegistry registry = RuleRegistry();
    final DartLintsConfig config = DartLintsConfigLoader(
      registry,
      const SystemFileSystemProbe(),
    ).load(configPath);

    final StringBuffer sink = StringBuffer();
    final LintRunner runner = LintRunner(
      config: config,
      registry: registry,
      resolver: AreaResolver(config.areas, rootDirectory: config.rootDirectory),
      analyzer: StockAnalyzerRunner(
        const SystemProcessRunner(),
        out: sink,
        err: sink,
      ),
      reporter: ViolationReporter(sink),
    );

    violations = (await runner.run()).violations;
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  test('every fixture file resolved — an unresolved file lints as clean', () {
    expect(violations, isNotEmpty);
    for (final String area in <String>['lib', 'test', 'tool']) {
      expect(
        _rulesIn(violations, area),
        isNotEmpty,
        reason: 'nothing fired in $area/, so nothing looked at it',
      );
    }
  });

  test('the enabled bundles all reach a rule that fires', () {
    // One rule per bundle, so a bundle silently failing to load is visible.
    expect(
      _rulesIn(violations, 'lib'),
      allOf(<Matcher>[
        contains('avoid_empty_catch'), // core
        contains('avoid_media_query_of'), // flutter
        contains('require_cubit_suffix'), // bloc, and resolved-AST
        contains('avoid_unsafe_log_interpolation'), // log_system, resolved-AST
      ]),
    );
  });

  test(
    'a rule with a required option actually fires once the option is set',
    () {
      // Regression coverage for the required-options mechanism itself: a
      // typo'd or missing maxComplexity would throw in setUpAll above,
      // failing every test in this file — this confirms the option that IS
      // set also actually reaches the rule and does something with it.
      expect(
        _rulesIn(violations, 'lib'),
        contains('avoid_high_cyclomatic_complexity'),
      );
    },
  );

  test('a resolved-AST rule resolves the stubbed supertype chain', () {
    // `Counter extends Cubit<int>` is only reachable through type resolution;
    // a syntax-only pass cannot know Cubit is the state-holder base.
    expect(_rulesIn(violations, 'lib'), contains('require_cubit_suffix'));
  });

  test('an area disables exactly what it declares, and nothing else', () {
    final Set<String> production = _rulesIn(violations, 'lib');

    expect(
      production.difference(_rulesIn(violations, 'test')),
      <String>{
        'avoid_record_types',
        'avoid_empty_catch',
        'avoid_media_query_of',
        'avoid_top_level_identifiers',
      },
      reason: 'the test area disables these four and only these four',
    );

    expect(
      production.difference(_rulesIn(violations, 'tool')),
      <String>{
        'avoid_top_level_identifiers',
        'avoid_throwing_generic_exception',
      },
      reason: 'the tool area disables these two and only these two',
    );
  });

  test('a disabled rule is disabled only where it is declared', () {
    // avoid_top_level_identifiers is off in two areas and on in the third —
    // the shape that a single global rule set could not express.
    expect(
      _rulesIn(violations, 'lib'),
      contains('avoid_top_level_identifiers'),
    );
    expect(
      _rulesIn(violations, 'test'),
      isNot(contains('avoid_top_level_identifiers')),
    );
    expect(
      _rulesIn(violations, 'tool'),
      isNot(contains('avoid_top_level_identifiers')),
    );
  });
}
