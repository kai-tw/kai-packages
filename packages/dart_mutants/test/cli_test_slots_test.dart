import 'dart:async';
import 'dart:io';

import 'package:dart_mutants/src/runner/test_slot.dart';
import 'package:dart_mutants/src/runner/test_slots.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixture_pubspec.dart';
import 'support/marker_fixture.dart';

final String _binPath = p.join(
  Directory.current.path,
  'bin',
  'dart_mutants.dart',
);

/// Starts the CLI in [dir] on `lib/a.dart`, its test processes marking
/// [marker] as [id], with [slots] test slots in [slotDir].
Future<Process> _start(
  Directory dir, {
  required File marker,
  required String id,
  required Directory slotDir,
  required int slots,
  String workers = '1',
}) => Process.start(
  'dart',
  <String>[
    'run',
    _binPath,
    '--test-command',
    'dart test',
    '--workers',
    workers,
    'lib/a.dart',
  ],
  workingDirectory: dir.path,
  environment: <String, String>{
    ...cliEnvironment,
    'DART_MUTANTS_SLOT_DIR': slotDir.path,
    'DART_MUTANTS_SLOTS': '$slots',
    'DM_MARKER': marker.path,
    'DM_ID': id,
  },
);

void main() {
  useHermeticVersionCheck();

  late Directory scratch;
  late Directory slotDir;
  late File marker;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('dm_slots_');
    slotDir = Directory(p.join(scratch.path, 'slots'))..createSync();
    marker = File(p.join(scratch.path, 'marker.txt'))..createSync();
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  Future<Directory> fixture(String name, {int testFiles = 1}) async {
    final Directory dir = await markerFixture(name: name, testFiles: testFiles);
    addTearDown(() => dir.deleteSync(recursive: true));
    return dir;
  }

  test(
    '[S5] two runs at once with one slot never have two test processes '
    'alive together',
    () async {
      final Directory one = await fixture('slot_one');
      final Directory two = await fixture('slot_two');

      final Process first = await _start(
        one,
        marker: marker,
        id: 'one',
        slotDir: slotDir,
        slots: 1,
      );
      final Process second = await _start(
        two,
        marker: marker,
        id: 'two',
        slotDir: slotDir,
        slots: 1,
      );
      final List<int> codes = await Future.wait(<Future<int>>[
        first.exitCode,
        second.exitCode,
      ]);

      // Both finish: the second waited for the slot, it was not refused.
      expect(codes, everyElement(anyOf(0, 1)));
      expect(startedIds(marker), containsAll(<String>['one', 'two']));
      expect(peakProcesses(marker), 1);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    '[S5] with two slots, two runs at once do overlap, and no more than two',
    () async {
      final Directory one = await fixture('slot_one');
      final Directory two = await fixture('slot_two');

      final Process first = await _start(
        one,
        marker: marker,
        id: 'one',
        slotDir: slotDir,
        slots: 2,
      );
      final Process second = await _start(
        two,
        marker: marker,
        id: 'two',
        slotDir: slotDir,
        slots: 2,
      );
      await Future.wait(<Future<int>>[first.exitCode, second.exitCode]);

      // Distinct test processes, not test files: one slot is one process.
      expect(peakProcesses(marker), 2);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    '[S5] --workers auto opens one lane per free slot, and at least one',
    () async {
      final Directory three = await fixture('slot_auto', testFiles: 3);

      final Process wide = await _start(
        three,
        marker: marker,
        id: 'wide',
        slotDir: slotDir,
        slots: 3,
        workers: 'auto',
      );
      expect(await wide.exitCode, anyOf(0, 1));
      // The baseline is one process running three files; the mutant phase
      // opens one process per free slot.
      expect(peakProcesses(marker), 3);

      clearMarkers(marker);
      final Process narrow = await _start(
        three,
        marker: marker,
        id: 'narrow',
        slotDir: slotDir,
        slots: 1,
        workers: 'auto',
      );
      expect(await narrow.exitCode, anyOf(0, 1));
      expect(peakProcesses(marker), 1);
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    '[S5] a run that ends leaves its slots free for the next one',
    () async {
      final Directory one = await fixture('slot_one');

      for (final String id in <String>['again1', 'again2']) {
        final Process run = await _start(
          one,
          marker: marker,
          id: id,
          slotDir: slotDir,
          slots: 1,
        );
        expect(await run.exitCode, anyOf(0, 1), reason: id);
      }
      expect(startedIds(marker), contains('again2'));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    '[S4] a run paused while it waits for a slot does not start its '
    'baseline when the slot frees, only once it is resumed',
    () async {
      final Directory dir = await fixture('slot_paused');
      final Directory runs = Directory(
        p.join(cliEnvironment['XDG_CACHE_HOME']!, 'dart_mutants', 'runs'),
      )..createSync(recursive: true);

      // This process holds the only slot, so the run has to wait for it.
      final TestSlot? held = await TestSlots(slotDir, 1).acquire();
      expect(held, isNotNull);

      final Completer<void> appeared = Completer<void>();
      final StreamSubscription<FileSystemEvent> watch = runs.watch().listen((
        FileSystemEvent e,
      ) {
        if (e is FileSystemCreateEvent &&
            e.path.endsWith('.json') &&
            !appeared.isCompleted) {
          appeared.complete();
        }
      });
      addTearDown(watch.cancel);
      final Process run = await _start(
        dir,
        marker: marker,
        id: 'waiting',
        slotDir: slotDir,
        slots: 1,
      );
      await appeared.future;
      // Let the run get as far as waiting for the slot.
      await Future<void>.delayed(const Duration(seconds: 6));

      final ProcessResult pause = await Process.run(
        'dart',
        <String>['run', _binPath, 'pause'],
        workingDirectory: dir.path,
        environment: cliEnvironment,
      );
      expect(pause.exitCode, 0, reason: '${pause.stderr}');

      held!.release();
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(
        startedIds(marker),
        isEmpty,
        reason: 'the baseline started while the run was paused',
      );

      final ProcessResult resume = await Process.run(
        'dart',
        <String>['run', _binPath, 'resume'],
        workingDirectory: dir.path,
        environment: cliEnvironment,
      );
      expect(resume.exitCode, 0, reason: '${resume.stderr}');
      expect(await run.exitCode, anyOf(0, 1));
      expect(startedIds(marker), contains('waiting'));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
