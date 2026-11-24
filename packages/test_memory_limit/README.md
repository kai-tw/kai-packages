# test_memory_limit

Kills a test process that uses more memory than a set limit, so a test stuck
in a loop that keeps allocating fails in seconds instead of filling the
machine's memory.

```yaml
dev_dependencies:
  test_memory_limit:
    git:
      url: https://github.com/kai-tw/kai-packages
      path: packages/test_memory_limit
      ref: test_memory_limit-v0.1.0
```

```dart
// test/flutter_test_config.dart
import 'dart:async';

import 'package:test_memory_limit/test_memory_limit.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await limitMemory(); // 4 GB; limitMemory(gigabytes: 8) to raise it
  await testMain();
}
```

`flutter test` runs `flutter_test_config.dart` around every test file in its
directory and below it, so one file covers a whole package. It applies however
the suite is started: from an editor, a script, CI, or plain `flutter test`.

## What happens

Each test file runs in a `flutter_tester` process of its own. When that
process goes over the limit, it's killed, and `flutter test` reports:

```
Shell: test_memory_limit: this test process is using 4.1 GB of memory, over its 4.0 GB limit; killing it. The limit is set by limitMemory() in flutter_test_config.dart.
00:03 +12: test/sync/merge_test.dart: merges a long history - did not complete [E]
```

The test that was running fails, the other test files still run, and
`flutter test` exits 1.

## Why an isolate of its own

A runaway test is usually a synchronous loop that never gives its isolate's
event loop a turn, so a `Timer` in the test's own isolate would never fire.
`limitMemory` reads the process's memory (`ProcessInfo.currentRss`) from a
separate isolate, which runs on its own thread, four times a second.

That isolate doesn't keep the process alive: when the tests are done, the
process exits as usual.

## Limits

- **It covers the test process, not the compiler or the `flutter` tool.**
  They're separate processes, and no test code runs in them. `test_queue run
  --max-rss` covers those.
- **It's checked four times a second.** A test that allocates very fast can
  go past the limit by however much it allocates in a quarter of a second.
- **`flutter_test_config.dart` doesn't apply to `dart test`.** For a pure
  Dart package, call `limitMemory()` at the top of each test file's `main`.
  Under `dart test`, several test files can share one process, so the limit
  covers all of them together.
- **It needs `dart:io`**, so it doesn't work for tests run in a browser
  (`--platform chrome`).

## Without `limitMemory`

`MemoryLimit(maxBytes: …, interval: …).start()` takes the limit in bytes and
the interval to check at.
