/// Runs test suites through one queue shared by every caller on a machine.
///
/// The `test_queue` command is the usual way in. The library is for a tool
/// that runs suites itself and has to take its slots from the same queue,
/// such as a mutation tester that runs one suite per worker.
library;

export 'src/held_slots.dart';
export 'src/memory_probe.dart';
export 'src/orphan_reaper.dart';
export 'src/process_row.dart';
export 'src/process_table.dart';
export 'src/queue_settings.dart';
export 'src/slot_holder.dart';
export 'src/slot_pool.dart';
export 'src/slot_status.dart';
export 'src/test_queue.dart';
export 'src/tree_runner.dart';
