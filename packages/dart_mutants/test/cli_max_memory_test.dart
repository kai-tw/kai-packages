import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture_pubspec.dart';

final String _binPath = p.join(
  Directory.current.path,
  'bin',
  'dart_mutants.dart',
);

/// A package whose one function allocates 1 MB a step. Deleting its `i++`
/// leaves a loop that allocates until something stops it: here, the cap of
/// 2500 steps, so a run whose memory limit failed peaks at 2.5 GB, and the
/// mutant comes out `detected` instead of `overMemory`.
Future<Directory> _fixture() async {
  final Directory dir = Directory.systemTemp.createTempSync('cli_max_memory_');
  File(
    p.join(dir.path, 'pubspec.yaml'),
  ).writeAsStringSync(dartFixturePubspec('fixture'));
  File(p.join(dir.path, 'lib', 'fill.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
int fill(int n) {
  final List<List<int>> kept = <List<int>>[];
  int i = 0;
  while (i < n) {
    kept.add(List<int>.filled(1 << 17, i));
    if (kept.length > 2500) {
      break;
    }
    i++;
  }
  return kept.length;
}
''');
  File(p.join(dir.path, 'test', 'fill_test.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
import 'package:fixture/fill.dart';
import 'package:test/test.dart';

void main() {
  test('fill', () => expect(fill(3), 3));
}
''');
  final ProcessResult pubGet = await Process.run('dart', <String>[
    'pub',
    'get',
  ], workingDirectory: dir.path);
  if (pubGet.exitCode != 0) {
    throw StateError('dart pub get failed:\n${pubGet.stderr}');
  }
  return dir;
}

void main() {
  useHermeticVersionCheck();

  test(
    '[partition] a mutant whose test process goes over --max-memory is '
    'killed, reported as over memory, and left out of the score',
    () async {
      final Directory dir = await _fixture();
      addTearDown(() => dir.deleteSync(recursive: true));

      final ProcessResult result = await Process.run(
        'dart',
        <String>[
          'run',
          _binPath,
          '--test-command',
          'dart test',
          '--max-memory',
          '1',
          '--json',
          p.join(dir.path, 'lib', 'fill.dart'),
        ],
        workingDirectory: dir.path,
        environment: cliEnvironment,
      );

      final Map<String, Object?> json =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      final Map<String, Object?> stats = json['stats']! as Map<String, Object?>;
      expect(
        (stats['environment']! as Map<String, Object?>)['maxMemoryGb'],
        1,
      );
      final Map<String, Object?> file =
          (json['files']! as Map<String, Object?>).values.single!
              as Map<String, Object?>;
      expect(file['overMemory'], 1, reason: '${result.stderr}');
      final Map<String, Object?> killed =
          (file['overMemoryMutants']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(killed['description'], contains('i++'));
      final List<Object?> undetected =
          file['undetectedMutants']! as List<Object?>;
      expect(file['total'], (file['detected']! as int) + undetected.length);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    '[validation] rejects a --max-memory that is not a whole number',
    () async {
      final ProcessResult result = await Process.run('dart', <String>[
        'run',
        _binPath,
        '--max-memory',
        '1.5',
        'lib/a.dart',
      ], environment: cliEnvironment);

      expect(result.exitCode, 64);
      expect(result.stderr, contains('--max-memory must be a whole number'));
    },
  );
}
