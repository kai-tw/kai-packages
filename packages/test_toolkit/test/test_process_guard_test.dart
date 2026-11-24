import 'dart:io';

import 'package:test/test.dart';
import 'package:test_toolkit/test_toolkit.dart';

import 'support/fixture_process.dart';

void main() {
  late Directory slots;

  setUp(() {
    slots = Directory.systemTemp.createTempSync('guard_');
    addTearDown(() => slots.deleteSync(recursive: true));
  });

  test('holds a slot until the process exits', () async {
    final FixtureProcess first = await FixtureProcess.start('guard', <String>[
      '60000',
      '60',
    ], slots: slots.path);
    await first.line('guarded');

    final SlotHolder? holder = SlotPool(slots, 1).survey().single.holder;
    expect(holder?.pid, first.pid);
    expect(holder?.command, 'flutter test (one test file)');
  });

  test('waits for a slot, and says who holds it', () async {
    final FixtureProcess first = await FixtureProcess.start('guard', <String>[
      '2000',
      '60',
    ], slots: slots.path);
    await first.line('guarded');

    final FixtureProcess second = await FixtureProcess.start('guard', <String>[
      '0',
      '60',
    ], slots: slots.path);
    await second.line('waiting for 1 of 1 slots');
    expect(second.stdoutLines, isNot(contains('guarded')));
    expect(second.stderrLines.join('\n'), contains('pid ${first.pid}'));

    expect(await first.process.exitCode, 0);
    await second.line('guarded');
    expect(await second.process.exitCode, 0);
  });

  test('takes no slot when a parent holds one for it', () async {
    final FixtureProcess holder = await FixtureProcess.start(
      'hold_slot',
      <String>[slots.path, '1', 'parent'],
      slots: slots.path,
    );
    await holder.line('slot 0');

    final FixtureProcess child = await FixtureProcess.start(
      'guard',
      <String>['0', '60'],
      slots: slots.path,
      environment: <String, String>{'TEST_QUEUE_HELD': '0'},
    );

    expect(await child.process.exitCode, 0);
    expect(child.stdoutLines, contains('guarded'));
    expect(SlotPool(slots, 1).survey().single.holder?.label, 'parent');
  });

  test('gives up after the slot wait, naming the holders', () async {
    final FixtureProcess holder = await FixtureProcess.start(
      'hold_slot',
      <String>[slots.path, '1', 'parent'],
      slots: slots.path,
    );
    await holder.line('slot 0');

    final FixtureProcess waiter = await FixtureProcess.start('guard', <String>[
      '0',
      '1',
    ], slots: slots.path);

    expect(await waiter.process.exitCode, isNot(0));
    expect(waiter.stdoutLines, isNot(contains('guarded')));
    final String err = waiter.stderrLines.join('\n');
    expect(err, contains('for a test slot and none came free'));
    expect(err, contains('slot-0  parent  pid ${holder.pid}'));
  });
}
