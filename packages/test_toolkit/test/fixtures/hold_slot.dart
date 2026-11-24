import 'dart:io';

import 'package:test_toolkit/test_toolkit.dart';

/// Run as `hold_slot.dart <slot directory> <slot count> <label>`.
///
/// Takes one slot, prints `slot <n>` to stderr, and holds it until killed.
Future<void> main(List<String> args) async {
  final SlotPool pool = SlotPool(Directory(args[0]), int.parse(args[1]));
  final HeldSlots? held = pool.tryAcquire(
    1,
    SlotHolder(
      pid: pid,
      label: args[2],
      workingDirectory: Directory.current.path,
      command: 'hold_slot.dart',
      startedAt: DateTime.now(),
    ),
  );
  if (held == null) {
    stderr.writeln('no slot free');
    exit(1);
  }
  stderr.writeln('slot ${held.numbers.single}');
  await Future<void>.delayed(const Duration(minutes: 5));
}
