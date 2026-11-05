import 'dart:io';

import 'package:path/path.dart' as p;

import 'fixture_pubspec.dart';

/// A fixture package whose [testFiles] test files each take about
/// [delayMs] and write `start <id>` / `end <id>` lines to the file named by
/// `$DM_MARKER` (the id is `$DM_ID`) while they run. Reading the markers
/// back shows how many test processes were alive at once, which is what a
/// test-slot limit has to bound.
Future<Directory> markerFixture({
  required String name,
  int testFiles = 1,
  int delayMs = 1500,
}) async {
  final Directory dir = Directory.systemTemp.createTempSync('dm_marker_');
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
    dartFixturePubspec(name),
  );
  Directory(p.join(dir.path, 'lib')).createSync();
  Directory(p.join(dir.path, 'test')).createSync();
  File(
    p.join(dir.path, 'lib', 'a.dart'),
  ).writeAsStringSync('int lower(int a, int b) => a < b ? a : b;\n');
  for (int i = 0; i < testFiles; i++) {
    File(p.join(dir.path, 'test', 'a${i}_test.dart')).writeAsStringSync('''
import 'dart:io';

import 'package:$name/a.dart';
import 'package:test/test.dart';

void main() {
  test('lower', () async {
    final File marker = File(Platform.environment['DM_MARKER']!);
    final String id = Platform.environment['DM_ID']!;
    marker.writeAsStringSync('start \$id\\n', mode: FileMode.append, flush: true);
    await Future<void>.delayed(const Duration(milliseconds: $delayMs));
    marker.writeAsStringSync('end \$id\\n', mode: FileMode.append, flush: true);
    expect(lower(1, 2), 1);
  });
}
''');
  }
  final ProcessResult pubGet = await Process.run('dart', <String>[
    'pub',
    'get',
  ], workingDirectory: dir.path);
  if (pubGet.exitCode != 0) {
    throw StateError(
      'dart pub get failed:\n${pubGet.stdout}\n${pubGet.stderr}',
    );
  }
  return dir;
}

/// The most test processes the [marker] file shows alive at once.
int peakConcurrency(File marker) {
  int alive = 0;
  int peak = 0;
  for (final String line in marker.readAsLinesSync()) {
    alive += line.startsWith('start ') ? 1 : -1;
    if (alive > peak) {
      peak = alive;
    }
  }
  return peak;
}
