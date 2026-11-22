import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mutants/src/runner/test_slot.dart';
import 'package:dart_mutants/src/runner/test_slots.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_queue/test_queue.dart';

/// A program that locks `slot-0` in the directory it is given and prints
/// `locked` when it holds it, or `busy` when someone else does. A holder
/// then waits to be killed.
const String _holder = '''
import 'dart:io';
import 'dart:isolate';

void main(List<String> args) {
  final RandomAccessFile file = File(args.single + '/slot-0').openSync(
    mode: FileMode.append,
  );
  try {
    file.lockSync(FileLock.exclusive);
  } on FileSystemException {
    print('busy');
    exit(0);
  }
  print('locked');
  Future<void>.delayed(const Duration(minutes: 5));
  RawReceivePort();
}
''';

void main() {
  late Directory scratch;
  late Directory slotDir;
  late File program;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('dm_test_slots_');
    slotDir = Directory(p.join(scratch.path, 'slots'))..createSync();
    program = File(p.join(scratch.path, 'holder.dart'))
      ..writeAsStringSync(_holder);
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  /// Starts the holder and completes with it and the first line it prints.
  Future<(Process, String)> startHolder() async {
    final Process process = await Process.start('dart', <String>[
      program.path,
      slotDir.path,
    ]);
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    final String first = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    return (process, first);
  }

  test(
    '[S5] a slot whose holder is killed outright is reclaimed within a few '
    'seconds',
    () async {
      final (Process holder, String first) = await startHolder();
      expect(first, 'locked');
      final TestSlots slots = TestSlots(slotDir, 1);
      expect(slots.free(), 0);

      final Future<TestSlot?> waiting = slots.acquire();
      holder.kill(ProcessSignal.sigkill);

      final TestSlot slot = (await waiting.timeout(
        const Duration(seconds: 6),
      ))!;
      expect(slot.number, 0);
      slot.release();
    },
  );

  test(
    '[S5] a wait for a slot that is given up on ends with no slot, and takes '
    'none when one frees later',
    () async {
      final (Process holder, String first) = await startHolder();
      expect(first, 'locked');
      final TestSlots slots = TestSlots(slotDir, 1);
      final Completer<void> giveUp = Completer<void>();

      final Future<TestSlot?> waiting = slots.acquire(until: giveUp.future);
      giveUp.complete();

      expect(await waiting.timeout(const Duration(seconds: 1)), isNull);
      // Freed afterwards, the slot is nobody's: the abandoned wait took none.
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode;
      expect(slots.free(), 1);
    },
  );

  test(
    '[S5] a process that holds a slot keeps it when it counts the free ones',
    () async {
      final TestSlots slots = TestSlots(slotDir, 1);
      final TestSlot slot = (await slots.acquire())!;

      expect(slots.free(), 0);
      expect(slots.free(), 0);
      final (Process other, String first) = await startHolder();
      expect(first, 'busy');
      await other.exitCode;

      slot.release();
      expect(slots.free(), 1);
    },
  );

  test(
    '[S5] a slot given back is free for another process to take',
    () async {
      final TestSlots slots = TestSlots(slotDir, 1);
      (await slots.acquire())!.release();

      final (Process holder, String first) = await startHolder();
      expect(first, 'locked');
      holder.kill(ProcessSignal.sigkill);
    },
  );

  test(
    '[S5] a lane\'s slot names its holder, for `test_queue status`',
    () async {
      final TestSlots slots = TestSlots(slotDir, 1);
      final TestSlot slot = (await slots.acquire())!;
      final File holder = File(p.join(slotDir.path, 'slot-0.holder'));

      expect(
        SlotHolder.decode(holder.readAsStringSync()).command,
        'dart_mutants (one test process)',
      );

      slot.release();
      expect(holder.existsSync(), isFalse);
    },
  );

  group('[S5] inside a test_queue run', () {
    test('hands out only the slots the parent holds', () async {
      final TestSlots slots = TestSlots.inherited(slotDir, <int>[3, 5]);

      final TestSlot first = (await slots.acquire())!;
      final TestSlot second = (await slots.acquire())!;

      expect(<int>[first.number, second.number], <int>[3, 5]);
      expect(slots.free(), 0);
      expect(slotDir.listSync(), isEmpty, reason: 'no slot file is locked');
    });

    test('a lane waits for a slot another lane gives back', () async {
      final TestSlots slots = TestSlots.inherited(slotDir, <int>[0]);
      final TestSlot first = (await slots.acquire())!;

      final Future<TestSlot?> waiting = slots.acquire();
      first.release();

      expect(
        (await waiting.timeout(const Duration(seconds: 1)))?.number,
        0,
      );
    });

    test('reads the slot numbers the parent names', () {
      expect(TestSlots.slotNumbers('0,1'), <int>[0, 1]);
      expect(TestSlots.slotNumbers(' 2 '), <int>[2]);
      expect(() => TestSlots.slotNumbers('0,x'), throwsFormatException);
      expect(() => TestSlots.slotNumbers('-1'), throwsFormatException);
    });
  });
}
