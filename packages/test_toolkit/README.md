# test_toolkit

Keeps `flutter test` from using more memory than the machine has. One call in
`flutter_test_config.dart`, and every test process:

- is killed once it uses more than 4 GB of memory;
- waits for one of a set of slots that every test process on the machine
  shares, so the tests running at once never need more memory than there is.

`flutter test` stays the only way in. There's no command of its own to run.

```dart
// test/flutter_test_config.dart
import 'dart:async';

import 'package:test_toolkit/test_toolkit.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await prepareTestProcess();
  await testMain();
}
```

```yaml
dev_dependencies:
  test_toolkit:
    git:
      url: https://github.com/kai-tw/kai-packages
      path: packages/test_toolkit
      ref: test_toolkit-v0.1.0
```

`flutter test` uses only the `flutter_test_config.dart` nearest to each test
file: one in the file's own directory, or the closest one above it up to the
package root. So one in `test/` covers every test file, unless a nearer one
hides it. `dart_lints`' `require_test_process_setup` rule checks that.

## Why

One `flutter test` starts a `flutter_tester` for each test file it runs at
once. Two things fill the machine's memory:

- **A runaway test.** A test stuck in a loop that keeps allocating can take
  its `flutter_tester` to tens of gigabytes.
- **Too many tests at once.** Several `flutter test` runs, from editor
  sessions, agents or a mutation tester, each start as many testers as they
  like. None of them sees the others.

## What `prepareTestProcess()` does

1. **Starts a memory limit**, 4 GB by default (`maxGigabytes`). It runs in an
   isolate of its own, so a test stuck in a synchronous loop can't stop it.
   Over the limit, it prints why and kills the process with `SIGKILL`.
   `flutter test` reports that test file as failed and carries on with the
   others.
2. **Kills leftover test processes**: `flutter_tester`s, `flutter test`
   tools, their compilers and development services that this user owns and
   whose parent is gone. Killing `flutter test` outright leaves its testers
   running, and nothing else ever stops them.
3. **Takes a number and waits its turn.** Test processes get slots in the
   order they started waiting, first come, first served. A process may try
   for a slot only while fewer processes ahead of it are still waiting than
   there are free slots, so a newcomer never takes a slot from one that has
   waited longer, and nobody waits forever behind a stream of newcomers. A
   process that dies while waiting drops out of the line on its own:
   its number is a file it keeps locked, and the next process to look deletes
   a number nobody holds.
4. **Waits for free memory**, 3 GB by default, read from `vm_stat` on macOS
   and `MemAvailable` on Linux. This covers what the slots can't see, like an
   Xcode build or a browser.
5. **Waits for a slot**, for at most `slotWait` (30 minutes by default, for
   steps 3 to 5 together). While it waits, it says why:

   ```
   Shell: test_toolkit: waiting for a slot, behind 3 test processes that started waiting first
   Shell: test_toolkit: waiting for 1 of 6 slots; holding now:
   Shell:   slot-0  app  pid 4121  0m12s  flutter test (one test file)
   ```

   A wait that runs out throws a `SlotTimeoutException`, and `flutter test`
   reports the test file as failed to load. There's no waiting forever: a slot
   held for good should fail where someone sees it, not hang.

The process holds its slot until it exits. `testExecutable` only declares the
tests, and `flutter test` runs them after it returns, so there's no earlier
point to give it back. A slot is a file locked with the operating system's own
lock, which goes away with the process however it ends, `SIGKILL` included.

A process whose parent already holds a slot for it skips steps 2 to 5:
`$TEST_QUEUE_HELD` lists the slots held. `dart_mutants` sets it for each test
process it starts, since it takes a slot for each one itself.

## Settings

Every test process on the machine has to see the same values, so set them for
the user, not per project.

| Variable | Default |
|---|---|
| `TEST_QUEUE_DIR` | `$XDG_CACHE_HOME/test_queue/slots`, else `~/.cache/test_queue/slots` |
| `TEST_QUEUE_SLOTS` | one slot per 4 GB of memory beyond the first 8, at least one |
| `TEST_QUEUE_GB_PER_SLOT` | 3: the free memory a test process waits for |

One slot per 4 GB matches the default memory limit: with every slot taken and
every process at its limit, the tests still fit.

## Limits

- **`flutter test` only.** `dart test` doesn't read `flutter_test_config.dart`,
  and an `integration_test` on a device runs in the app's process.
- **The `flutter` tool and its compiler hold no slot.** They take 1 to 2 GB
  per `flutter test`, which step 4 leaves room for.
- **Waiting testers still exist.** `flutter test -j 8` starts eight testers;
  the ones waiting for a slot hold a little memory each, a few hundred MB at
  most, while they wait.
- **macOS and Linux only.** On Windows only the memory limit works: it can't
  read the free memory or the process table, and with no `$HOME` the slots
  would land in each project's own directory instead of one for the machine.

## As a library

A tool that starts test processes itself, such as a mutation tester with
several workers, takes its slots from the same `SlotPool` and sets
`TEST_QUEUE_HELD` for each process it starts. See `lib/test_toolkit.dart`.
