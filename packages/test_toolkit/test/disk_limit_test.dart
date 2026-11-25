import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_toolkit/test_toolkit.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('disk_limit_test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  Future<ProcessResult> write(int maxMegabytes, int megabytes) =>
      Process.run(Platform.resolvedExecutable, <String>[
        'run',
        p.join('test', 'fixtures', 'write.dart'),
        '$maxMegabytes',
        '$megabytes',
        p.join(dir.path, 'runaway.log'),
      ]);

  test('kills a process stuck writing past its limit, and says why', () async {
    final ProcessResult result = await write(64, 512);

    expect(result.exitCode, -ProcessSignal.sigkill.signalNumber);
    expect(result.stdout, isNot(contains('done')));
    expect(result.stderr, contains('GB limit; killing it.'));
  });

  test('leaves a process under its limit alone', () async {
    final ProcessResult result = await write(1024, 8);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('done 8'));
    expect(result.stderr, isNot(contains('test_toolkit')));
  });

  test('reads the free space of a real disk', () {
    expect(DiskLimit.freeBytes(dir.path), greaterThan(0));
  });

  test('parses df -Pk output into bytes', () {
    const String output =
        'Filesystem   1024-blocks      Used Available Capacity  Mounted on\n'
        '/dev/disk3s5   239362496 151542180  48411920    76%    /System/Volumes/Data\n';

    expect(DiskLimit.parseDf(output), 48411920 * 1024);
  });

  test('returns null for df output it cannot read', () {
    expect(DiskLimit.parseDf(''), isNull);
    expect(
      DiskLimit.parseDf('Filesystem 1024-blocks Used Available\n'),
      isNull,
    );
    expect(DiskLimit.parseDf('header\n/dev/disk3s5 1 2\n'), isNull);
    expect(DiskLimit.parseDf('header\n/dev/disk3s5 1 2 lots 76% /\n'), isNull);
  });

  test('returns null when df fails', () {
    expect(DiskLimit.freeBytes(p.join(dir.path, 'missing')), isNull);
  });

  test('rejects a limit below 1', () {
    expect(
      () => prepareTestProcess(maxWrittenGigabytes: 0),
      throwsArgumentError,
    );
    expect(() => DiskLimit(maxWrittenBytes: 0), throwsArgumentError);
    expect(
      () => DiskLimit(maxWrittenBytes: 1, interval: Duration.zero),
      throwsArgumentError,
    );
  });
}
