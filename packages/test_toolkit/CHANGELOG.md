## 0.2.0

- `prepareTestProcess()` also kills the test process once the disk it runs on
  has lost more than 5 GB of free space since it started (`maxWrittenGigabytes`),
  as when a test stuck in a loop keeps writing to a log file. Free space is
  read with `df` once a second, from an isolate of its own.
- `DiskLimit` does the same for a process that sets it up itself.

## 0.1.0

First release, replacing `test_queue`. `flutter test` is now the only way in:
there's no command of its own.

- `prepareTestProcess()`, called from `flutter_test_config.dart`, kills the
  test process once it uses more than 4 GB of memory, kills leftover test
  processes, and waits for one of the machine's shared slots before the
  tests run. Processes get slots in the order they started waiting, so none
  waits forever behind newcomers.
- One slot is now one test process, not one whole `flutter test` run. The
  slot directory and the `TEST_QUEUE_*` variables are unchanged.
- `test_queue run`, `status` and `reap` are gone, with `TreeRunner`.
