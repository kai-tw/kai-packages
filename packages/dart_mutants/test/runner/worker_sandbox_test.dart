import 'dart:convert';
import 'dart:io';

import 'package:dart_mutants/src/runner/process_command.dart';
import 'package:dart_mutants/src/runner/temp_space.dart';
import 'package:dart_mutants/src/runner/worker_sandbox.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory base;
  late String package;
  late TempSpace temps;

  setUp(() {
    base = Directory.systemTemp.createTempSync('worker_sandbox_test_');
    package = p.join(base.path, 'pkg');
    temps = TempSpace(
      root: Directory(p.join(base.path, 'temps'))..createSync(),
    );
    for (final String dir in <String>[
      'lib/src',
      'test',
      'assets',
      'build',
      '.git',
      'ios',
      '.dart_tool/test',
    ]) {
      Directory(p.join(package, dir)).createSync(recursive: true);
    }
    for (final (String path, String content) in <(String, String)>[
      ('pubspec.yaml', 'name: pkg\n'),
      ('lib/pkg.dart', "export 'src/a.dart';\n"),
      ('lib/src/a.dart', 'int a() => 1;\n'),
      ('lib/src/b.dart', 'int b() => 2;\n'),
      ('test/a_test.dart', 'void main() {}\n'),
      ('assets/data.txt', 'data'),
      ('build/out.bin', 'big'),
      ('.dart_tool/version', '3.9.0'),
    ]) {
      File(p.join(package, path)).writeAsStringSync(content);
    }
    File(
      p.join(package, '.dart_tool', 'package_config.json'),
    ).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'configVersion': 2,
        'packages': <Object?>[
          <String, Object?>{
            'name': 'pkg',
            'rootUri': '../',
            'packageUri': 'lib/',
          },
          <String, Object?>{
            'name': 'dep',
            'rootUri': 'file:///cache/dep-1.0.0',
            'packageUri': 'lib/',
          },
          <String, Object?>{
            'name': 'sibling',
            'rootUri': '../../sibling',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
  });
  tearDown(() => base.deleteSync(recursive: true));

  WorkerSandbox create({bool flutter = false}) => WorkerSandbox.create(
    id: 3,
    root: package,
    targets: <String>[p.join(package, 'lib', 'src', 'a.dart')],
    temps: temps,
    flutter: flutter,
  );

  FileSystemEntityType typeIn(WorkerSandbox sandbox, String path) =>
      FileSystemEntity.typeSync(
        p.join(sandbox.directory, path),
        followLinks: false,
      );

  test('[partition] a target is a real copy; its neighbours are links; the '
      'directories to them are real', () {
    final WorkerSandbox sandbox = create();

    expect(typeIn(sandbox, 'lib/src/a.dart'), FileSystemEntityType.file);
    expect(
      File(p.join(sandbox.directory, 'lib/src/a.dart')).readAsStringSync(),
      'int a() => 1;\n',
    );
    expect(typeIn(sandbox, 'lib/src/b.dart'), FileSystemEntityType.link);
    expect(typeIn(sandbox, 'lib/pkg.dart'), FileSystemEntityType.link);
    expect(typeIn(sandbox, 'lib/src'), FileSystemEntityType.directory);
    expect(typeIn(sandbox, 'test'), FileSystemEntityType.directory);
    expect(typeIn(sandbox, 'test/a_test.dart'), FileSystemEntityType.link);
  });

  test('[partition] top-level files are copies, other top-level directories '
      'one link each, and build output is left out', () {
    final WorkerSandbox sandbox = create();

    expect(typeIn(sandbox, 'pubspec.yaml'), FileSystemEntityType.file);
    expect(typeIn(sandbox, 'assets'), FileSystemEntityType.link);
    expect(typeIn(sandbox, 'ios'), FileSystemEntityType.link);
    expect(typeIn(sandbox, 'build'), FileSystemEntityType.notFound);
    expect(typeIn(sandbox, '.git'), FileSystemEntityType.notFound);
    expect(typeIn(sandbox, '.dart_tool/test'), FileSystemEntityType.notFound);
    expect(
      File(
        p.join(sandbox.directory, '.dart_tool', 'version'),
      ).readAsStringSync(),
      '3.9.0',
    );
  });

  test('[decision] under Flutter, the platform directories are left out', () {
    expect(typeIn(create(flutter: true), 'ios'), FileSystemEntityType.notFound);
  });

  test('[decision] the package config resolves this package to the worker, '
      'and every other package to where it already was', () {
    final WorkerSandbox sandbox = create();
    final Map<String, Object?> config =
        jsonDecode(
              File(
                p.join(sandbox.directory, '.dart_tool', 'package_config.json'),
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final Map<String, String> roots = <String, String>{
      for (final Object? entry in config['packages']! as List<Object?>)
        (entry! as Map<String, Object?>)['name']! as String:
            (entry as Map<String, Object?>)['rootUri']! as String,
    };

    expect(roots['pkg'], Uri.directory(sandbox.directory).toString());
    expect(roots['dep'], 'file:///cache/dep-1.0.0');
    expect(
      roots['sibling'],
      Uri.file(p.join(base.path, 'sibling')).toString(),
    );
  });

  test('[decision] a relative path dependency is anchored to where it is; '
      'anything else named path is left as written', () {
    Directory(p.join(base.path, 'sibling')).createSync();
    File(p.join(package, 'pubspec.yaml')).writeAsStringSync('''
name: pkg
dependencies:
  sibling:
    path: ../sibling
  quoted:
    path: "../sibling"
  gone:
    path: ../missing
  absolute:
    path: /opt/absolute
''');

    final String pubspec = File(
      p.join(create().directory, 'pubspec.yaml'),
    ).readAsStringSync();
    final String sibling = p.join(base.path, 'sibling');

    expect(pubspec, contains('sibling:\n    path: $sibling\n'));
    expect(pubspec, contains('quoted:\n    path: "$sibling"\n'));
    expect(pubspec, contains('path: ../missing'));
    expect(pubspec, contains('path: /opt/absolute'));
    expect(
      File(p.join(package, 'pubspec.yaml')).readAsStringSync(),
      contains('path: ../sibling'),
    );
  });

  test('[decision] a workspace member gets the workspace\'s package config '
      'and lock file, and stands alone', () {
    // Laid out as `pub` does: one config at the workspace root, listing the
    // member relative to it, and only a pointer in the member.
    final Directory workspace = Directory(base.path);
    File(p.join(package, '.dart_tool', 'package_config.json')).deleteSync();
    Directory(p.join(workspace.path, '.dart_tool')).createSync();
    File(
      p.join(workspace.path, '.dart_tool', 'package_config.json'),
    ).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'configVersion': 2,
        'packages': <Object?>[
          <String, Object?>{
            'name': 'pkg',
            'rootUri': '../pkg/',
            'packageUri': 'lib/',
          },
          <String, Object?>{
            'name': 'workspace',
            'rootUri': '../',
            'packageUri': 'lib/',
          },
        ],
      }),
    );
    File(
      p.join(workspace.path, '.dart_tool', 'version'),
    ).writeAsStringSync('ws');
    File(p.join(workspace.path, 'pubspec.lock')).writeAsStringSync('lock');
    File(p.join(package, '.dart_tool', 'version')).deleteSync();
    Directory(p.join(package, '.dart_tool', 'pub')).createSync();
    File(
      p.join(package, '.dart_tool', 'pub', 'workspace_ref.json'),
    ).writeAsStringSync('{"workspaceRoot": "../../.."}');
    File(
      p.join(package, 'pubspec.yaml'),
    ).writeAsStringSync('name: pkg\nresolution: workspace\n');

    final WorkerSandbox sandbox = create();
    String read(String path) =>
        File(p.join(sandbox.directory, path)).readAsStringSync();
    final Map<String, Object?> copied =
        jsonDecode(read('.dart_tool/package_config.json'))
            as Map<String, Object?>;
    final List<Object?> packages = copied['packages']! as List<Object?>;

    expect(
      (packages[0]! as Map<String, Object?>)['rootUri'],
      Uri.directory(sandbox.directory).toString(),
    );
    expect(
      (packages[1]! as Map<String, Object?>)['rootUri'],
      Uri.directory(workspace.path).toString(),
    );
    expect(read('.dart_tool/version'), 'ws');
    expect(read('pubspec.lock'), 'lock');
    expect(read('pubspec.yaml'), isNot(contains('resolution')));
    expect(
      File(p.join(package, 'pubspec.yaml')).readAsStringSync(),
      contains('resolution: workspace'),
    );
  });

  test('[state] writing a target changes the worker only', () {
    final WorkerSandbox sandbox = create();
    final String copy = sandbox.pathFor(p.join(package, 'lib/src/a.dart'));

    sandbox.write(copy, 'int a() => 2;\n');

    expect(File(copy).readAsStringSync(), 'int a() => 2;\n');
    expect(
      File(p.join(package, 'lib/src/a.dart')).readAsStringSync(),
      'int a() => 1;\n',
    );
  });

  test('[error] writing through a link is refused, and the package is left '
      'as it was', () {
    final WorkerSandbox sandbox = create();

    expect(
      () => sandbox.write(
        p.join(sandbox.directory, 'lib/src/b.dart'),
        'int b() => 3;\n',
      ),
      throwsStateError,
    );
    expect(
      File(p.join(package, 'lib/src/b.dart')).readAsStringSync(),
      'int b() => 2;\n',
    );
  });

  test('[partition] a command moves to the worker: its directory, and any '
      'argument naming a path in the package', () {
    final ProcessCommand moved = create().commandFor(
      ProcessCommand('dart', <String>[
        'test',
        p.join(package, 'test', 'a_test.dart'),
        'test/relative_test.dart',
        '--name',
        'x',
      ], workingDirectory: package),
      flutter: false,
    );

    expect(moved.workingDirectory, isNot(package));
    expect(moved.arguments, <String>[
      'test',
      p.join(moved.workingDirectory!, 'test', 'a_test.dart'),
      'test/relative_test.dart',
      '--name',
      'x',
    ]);
  });

  test('[boundary] run from inside the package, a word that happens to name '
      'one of its directories is not taken for a path', () {
    final String cwd = Directory.current.path;
    Directory.current = package;
    addTearDown(() => Directory.current = cwd);

    expect(
      create()
          .commandFor(
            const ProcessCommand('dart', <String>['test', 'test/a_test.dart']),
            flutter: false,
          )
          .arguments,
      <String>['test', 'test/a_test.dart'],
    );
  });

  test('[decision] under Flutter the command gets --no-pub, once', () {
    final WorkerSandbox sandbox = create(flutter: true);

    expect(
      sandbox
          .commandFor(
            const ProcessCommand('flutter', <String>['test']),
            flutter: true,
          )
          .arguments,
      <String>['test', '--no-pub'],
    );
    expect(
      sandbox
          .commandFor(
            const ProcessCommand('flutter', <String>['test', '--no-pub']),
            flutter: true,
          )
          .arguments,
      <String>['test', '--no-pub'],
    );
  });

  test('[state] disk use counts the worker\'s own files, not what its links '
      'point at', () {
    final WorkerSandbox sandbox = create();
    final int own =
        <String>[
          'pubspec.yaml',
          'lib/src/a.dart',
          '.dart_tool/version',
          '.dart_tool/package_config.json',
        ].fold(
          0,
          (int sum, String path) =>
              sum + File(p.join(sandbox.directory, path)).lengthSync(),
        );

    expect(sandbox.diskBytes(), own);
  });

  test('[state] the worker lives in the run\'s temporary space, and goes '
      'with it', () {
    final WorkerSandbox sandbox = create();
    expect(
      p.basename(sandbox.directory),
      startsWith('dart_mutants_${pid}_worker3_'),
    );

    temps.deleteAll();

    expect(Directory(sandbox.directory).existsSync(), isFalse);
    expect(File(p.join(package, 'lib/src/b.dart')).existsSync(), isTrue);
  });
}
