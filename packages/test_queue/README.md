# test_queue

Runs `flutter test` and `dart test` through one queue that every caller on a
machine shares, so the suites running at once never need more memory than the
machine has, and no test process outlives the run that started it.

```bash
dart pub global activate --source git https://github.com/kai-tw/kai-packages \
  --git-path packages/test_queue

test_queue run flutter test test/features/
test_queue status
```

## Why

One `flutter test` can take a few gigabytes at its peak: the compiler, a
`flutter_tester` for each test file running at once, and the `flutter` tool.
Three things fill a machine's memory when tools run suites on it:

- **Every caller keeps a count of its own.** Tools that each limit how many
  suites they run still add up, because none of them sees the others.
- **Killed runs leave testers running.** Killing the `flutter` tool doesn't
  stop the `flutter_tester` processes under it. The system adopts them, and
  nothing ever stops them, so a stuck test can keep running for hours.
- **One test can grow without end.** A test stuck in a loop that keeps
  allocating takes its `flutter_tester` to tens of gigabytes, and the
  machine swaps until it's unusable. Waiting for free memory before the
  start can't catch that.

`test_queue` fixes all three: one set of slots in one directory for everyone,
a memory limit for each process while the run goes, and a run that kills
everything its command started when it ends.

## What `run` does

1. **Kills stray test processes first.** These are processes that `flutter
   test` runs (the `flutter` tool, `flutter_tester`, its compiler, its
   development service) that this user owns and whose parent is gone. Nothing
   else is touched.
2. **Waits for free memory**: 3 GB a slot by default, read from `vm_stat` on
   macOS and `MemAvailable` on Linux. This covers what slots can't see, like
   an Xcode build or a browser.
3. **Waits for a slot.** Slots are files locked with the operating system's
   own locks, so a run killed outright gives its slot back.
4. **Runs the command**, with a temporary directory of its own. Every second
   it checks each process in the tree, and if one uses more than `--max-rss`
   (4 GB by default), it kills the whole tree and names that process.
5. **Kills whatever the command left running** when it ends, and on `SIGINT`,
   `SIGTERM`, `SIGHUP` or `--timeout`, the whole process tree.

While it waits, it says why, and which runs hold the slots:

```
test_queue: waiting for 1 of 2 slots; holding now:
  slot-0  app  pid 4121  3m12s  flutter test
  slot-1  ci-runner  pid 5530  0m40s  flutter test --coverage
```

## Options

| `run` option | |
|---|---|
| `--slots <n>` | Slots this run needs (default 1). A tool that runs *n* suites at once takes *n*. |
| `--wait <seconds>` | How long to wait for a slot and free memory before giving up (default 120). There's no "forever": a run that can never start should fail where someone sees it, not hang. In CI, set it below the job's own timeout. |
| `--timeout <seconds>` | How long the command may run before its tree is killed. |
| `--max-rss <GB>` | How much memory any one process the command starts may use before the tree is killed (default 4). It's per process, not the total: a healthy `flutter test` spreads its memory over the compiler and several testers, and none of them comes near 4 GB. |
| `--label <name>` | The name other runs see while they wait on this one (default: the directory name, or `$TEST_QUEUE_LABEL`). |

Everything after the command is passed to it unchanged:
`test_queue run flutter test --coverage` passes `--coverage` to `flutter test`.

| Exit code | |
|---|---|
| the command's own | it ran |
| 64 | a usage error |
| 75 | the wait ran out; nothing ran, and trying again later is fine |
| 124 | `--timeout` ran out |
| 127 | the command could not be started |
| 137 | a process went over `--max-rss` |
| 128 + *n* | stopped by signal *n* |

A `test_queue run` inside another one starts at once without a slot of its
own, because its parent already holds one (`$TEST_QUEUE_HELD`).

## Settings

Every caller on the machine has to see the same values, so set them for the
user, not per project.

| Variable | Default |
|---|---|
| `TEST_QUEUE_DIR` | `$XDG_CACHE_HOME/test_queue/slots`, else `~/.cache/test_queue/slots` |
| `TEST_QUEUE_SLOTS` | one slot per 4 GB of memory beyond the first 8, at least one |
| `TEST_QUEUE_GB_PER_SLOT` | 3 |

## Limits

- **A `test_queue` killed outright with `SIGKILL`** can't stop its command.
  Its slot frees at once, while the suite keeps running. The next `run` (or
  `test_queue reap`) kills that suite before it starts anything.
- **The memory limit is checked once a second.** A process that allocates
  gigabytes in under a second can pass it before the check sees it.
- **macOS and Linux only.** It reads the process table with `ps`.

## As a library

A tool that runs suites itself, such as a mutation tester with several
workers, takes its slots from the same `SlotPool` and runs each suite through
a `TreeRunner`. See `lib/test_queue.dart`.
