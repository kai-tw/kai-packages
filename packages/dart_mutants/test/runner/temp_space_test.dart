import 'dart:io';

import 'package:dart_mutants/src/runner/temp_space.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A pid that was running a moment ago and no longer is.
Future<int> _deadPid() async {
  final Process process = await Process.start('true', <String>[]);
  await process.exitCode;
  return process.pid;
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('temp_space_test_'));
  tearDown(() => root.deleteSync(recursive: true));

  List<String> names() =>
      root.listSync().map((FileSystemEntity e) => p.basename(e.path)).toList()
        ..sort();

  test('[partition] a directory is named for this package, this process and '
      'its purpose, and delete removes it with its contents', () {
    final TempSpace space = TempSpace(root: root);
    final Directory dir = space.create('cov');
    File(p.join(dir.path, 'report.json')).writeAsStringSync('{}');

    expect(p.basename(dir.path), startsWith('dart_mutants_${pid}_cov_'));
    expect(TempSpace.ownerOf(p.basename(dir.path)), pid);

    space.delete(dir);
    expect(names(), isEmpty);
  });

  test('[state] deleteAll removes every directory still tracked, and only '
      'those', () {
    final TempSpace space = TempSpace(root: root);
    space
      ..create('a')
      ..delete(space.create('b'))
      ..create('c');
    Directory(p.join(root.path, 'someone_else')).createSync();

    space.deleteAll();

    expect(names(), <String>['someone_else']);
  });

  test('[boundary] deleting a directory that is already gone is not an '
      'error', () {
    final TempSpace space = TempSpace(root: root);
    final Directory dir = space.create('cov')..deleteSync();

    expect(() => space.delete(dir), returnsNormally);
  });

  test('[decision] a sweep deletes what a finished run left, and keeps what '
      'a running one, this one, or anyone else owns', () {
    for (final String name in <String>[
      'dart_mutants_111_cov_x', // finished
      'dart_mutants_222_cov_x', // still running
      'dart_mutants_${pid}_cov_x', // this process
      'dart_mutants_cov_x', // an older release's: no pid to judge by
      'other_111_cov_x', // not this package's
    ]) {
      Directory(p.join(root.path, name)).createSync();
    }
    File(p.join(root.path, 'dart_mutants_111_file')).writeAsStringSync('');

    final int swept = TempSpace(
      root: root,
      isRunning: (int owner) => owner != 111,
    ).sweepStale();

    expect(swept, 1);
    expect(
      names(),
      <String>[
        'dart_mutants_${pid}_cov_x',
        'dart_mutants_111_file',
        'dart_mutants_222_cov_x',
        'dart_mutants_cov_x',
        'other_111_cov_x',
      ]..sort(),
    );
  });

  test('[state] by default a pid is judged by ps: a dead one is swept, a '
      'live one kept', () async {
    final int dead = await _deadPid();
    final Process live = await Process.start('sleep', <String>['30']);
    addTearDown(live.kill);
    Directory(p.join(root.path, 'dart_mutants_${dead}_cov_x')).createSync();
    Directory(
      p.join(root.path, 'dart_mutants_${live.pid}_cov_x'),
    ).createSync();

    expect(TempSpace(root: root).sweepStale(), 1);
    expect(names(), <String>['dart_mutants_${live.pid}_cov_x']);
  });

  test('[boundary] a root that does not exist sweeps nothing', () {
    expect(
      TempSpace(root: Directory(p.join(root.path, 'missing'))).sweepStale(),
      0,
    );
  });
}
