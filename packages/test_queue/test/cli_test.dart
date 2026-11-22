import 'dart:io';

import 'package:test/test.dart';
import 'package:test_queue/test_queue.dart';

import 'support/compiled_cli.dart';

void main() {
  late CompiledCli cli;
  late String slots;

  setUpAll(() async => cli = await CompiledCli.compile());
  tearDownAll(() => cli.delete());
  setUp(() => slots = cli.slotDirectory());

  bool sleeping(String seconds) => ProcessTable.read().rows.any(
    (ProcessRow row) => row.command == 'sleep $seconds',
  );

  test('run passes the command through and returns its exit code', () async {
    final ProcessResult result = await cli.run(<String>[
      'run',
      'sh',
      '-c',
      'echo out; exit 4',
    ], slots);

    expect(result.exitCode, 4);
    expect(result.stdout, 'out\n');
    expect(result.stderr, contains('test_queue: slot 0 · sh -c echo out'));
  });

  test('run passes the options after the command to the command', () async {
    final ProcessResult result = await cli.run(<String>[
      'run',
      'sh',
      '-c',
      r'echo "$1"',
      'sh',
      '--wait',
    ], slots);

    expect(result.stdout, '--wait\n');
  });

  test(
    'run gives up with 75, naming the holders, once --wait runs out',
    () async {
      final Process first = await cli.start(<String>[
        'run',
        '--label',
        'first',
        'sleep',
        '81',
      ], slots);
      final Process second = await cli.start(<String>[
        'run',
        '--label',
        'second',
        'sleep',
        '82',
      ], slots);
      await CompiledCli.stderrLine(first, 'test_queue: slot');
      await CompiledCli.stderrLine(second, 'test_queue: slot');

      final ProcessResult third = await cli.run(<String>[
        'run',
        '--wait',
        '1',
        'true',
      ], slots);

      expect(third.exitCode, 75);
      expect(third.stderr, contains('  first  pid ${first.pid}'));
      expect(third.stderr, contains('  second  pid ${second.pid}'));
      expect(third.stderr, contains('Nothing ran.'));
    },
  );

  test('run kills its command when it is sent SIGTERM', () async {
    final Process run = await cli.start(<String>[
      'run',
      'sh',
      '-c',
      'sleep 83',
    ], slots);
    await CompiledCli.stderrLine(run, 'test_queue: slot');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    run.kill();

    expect(await run.exitCode, 128 + ProcessSignal.sigterm.signalNumber);
    expect(sleeping('83'), isFalse);
  });

  test('run inside a run starts at once, without a slot', () async {
    final ProcessResult result = await cli.run(<String>[
      'run',
      '--slots',
      '2',
      cli.executable,
      'run',
      '--slots',
      '2',
      'sh',
      '-c',
      r'echo "held=$TEST_QUEUE_HELD"',
    ], slots);

    expect(result.exitCode, 0);
    expect(result.stdout, 'held=0,1\n');
  });

  test('run rejects a request it can never meet', () async {
    final ProcessResult noCommand = await cli.run(<String>['run'], slots);
    final ProcessResult tooMany = await cli.run(<String>[
      'run',
      '--slots',
      '3',
      'true',
    ], slots);
    final ProcessResult badWait = await cli.run(<String>[
      'run',
      '--wait',
      'soon',
      'true',
    ], slots);
    final ProcessResult forever = await cli.run(<String>[
      'run',
      '--wait',
      'forever',
      'true',
    ], slots);

    expect(noCommand.exitCode, 64);
    expect(tooMany.exitCode, 64);
    expect(tooMany.stderr, contains('needs 3 slots, and this machine has 2'));
    expect(badWait.exitCode, 64);
    expect(forever.exitCode, 64);
    expect(
      forever.stderr,
      contains('--wait must be a whole number of seconds'),
    );
  });

  test('run returns 127 for a command that cannot be started', () async {
    final ProcessResult result = await cli.run(<String>[
      'run',
      'test-queue-no-such-command',
    ], slots);

    expect(result.exitCode, 127);
  });

  test('status lists every slot', () async {
    final ProcessResult result = await cli.run(<String>['status'], slots);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('test_queue · 2 slots · $slots'));
    expect(result.stdout, contains('  slot-0  free'));
    expect(result.stdout, contains('  slot-1  free'));
  });

  test('an unknown command prints the usage and exits 64', () async {
    final ProcessResult result = await cli.run(<String>['launch'], slots);

    expect(result.exitCode, 64);
  });
}
