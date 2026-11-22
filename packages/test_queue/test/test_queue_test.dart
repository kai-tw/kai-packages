import 'dart:io';

import 'package:test/test.dart';
import 'package:test_queue/test_queue.dart';

const int _gb = 1024 * 1024 * 1024;

/// A probe that reports [gigabytes] free, on macOS and on Linux alike.
MemoryProbe _freeMemory(int gigabytes) {
  const int page = 16384;
  final int pages = gigabytes * _gb ~/ page;
  return MemoryProbe(
    run: (String executable, List<String> arguments) async =>
        'Mach Virtual Memory Statistics: (page size of $page bytes)\n'
        'Pages free: $pages.\nPages inactive: 0.\n'
        'Pages speculative: 0.\nPages purgeable: 0.\n',
    readMeminfo: () async => 'MemAvailable: ${gigabytes * 1024 * 1024} kB\n',
  );
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('tq_queue_');
    addTearDown(() => directory.deleteSync(recursive: true));
  });

  final SlotHolder holder = SlotHolder(
    pid: pid,
    label: 'me',
    workingDirectory: '/work',
    command: 'flutter test',
    startedAt: DateTime.now(),
  );

  TestQueue queue(SlotPool pool, {int freeGigabytes = 16}) => TestQueue(
    pool: pool,
    memoryPerSlot: 3 * _gb,
    memory: _freeMemory(freeGigabytes),
    reaper: OrphanReaper(readTable: () => const ProcessTable(<ProcessRow>[])),
    pollInterval: const Duration(milliseconds: 20),
  );

  test('admits a run at once when a slot and the memory are free', () async {
    final List<String> reasons = <String>[];

    final HeldSlots? held = await queue(
      SlotPool(directory, 2),
    ).admit(slots: 2, holder: holder, wait: Duration.zero, onWait: reasons.add);

    expect(held?.numbers, <int>[0, 1]);
    expect(reasons, isEmpty);
  });

  test('waits while memory is short, and says so once', () async {
    final List<String> reasons = <String>[];

    final HeldSlots? held =
        await queue(SlotPool(directory, 2), freeGigabytes: 4).admit(
          slots: 2,
          holder: holder,
          wait: const Duration(milliseconds: 150),
          onWait: reasons.add,
        );

    expect(held, isNull);
    expect(reasons, <String>[
      'only 4.0 GB of memory is free, and this run needs 6.0 GB',
    ]);
  });

  test('waits while the slots are taken, and names who has them', () async {
    final SlotPool pool = SlotPool(directory, 1);
    final HeldSlots? other = pool.tryAcquire(1, holder);
    final List<String> reasons = <String>[];

    final HeldSlots? held = await queue(pool).admit(
      slots: 1,
      holder: holder,
      wait: const Duration(milliseconds: 150),
      onWait: reasons.add,
    );

    expect(held, isNull);
    expect(reasons, hasLength(1));
    expect(reasons.single, contains('waiting for 1 of 1 slots'));
    expect(reasons.single, contains('slot-0  me  pid $pid'));
    other?.release();
  });

  test('starts the run once a slot comes free', () async {
    final SlotPool pool = SlotPool(directory, 1);
    final HeldSlots? other = pool.tryAcquire(1, holder);
    Future<void>.delayed(
      const Duration(milliseconds: 100),
      () => other?.release(),
    ).ignore();

    final HeldSlots? held = await queue(
      pool,
    ).admit(slots: 1, holder: holder, wait: const Duration(seconds: 5));

    expect(held?.numbers, <int>[0]);
  });

  test('reaps strays before it looks at the slots', () async {
    const String tester =
        '/f/bin/cache/artifacts/engine/darwin-x64/flutter_tester';
    final List<int> killed = <int>[];
    final List<ProcessRow> reaped = <ProcessRow>[];
    final TestQueue withStray = TestQueue(
      pool: SlotPool(directory, 1),
      memoryPerSlot: 3 * _gb,
      memory: _freeMemory(16),
      reaper: OrphanReaper(
        readTable: () =>
            ProcessTable.parse(' $pid 1 7 dart\n 50 1 7 $tester\n'),
        kill: killed.add,
        confirmDelay: Duration.zero,
      ),
    );

    await withStray.admit(
      slots: 1,
      holder: holder,
      wait: Duration.zero,
      onReaped: reaped.add,
    );

    expect(killed, <int>[50]);
    expect(reaped.single.pid, 50);
  });
}
