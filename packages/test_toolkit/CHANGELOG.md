## 0.1.0

First release, replacing `test_queue`. `flutter test` is now the only way in:
there's no command of its own.

- `guardTestProcess()`, called from `flutter_test_config.dart`, kills the
  test process once it uses more than 4 GB of memory, kills leftover test
  processes, and waits for one of the machine's shared slots before the
  tests run.
- One slot is now one test process, not one whole `flutter test` run. The
  slot directory and the `TEST_QUEUE_*` variables are unchanged.
- `test_queue run`, `status` and `reap` are gone, with `TreeRunner`.
