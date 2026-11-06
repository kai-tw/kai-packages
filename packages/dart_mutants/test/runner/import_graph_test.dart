import 'dart:convert';
import 'dart:io';

import 'package:dart_mutants/src/runner/import_graph.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A package `app` beside a path package `helper`, with a package config
/// naming both and nothing else: no `pub get` runs, so every directive to a
/// package not named here leads nowhere — as `dart:` ones always do.
late Directory _dir;

String get _app => p.join(_dir.path, 'app');

void _write(String path, String content) {
  File(p.join(_dir.path, path))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
}

void _config(List<Map<String, Object?>> packages) => _write(
  'app/.dart_tool/package_config.json',
  jsonEncode(<String, Object?>{'configVersion': 2, 'packages': packages}),
);

Map<String, List<String>>? _loading(List<String> targets) {
  final List<String> tests = <String>[
    for (final FileSystemEntity e in Directory(
      p.join(_app, 'test'),
    ).listSync(recursive: true))
      if (e.path.endsWith('_test.dart')) p.relative(e.path, from: _app),
  ]..sort();
  return testFilesLoading(
    root: _app,
    testFiles: tests,
    targets: <String>[for (final String t in targets) p.join(_app, t)],
  );
}

List<String>? _for(String target) =>
    _loading(<String>[target])?[p.join(_app, target)];

void main() {
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('import_graph_test_');
    _config(<Map<String, Object?>>[
      <String, Object?>{'name': 'app', 'rootUri': '../', 'packageUri': 'lib/'},
      <String, Object?>{
        'name': 'helper',
        'rootUri': '../../helper',
        'packageUri': 'lib/',
      },
    ]);
    _write('app/pubspec.yaml', 'name: app\n');
    _write('app/lib/target.dart', 'int f() => 1;\n');
    _write('app/lib/other.dart', "import 'dart:io';\nint g() => 2;\n");
  });
  tearDown(() => _dir.deleteSync(recursive: true));

  group('a test file that leads to the target is kept', () {
    final Map<String, String> ways = <String, String>{
      'a package: import': "import 'package:app/target.dart';",
      'a relative import into lib/': "import '../lib/target.dart';",
      'a test helper that imports it': "import 'helpers/h.dart';",
      'a library that exports it': "import 'package:app/barrel.dart';",
      'another package that imports it back': "import 'package:helper/h.dart';",
      'a library of which it is a part': "import 'package:app/whole.dart';",
      'only one branch of a conditional import':
          "import 'package:app/other.dart' "
          "if (dart.library.io) 'package:app/target.dart';",
    };
    for (final MapEntry<String, String> way in ways.entries) {
      test('[partition] through ${way.key}', () {
        _write('app/test/helpers/h.dart', "import 'package:app/target.dart';");
        _write('app/lib/barrel.dart', "export 'target.dart';");
        _write('helper/lib/h.dart', "import 'package:app/target.dart';");
        _write('app/lib/whole.dart', "part 'target.dart';");
        _write('app/test/a_test.dart', '${way.value}\nvoid main() {}\n');
        _write('app/test/z_test.dart', "import 'package:app/other.dart';");

        expect(_for('lib/target.dart'), <String>['test/a_test.dart']);
      });
    }
  });

  test('[partition] a test file that imports only other code is left out, '
      'and a target no test imports is loaded by none', () {
    _write('app/test/a_test.dart', "import 'package:app/other.dart';");

    expect(_for('lib/target.dart'), isEmpty);
    expect(_for('lib/other.dart'), <String>['test/a_test.dart']);
  });

  test('[decision] a test file that leads to Isolate.spawnUri is kept for '
      'every target: it can load any file by its path', () {
    _write(
      'app/test/a_test.dart',
      "import 'dart:isolate';\n"
          'void main() => Isolate.spawnUri(Uri.file("x.dart"), [], null);\n',
    );
    _write('app/test/b_test.dart', "import 'package:app/other.dart';");

    expect(_for('lib/target.dart'), <String>['test/a_test.dart']);
  });

  test('[boundary] import cycles end, and each target gets its own list', () {
    _write('app/lib/a.dart', "import 'b.dart';");
    _write('app/lib/b.dart', "import 'a.dart';\nimport 'target.dart';");
    _write('app/test/a_test.dart', "import 'package:app/a.dart';");
    _write('app/test/b_test.dart', "import 'package:app/other.dart';");

    expect(
      _loading(<String>['lib/target.dart', 'lib/other.dart']),
      <String, List<String>>{
        p.join(_app, 'lib/target.dart'): <String>['test/a_test.dart'],
        p.join(_app, 'lib/other.dart'): <String>['test/b_test.dart'],
      },
    );
  });

  test('[boundary] a directive to a missing file, an unknown package or a '
      'dart: library leads nowhere, and does not stop the walk', () {
    _write(
      'app/test/a_test.dart',
      "import 'dart:async';\n"
          "import 'package:nowhere/x.dart';\n"
          "import 'missing.dart';\n"
          "import 'package:app/target.dart';\n",
    );

    expect(_for('lib/target.dart'), <String>['test/a_test.dart']);
  });

  group('cannot tell, and says so with null', () {
    test('[error] without a package config', () {
      File(p.join(_app, '.dart_tool', 'package_config.json')).deleteSync();
      _write('app/test/a_test.dart', "import 'package:app/target.dart';");

      expect(_loading(<String>['lib/target.dart']), isNull);
    });

    test('[error] with a package config in a shape it does not know', () {
      _write('app/.dart_tool/package_config.json', '{"packages": [{}]}');
      _write('app/test/a_test.dart', "import 'package:app/target.dart';");

      expect(_loading(<String>['lib/target.dart']), isNull);
    });
  });
}
