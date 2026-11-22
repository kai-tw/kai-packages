import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_queue/test_queue.dart';

import 'support/compiled_cli.dart';

void main() {
  late CompiledCli cli;
  late Directory directory;

  setUpAll(() async => cli = await CompiledCli.compile());
  tearDownAll(() => cli.delete());
  setUp(() => directory = Directory(cli.slotDirectory()));

  SlotHolder holder(String label) => SlotHolder(
    pid: pid,
    label: label,
    workingDirectory: '/work',
    command: 'flutter test',
    startedAt: DateTime.now(),
  );

  test('hands out slots until none is left', () {
    final SlotPool pool = SlotPool(directory, 2);

    final HeldSlots? first = pool.tryAcquire(1, holder('a'));
    final HeldSlots? second = pool.tryAcquire(1, holder('b'));

    expect(first?.numbers, <int>[0]);
    expect(second?.numbers, <int>[1]);
    expect(pool.tryAcquire(1, holder('c')), isNull);
  });

  test('takes all the slots it asks for, or none', () {
    final SlotPool pool = SlotPool(directory, 2);
    final HeldSlots? one = pool.tryAcquire(1, holder('a'));

    expect(pool.tryAcquire(2, holder('b')), isNull);

    one?.release();
    expect(pool.tryAcquire(2, holder('b'))?.numbers, <int>[0, 1]);
  });

  test('writes the holder next to the slot, and removes it on release', () {
    final SlotPool pool = SlotPool(directory, 1);
    final File holderFile = File(p.join(directory.path, 'slot-0.holder'));

    final HeldSlots? held = pool.tryAcquire(1, holder('app'));
    expect(SlotHolder.decode(holderFile.readAsStringSync()).label, 'app');
    expect(pool.survey().single.holder?.label, 'app');

    held?.release();
    expect(holderFile.existsSync(), isFalse);
    expect(pool.survey().single.holder, isNull);
  });

  test('a second release does nothing', () {
    final SlotPool pool = SlotPool(directory, 1);
    final HeldSlots? held = pool.tryAcquire(1, holder('a'));
    held?.release();
    final HeldSlots? next = pool.tryAcquire(1, holder('b'));

    held?.release();

    expect(next, isNotNull);
    expect(pool.survey().single.holder?.label, 'b');
  });

  test('rejects a count or a request it can never meet', () {
    expect(() => SlotPool(directory, 0), throwsArgumentError);
    expect(
      () => SlotPool(directory, 2).tryAcquire(3, holder('a')),
      throwsArgumentError,
    );
  });

  test('sees a slot another process holds, and who holds it', () async {
    final Process other = await cli.start(<String>[
      'run',
      '--label',
      'other-run',
      '--',
      'sleep',
      '60',
    ], directory.path);
    await CompiledCli.stderrLine(other, 'slot 0');
    final SlotPool pool = SlotPool(directory, 2);

    expect(pool.survey().first.holder?.label, 'other-run');
    expect(pool.tryAcquire(2, holder('a')), isNull);
    expect(pool.tryAcquire(1, holder('a'))?.numbers, <int>[1]);
  });

  test('gets a slot back when its holder is killed outright', () async {
    final Process other = await cli.start(<String>[
      'run',
      '--',
      'sleep',
      '3',
    ], directory.path);
    await CompiledCli.stderrLine(other, 'slot 0');
    final SlotPool pool = SlotPool(directory, 1);
    expect(pool.tryAcquire(1, holder('a')), isNull);

    other.kill(ProcessSignal.sigkill);
    await other.exitCode;

    expect(pool.tryAcquire(1, holder('a')), isNotNull);
  });
}
