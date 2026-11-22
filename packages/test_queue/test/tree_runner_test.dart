import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_queue/test_queue.dart';

void main() {
  late List<String> log;
  late TreeRunner runner;

  setUp(() {
    log = <String>[];
    runner = TreeRunner(
      trackInterval: const Duration(milliseconds: 50),
      log: log.add,
    );
  });

  bool sleeping(String seconds) => ProcessTable.read().rows.any(
    (ProcessRow row) => row.command == 'sleep $seconds',
  );

  test('returns the command exit code', () async {
    expect(await runner.run(<String>['sh', '-c', 'exit 3']), 3);
    expect(log, isEmpty);
  });

  test('kills what the command left running when it ends', () async {
    final int code = await runner.run(<String>[
      'sh',
      '-c',
      'sleep 71 & sleep 0.5; exit 0',
    ]);

    expect(code, 0);
    expect(sleeping('71'), isFalse);
    expect(log.single, contains('killed 1 process(es)'));
    expect(log.single, contains('sleep 71'));
  });

  test('kills the whole tree when the timeout runs out', () async {
    final Stopwatch clock = Stopwatch()..start();

    final int code = await runner.run(<String>[
      'sh',
      '-c',
      'sleep 72 & sleep 73',
    ], timeout: const Duration(milliseconds: 500));

    expect(code, TreeRunner.timedOutCode);
    expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
    expect(sleeping('72'), isFalse);
    expect(sleeping('73'), isFalse);
  });

  test('gives the command a temporary directory and deletes it', () async {
    final Directory scratch = Directory.systemTemp.createTempSync('tq_tree_');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final String record = p.join(scratch.path, 'tmpdir');

    await runner.run(<String>[
      'sh',
      '-c',
      r'echo "$TMPDIR" > "$0"; touch "$TMPDIR/left-behind"',
      record,
    ]);

    final String tmp = File(record).readAsStringSync().trim();
    expect(p.basename(tmp), startsWith('test_queue_'));
    expect(Directory(tmp).existsSync(), isFalse);
  });

  test('passes the environment it is given', () async {
    expect(
      await runner.run(
        <String>['sh', '-c', r'test "$TQ_VALUE" = yes'],
        environment: <String, String>{'TQ_VALUE': 'yes'},
      ),
      0,
    );
  });

  test('throws when the command cannot be started', () {
    expect(
      runner.run(<String>['test-queue-no-such-command']),
      throwsA(isA<ProcessException>()),
    );
  });
}
