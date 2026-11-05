import 'dart:io';

import 'package:path/path.dart' as p;

import 'fixture_pubspec.dart';

/// A fixture package whose [testFiles] test files each take about
/// [delayMs] and write `<microseconds> start <id>` / `<microseconds> end <id>`
/// lines while they run (the id is `$DM_ID`). Each test file in each process
/// writes its own file, `$DM_MARKER.<pid>.<file index>`, so no two writers
/// ever share a file and there is nothing to race on. [readMarkers] merges
/// them back; [peakProcesses] counts the distinct processes alive at once,
/// which is what a test-slot limit has to bound.
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
    final File marker = File('\${Platform.environment['DM_MARKER']!}.\$pid.$i');
    final String id = Platform.environment['DM_ID']!;
    void mark(String what) => marker.writeAsStringSync(
      '\${DateTime.now().microsecondsSinceEpoch} \$what \$id\\n',
      mode: FileMode.append,
      flush: true,
    );
    mark('start');
    await Future<void>.delayed(const Duration(milliseconds: $delayMs));
    mark('end');
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

/// One marker line: when [pid] started or ended a test under [id].
typedef MarkerEvent = ({int micros, int pid, bool start, String id});

/// Every event written under the [marker] base path, merged in time order.
List<MarkerEvent> readMarkers(File marker) {
  final String base = p.basename(marker.path);
  final List<MarkerEvent> events = <MarkerEvent>[];
  for (final FileSystemEntity entity in marker.parent.listSync()) {
    final String name = p.basename(entity.path);
    if (entity is! File || !name.startsWith('$base.')) {
      continue;
    }
    final int pid = int.parse(name.substring(base.length + 1).split('.').first);
    for (final String line in entity.readAsLinesSync()) {
      final List<String> parts = line.split(' ');
      events.add((
        micros: int.parse(parts[0]),
        pid: pid,
        start: parts[1] == 'start',
        id: parts[2],
      ));
    }
  }
  events.sort((MarkerEvent a, MarkerEvent b) {
    final int byTime = a.micros.compareTo(b.micros);
    // An end sorts before a start at the same instant.
    return byTime == 0 ? (a.start ? 1 : 0) - (b.start ? 1 : 0) : byTime;
  });
  return events;
}

/// The ids that started a test, in any process.
Set<String> startedIds(File marker) => <String>{
  for (final MarkerEvent e in readMarkers(marker))
    if (e.start) e.id,
};

/// The most distinct test processes with a test running at once. A slot
/// stands for one process, and a process may run several test files, so this
/// counts pids, not test files.
int peakProcesses(File marker) {
  final Map<int, int> open = <int, int>{};
  int peak = 0;
  for (final MarkerEvent e in readMarkers(marker)) {
    open[e.pid] = (open[e.pid] ?? 0) + (e.start ? 1 : -1);
    final int alive = open.values.where((int n) => n > 0).length;
    if (alive > peak) {
      peak = alive;
    }
  }
  return peak;
}

/// Deletes the events written so far under [marker].
void clearMarkers(File marker) {
  final String base = p.basename(marker.path);
  for (final FileSystemEntity entity in marker.parent.listSync()) {
    if (entity is File && p.basename(entity.path).startsWith('$base.')) {
      entity.deleteSync();
    }
  }
}
