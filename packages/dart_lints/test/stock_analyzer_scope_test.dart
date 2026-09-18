import 'dart:io';

import 'package:dart_lints/dart_lints.dart';
import 'package:glob/glob.dart';
import 'package:test/test.dart';

/// Records what the analyzer would have been invoked with.
class _RecordingProcessRunner implements ProcessRunner {
  final List<List<String>> invocations = <List<String>>[];

  @override
  ProcessResult run(String executable, List<String> arguments) {
    invocations.add(<String>[executable, ...arguments]);
    return ProcessResult(0, 0, '', '');
  }
}

DartLintsConfig _config({
  required String root,
  required List<String> areaGlobs,
  List<String> analyzerPaths = const <String>[],
}) => DartLintsConfig(
  rootDirectory: root,
  analyzer: AnalyzerSpec(
    command: AnalyzerCommand.dart,
    args: const <String>['--fatal-infos'],
    paths: analyzerPaths,
  ),
  areas: <Area>[
    Area(
      name: 'production',
      pathGlobs: areaGlobs.map(Glob.new).toList(),
      enabledRules: const <String>{},
    ),
  ],
);

void main() {
  group('the stock analyzer is scoped to the areas, not the repository', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('dart_lints_scope');
      Directory('${root.path}/lib').createSync();
      Directory('${root.path}/test').createSync();
      // The reason this test exists. A Flutter project's build output is
      // hundreds of generated files; handing the analyzer the repository root
      // reports every one of them, and none says anything about code anyone
      // wrote. Measured on one project: 912 of its 995 findings were here.
      Directory('${root.path}/build').createSync();
    });

    tearDown(() => root.deleteSync(recursive: true));

    Future<List<String>> argvFor(DartLintsConfig config) async {
      final _RecordingProcessRunner process = _RecordingProcessRunner();
      final LintRunner runner = LintRunner(
        config: config,
        registry: RuleRegistry(),
        resolver: AreaResolver(
          config.areas,
          rootDirectory: config.rootDirectory,
        ),
        analyzer: StockAnalyzerRunner(
          process,
          out: StringBuffer(),
          err: StringBuffer(),
        ),
        reporter: ViolationReporter(StringBuffer()),
      );
      await runner.run();
      return process.invocations.single;
    }

    test(
      'a bare run analyzes the area roots, never the repository root',
      () async {
        final List<String> argv = await argvFor(
          _config(root: root.path, areaGlobs: <String>['lib/**', 'test/**']),
        );

        expect(argv.first, 'dart');
        expect(argv, contains('--fatal-infos'));
        expect(argv, contains('${root.path}/lib'));
        expect(argv, contains('${root.path}/test'));
        expect(
          argv,
          isNot(contains(root.path)),
          reason: 'the repository root would drag in build/',
        );
        expect(argv.any((String a) => a.endsWith('/build')), isFalse);
      },
    );

    test('analyzer.paths overrides the derived roots when given', () async {
      final List<String> argv = await argvFor(
        _config(
          root: root.path,
          areaGlobs: <String>['lib/**', 'test/**'],
          analyzerPaths: <String>['lib'],
        ),
      );

      expect(argv, contains('lib'));
      expect(argv, isNot(contains('${root.path}/test')));
    });

    test('a glob whose first segment is itself a pattern falls back to the '
        'root — there is no fixed prefix to derive', () async {
      final List<String> argv = await argvFor(
        _config(root: root.path, areaGlobs: <String>['*/lib/**']),
      );

      expect(argv, contains(root.path));
    });

    test('a derived root that does not exist is dropped rather than passed '
        'to the analyzer', () async {
      final List<String> argv = await argvFor(
        _config(root: root.path, areaGlobs: <String>['lib/**', 'absent/**']),
      );

      expect(argv, contains('${root.path}/lib'));
      expect(argv.any((String a) => a.endsWith('/absent')), isFalse);
    });
  });
}
