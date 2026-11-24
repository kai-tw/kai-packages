/// Keeps `flutter test` from using more memory than the machine has.
///
/// [prepareTestProcess], called from `flutter_test_config.dart`, is the usual
/// way in. The rest is for a tool that starts test processes itself and has
/// to take its slots from the same queue, such as a mutation tester.
library;

import 'src/prepare_test_process.dart';

export 'src/held_slots.dart';
export 'src/memory_limit.dart';
export 'src/memory_probe.dart';
export 'src/orphan_reaper.dart';
export 'src/prepare_test_process.dart';
export 'src/process_row.dart';
export 'src/process_table.dart';
export 'src/queue_settings.dart';
export 'src/slot_holder.dart';
export 'src/slot_pool.dart';
export 'src/slot_status.dart';
export 'src/slot_timeout_exception.dart';
export 'src/test_queue.dart';
