# dart_mutants

AST-based mutation testing for Dart and Flutter.

A regex-based mutator can only see text patterns, which means it is blind to
whatever it cannot tell apart from something else — a ternary's `?`/`:` also
appear in null-aware access and named-parameter syntax, `??` is two
characters that mean nothing on their own, and `<` inside `List<int>` is a
generic bracket, not a comparison. This package walks the real analyzer AST
instead, so it mutates exactly the node it means to and nothing it does not.

```bash
dart run dart_mutants \
  --test-command "flutter test test/foo_test.dart" \
  lib/foo.dart lib/bar.dart
```

```bash
dart run dart_mutants --output build/mutation.json \
  --test-command "dart test" lib/foo.dart
```

A run prints what it holds once the baseline has passed, then one line per
mutant as it finishes, then the text report:

```text
3 mutants in 1 file — baseline 4.1s, each mutant given at least 30.0s a test file
[1/3] detected lib/foo.dart:12:10 ternary_swap (3.9s, ~8s left)
[2/3] invalid lib/foo.dart:18:5 statement_deletion (0.0s, ~3s left)
[3/3] undetected lib/foo.dart:30:12 condition_negation (4.2s)
```

`--output` writes the JSON report to a file and leaves stdout to those lines.
`--json` prints the JSON report to stdout instead, with no progress lines, so
stdout parses as a whole.

## How long it will take

The plan line doesn't say, because nothing before the first mutant knows. A
mutant costs one run of each test file it reaches, until one of them fails,
and how many files that is, how fast they run, how many candidates the
compile-safety gate rejects for free and what parallel workers actually win
all only exist once mutants have run.

The `left` on each progress line is the one projection, and it is measured:
the wall time since the first mutant started, over the mutants finished in
it, times the ones to come. It moves as the run does.

### `--max-minutes`: stop rather than find out

`--max-minutes <n>` ends a run that will not fit, scoring nothing, as
`over-budget`. The measured pace is compared against the limit once enough
mutants have finished for it to mean anything — eight per worker, so that a
stretch of free rejections cannot pass for the pace of the rest — and a run
that will not fit stops between mutants. Nothing is refused up front: only
the pace can say.

There is no dry-run mode, and this is why: the pace only exists once mutants
have run. A separate counting pass would pay for what the run itself learns
on the way past.

The limit is on the mutants. The baseline and the coverage pass come before
the first one and are not counted against it. Compiling the test files
happens among the mutants, and is.

### `--journal`: stop now, finish later

`--journal <path>` writes the baseline, the coverage map and each mutant's
result to a JSON Lines file as each is known. Start the same run again with
the same file and all of them are reused; only the rest run. So a run can be
stopped — Ctrl-C, `kill`, `--max-minutes`, a crash — and resumed without
paying for the baseline or the coverage pass again, and a finished run
started again runs no test at all. Under `flutter test` the coverage pass is
one run per test file, and each one's result is written as it finishes, so a
pass stopped part-way resumes from the next test file too.

```bash
dart run dart_mutants --journal .mutation/journal.jsonl \
  --test-command "flutter test test/foo" lib/foo.dart
```

What is recorded is reused only when nothing it depends on has changed: the
test command, the operators, the compile-safety gate,
`--select-by-coverage`, and the content of `pubspec.yaml`, `pubspec.lock`,
everything under `lib/` and `test/`, and the files given. Any change starts
the file over, with a note on stderr saying which — an edit anywhere can
change any verdict, so none is guessed at. So does a release that changes
how a verdict is reached; other releases resume a journal an earlier one
wrote. 0.9.0 is such a release, so a journal an earlier one wrote starts over
once. A file a test reads from outside `test/`, or a Dart SDK upgrade, is
not seen; delete the journal after changing one. A recorded timeout is
always asked again: the budget decided it, and the next start may have a
larger one.

What a start still does every time: the gate checks. The plan line counts
the mutants that will run, names how many more were reused, and says when
the baseline or the coverage map came from the journal; the report's
`reusedMutants` gives the count.

### `pause`, `resume` and `stop`: a run in progress

```bash
dart run dart_mutants pause    # in the package the run is in
dart run dart_mutants resume
dart run dart_mutants stop 4242   # or name the run by its pid
```

A paused run lets each test file's run it is on finish, then starts no new
one, and each worker closes its compiler; on resume each compiles again where
it needs to and carries on. The time paused counts neither against a
mutant's budget nor against the pace `--max-minutes` is judged by. A stopped
run kills its test processes, deletes its copies of the package and ends as
`stopped`, exit 1, scoring nothing — the mutants that finished are in the
journal, if it has one.

A run finds itself by a file it keeps at
`$XDG_CACHE_HOME/dart_mutants/runs/<pid>.json` (`~/.cache` without
`XDG_CACHE_HOME`) while it runs. Without a pid, the command acts on the one
run in the current directory's package, and exits 2 when there is none or
more than one. The signals are `SIGUSR1`, `SIGUSR2` and `SIGTERM`, so `kill`
does the same where the command cannot.

### `--lines` and `--per-line`: mutate what a change touched

A file given on the command line is mutated whole. For a review, that is
mostly mutants in code the change never touched. `--lines <file>:<ranges>`
keeps only the mutants on those lines of that file, and `--per-line <n>`
keeps at most `n` on any one line:

```bash
dart run dart_mutants --per-line 1 \
  --lines lib/foo.dart:12-18,40 --lines lib/bar.dart:3 \
  --test-command "flutter test test/foo" lib/foo.dart lib/bar.dart
```

Repeat `--lines` per file; a file it doesn't name is mutated whole, and one it
names that isn't among the files given is a usage error. Which mutants a line
keeps is fixed by a hash of each mutant, not by order, so the same code always
keeps the same ones and `--journal` still finds them on a restart. The report
counts only the mutants kept.

## What it mutates

The operators fall into two groups that ask different questions, and a pool
holding only one group has a blind half rather than a smaller sample.

**"Is this expression's branch or boundary pinned?"** — these presume the
line runs and probe which way it went:

- **`ternary_swap`** — `a ? b : c` -> `a ? c : b`.
- **`switch_expression_arm_swap`** — one arm's result replaced with an
  adjacent arm's, patterns and guards untouched.
- **`null_coalescing_deletion`** — `a ?? b` -> `a` alone and, separately,
  `b` alone.
- **`relational_operator_replacement`** — `<`/`<=`/`>`/`>=`/`==`/`!=`
  replaced with a boundary-adjacent operator (not the full family — see the
  class doc on `RelationalOperatorReplacement` for why).
- **`logical_operator_replacement`** — `&&` <-> `||`.
- **`arithmetic_operator_replacement`** — `+` <-> `-`, `*` <-> `/`.

**"Does any test assert this line's effect happened at all?"** — these ask
the prior question, and are the only ones that reach code containing no
operator to mutate:

- **`statement_deletion`** — one statement replaced with an empty `;`.
- **`condition_negation`** — `if (x)` -> `if (!(x))`, for `if`/`while`/
  `do-while` and collection-`if`. Skipped when the condition is already a
  comparison, which `relational_operator_replacement` covers better.

A guard like `if (mounted) { setState(...) }` contains no ternary, no `??`
and no comparison, so only the second group reaches it at all. Without those,
a file's whole conditional structure can go unmeasured while the score reads
clean.

## The compile-safety gate

An AST-legal edit is not a type-legal one. A mutant that fails to compile
still fails its test run, which — read naively — counts as "detected": a
broken mutant would make the score go *up*, not down, for a file the
mutation never actually ran against. Every mutant is checked against the
analyzer before it ever runs; one that
fails compiles is `invalid` and excluded from both the numerator and
denominator of the score, not counted as caught.

The check runs **in process** by default: one analyzer, kept alive for the
whole run, re-resolving only the file each mutant changed. The alternative is
a fresh `dart analyze` process per mutant, which rebuilds the package's whole
element model every time to type-check one file. Over 384 mutants — 264 from
three pure-Dart packages in this repository, 120 from two Flutter ones — the
two agreed on every verdict, at 9–89ms per mutant against 1.2–2.2s. On a
whole-package run over `clock_anchor` (430 mutants) that took the run from
852s to 332s, with a byte-identical report.

"Compiles" means no diagnostic whose own severity is an error, whatever your
`analysis_options.yaml` re-rates it to. Mostly that is where `dart analyze`
draws its exit-code line too, but where a project re-rates a diagnostic the
two differ, both ways, each time with the in-process gate on the compiler's
side:

- a lint **promoted** to an error does not make a mutant invalid — it still
  compiles and runs, so it is still measured;
- a real compile error **downgraded** to a warning still does. `dart
  analyze` accepts that file, the compiler does not, and the resulting
  failure would otherwise read as `detected`.

Before anything is mutated, every target file that has mutants is put to
the gate as it stands — the same rule as the baseline test run, applied to
the gate. A gate that rejects a target's unmodified code would score every
one of its mutants `invalid`, which reads downstream as a file with nothing
to measure. The in-process analyzer can do that: it is the
`package:analyzer` this package was built with, not your SDK's own, and a
file using language features newer than it knows reads as broken. Such a
file is judged by `dart analyze` instead, with a note on stderr. If
`dart analyze` rejects it too — or there is no fallback, because you chose
the analyzer yourself — the run aborts before touching anything, as
`gate-rejects-unmodified`. The run cannot tell you why, and there are three
candidates: the analyzer cannot read the file; the analyzer's own
configuration rejects code that does compile — bare `flutter analyze` on
any lint, or `dart analyze` on a lint your options promote to an error;
or the file genuinely does not compile. The baseline only vouches for files
your tests load, so a broken file no test imports passes it and lands here.

To have your own analyzer command be the judge instead — its configuration,
its exit code — pass it, and pay a process per mutant for it. Its
configuration is exactly what then decides, including a downgraded error.
It reads files from disk, so each mutant is written into a copy of the
package for it to judge, never into the package itself:

```bash
dart run dart_mutants --analyze-command "dart analyze" \
  --test-command "dart test" lib/foo.dart
```

**`flutter analyze` needs `--no-fatal-infos --no-fatal-warnings` here.**
Without them its exit code fails on any info or warning, so a mutant that
compiles fine but trips a lint is thrown out as invalid. `statement_deletion`
trips one almost every time — it leaves a bare `;`, and `empty_statements`
flags it. Measured over 120 mutants of two Flutter packages, bare
`flutter analyze` rejected 42 valid ones; with both flags it agreed with
`dart analyze` on all 120. `dart analyze` needs no flags, for a Flutter
package too. The unmodified-file check above only catches this when the
file already trips a lint before it is mutated; a lint-clean file passes
it, and then loses its mutants one lint at a time.

## The timeout gate

A mutant can turn a normal loop into an infinite one — sometimes the most
real signal a mutation testing tool can produce. But `package:test`'s own
per-test timeout is cooperative, built on the event loop, and cannot
preempt a synchronous `while (true) {}` that never yields to it; this
package would then wait on the test process forever. Every run of a mutant
against a test file is bounded by a budget (below) and killed with
`SIGKILL` — which cannot be ignored — if it does not finish in time. A timed-out mutant is scored
`timeout`, not `detected`: a hang is not the same evidence as an assertion
actually catching the wrong output, and counting it as caught would inflate
the score the same way an uncompilable mutant would.

### The budget follows the baseline

A mutant gets a budget on each test file it runs against, worked out from
that test file's own unmutated run in this run (see *How a mutant runs*):
the larger of `--baseline-factor` (default 4) times that run, and that run
plus `--mutant-timeout` (default 30s) plus 30s. `--baseline-factor 0` turns
the multiple off and leaves the floor.

The extra 30s is `package:test`'s own per-test timeout. A test that awaits
forever fails at 30s under the test runner, which is a detection; killed at
that moment, the same mutant would read as `timeout`. A test file usually
runs in a few seconds, so its budget is usually the floor.

The unmutated run is one sample, and the factor is there for load: the
machine getting busier mid-run. The same unmodified suite, on a workstation
running several sessions at once, took 9s at its quietest and 29s at its
busiest, a 3.2× spread; 3 would not have covered that, so the default is 4.

A budget that is too small does not fail safe. A timeout moves the score in
either direction (see the output contract below), but one harm is certain:
a mutant that would have survived and timed out instead leaves both the
score and the undetected list, which is the survivor a caller most needed
to see. A budget that is too large costs time on mutants that genuinely
hang, each of which runs for the full budget, and memory (see below).

The report's `mutantTimeoutSeconds` is `--mutant-timeout`, the part of the
floor a caller sets. Each mutant's own budget is in its result, as
`timeoutSeconds`: the budget on the test file that decided it.

The baseline itself gets `--baseline-timeout`, ten times `--mutant-timeout`
by default, and so does each test file's compile and its unmutated run. The
baseline used to get the mutant budget, so a green suite whose cold run took
longer than one mutant's floor aborted the whole run as `baseline-timeout`,
as if it had hung. Its only job is to tell a suite that finishes from one
that does not.

### The kill goes to the whole process tree

A mutant runs in a `flutter_tester` or `dart` process this package starts
itself, but the baseline and the coverage pass run your test command, and
`flutter test` is three processes, not one — the `flutter` wrapper spawns
`dartaotruntime`, which spawns the `flutter_tester` engine that actually runs
the test. A signal to the wrapper does not propagate downward, and POSIX
reparents an orphan to init rather than killing it, so killing the direct
child left the engine **running the mutant's infinite loop forever**, with
nothing that would ever reap it. That was found when mutants still ran
through `flutter test`; every process this package starts is killed the
same way.

Measured: one such orphan sat at 1.86 GB at the moment of the kill and 2.25 GB
three seconds later — roughly 130 MB/s, indefinitely, from a single timed-out
mutant. It outlives the run that created it, so the cost accumulates across
runs and does not come back when this binary exits. Two runs exhausted a
workstation's memory.

The tree is snapshotted before anything is killed (the parent link is the only
thing connecting it, and killing the root destroys it) and then killed
**top-down**. Leaves-first was tried and measured worse: `flutter_tools` is a
supervisor, so killing the tester while its parent is still alive makes the
parent spawn a replacement, which the arriving kill then orphans. Any process
that still survives is named on stderr rather than left to leak silently.

`SIGINT`/`SIGTERM` take every running test process and compiler down the
same way, so a Ctrl-C mid-run is not a second route to the same leak.

### Your timeout is also your memory budget

The budget bounds how long a runaway mutant runs *before* the kill, and a
mutant that allocates inside its loop allocates for that whole window. At
the default floor, about a minute for a fast test file, that is a bounded
spike; at a 300s budget, whether set through `--mutant-timeout` or derived
from a 75s test file, the same mutant has five times as long to grow. Raising the budget to resolve timeouts
is the right move for score accuracy (see the output contract below) and it
buys that accuracy with peak memory — worth knowing before raising it on a
machine that is also running other suites.

## `--fail-fast` is accepted, and does nothing

Earlier releases recommended putting `--fail-fast` in the test command, so
each mutant's run of the suite stopped at the first failure. Mutants no
longer run the test command (see *How a mutant runs*), so there is nothing
for it to shorten. It is accepted and ignored: each compiled test file runs
to completion, and a mutant is settled as soon as one of its test files
fails, without running the rest.

`--no-pub` still helps under `flutter test`, for the runs that do use your
command: the baseline and, under `--select-by-coverage`, the coverage pass,
which is one run per test file. Without it every invocation re-checks
dependencies first: measured at 0.17s a run on a small package here, and
0.5–0.6s on a single test file of a consuming app.

## `--select-by-coverage`: run only the tests that reach the mutant

Without the flag, every mutant runs against every test file the command
runs, until one of them fails. Most of those runs can't reach the mutant at
all, and a mutant no test reaches runs against every one of them before it
survives.

With `--select-by-coverage`, each test file is run once with coverage on,
after the baseline, and that records which test files entered which
functions. Each mutant then gets one of three answers, about the **function
it sits in**:

- **some test files entered it** — it runs against only those;
- **no test file entered it** — the mutant is scored `undetected` without
  running anything, and marked `uncovered`: it needs a test that reaches the
  function at all, not a better assertion;
- **coverage cannot say** — the mutant runs against every test file, as it
  would without the flag, and is not marked `uncovered`. That covers code outside any function (field and
  top-level initializers), a `const` constructor (its initializers run at
  compile time), and a file no report mentions (one with no executable code
  is absent even when every test loads it).

**Why the function and not the line.** The VM instruments calls and
function entries, not statements. Measured: `final s = b ? 'x' : g();`, run
with `b` true, is reported at **zero** hits, because its only instrumented
point is the call it skipped, and the `return s;` under it is not reported at
all. A line-level answer called the ternary swap on that line uncovered; a
test catches it. A function's entry is always instrumented.

The coverage pass is `dart test` once, or `flutter test` once per test file,
since `flutter test` writes one combined report per run. It needs a
`--test-command` of `dart test …` or `flutter test …` whose test files it
can list exactly as the runner would. The commands it would refuse — one
that collects coverage itself, uses `--`, runs on a platform other than the
VM, or carries an argument it cannot place, and a `dart_test.yaml` that
sets `filename`, `include` or a platform, or `paths` for a command that
names none — are refused before the baseline now, since a switched run
can't take them either (see *How a mutant runs*). `flutter test` is also
refused when a test imports `lib/` by relative path, since its coverage
drops that copy of the file; `dart test` handles it by collecting coverage
unfiltered. A run in the pass that fails is run once more before the pass
gives up. That refusal, or a pass that still fails, aborts the run before
the first mutant, as `selection-unavailable`, rather than run every mutant
against every test file: on a large suite that is a run many times longer
than the one asked for — measured, 41 of 831 mutants in over four hours.
Under `flutter test`, a file containing `coverage:ignore` comments also
runs its mutants against every test file: those comments delete lines from
the report, and can delete a function's entry.

**It can only err low.** A test that fails in a selected test file fails
when every test file runs too, so selection can lose a detection and not
invent one. A selected test file in which no test runs, because the
command's filters leave none, passes and decides nothing, as it would among
the others under the test command. The known ways selection loses a
detection:

- a mutant that changes a declaration's inferred type can break the
  compilation of a test file that never enters its function. Run against
  every test file, that failure reads as `detected` — a detection by compile
  error, the kind the gate exists to keep out of the score;
- code reached only from a subprocess or `Isolate.spawnUri`, whose coverage
  the test runner does not collect;
- code whose execution depends on timing or randomness, which one coverage
  pass can miss.

The saving grows with how many test files a mutant's scope loads against how
few of them enter its function, and with how many mutants sit in functions no
test enters, which run nothing at all.

## How a mutant runs

Every mutant runs as a switched file; there is no other way. `dart test` and
`flutter test` compile every test file they run, every time — 2–3.5s a file
on a large app even when nothing changed — so when mutants ran through the
test command, one that 30 test files reach spent over a minute compiling
before any test ran. Here each test file is compiled once for the whole run.

Every mutant of a target file that the gate accepts is written into that
file at once, each behind a switch read from the `DART_MUTANTS_ID`
environment variable:

```dart
if (a > b) …    →  if ((_dmOn(3) ? (a >= b) : (a > b))) …
save();         →  if (_dmOn(7)) { ; } else { save(); }
```

Unset, the file behaves as it did. The switch sits on the whole expression
around the mutant, not just the part it changes, so a null check that
promotes a variable later in the same expression stays in one piece. The
switched file has to pass the gate whole; a mutant that stops it compiling,
typically one whose switch hides a null check that later code relies on, is
left out of it.

Each test file the mutants need is then compiled once, with the compiler the
test runner itself keeps running — Flutter's frontend server under
`flutter test`, the Dart SDK's, targeting the VM, under `dart test` — and
the result is started directly, in `flutter_tester` or the `dart` VM: once
with no mutant, which has to pass, and then once per mutant that runs
against that file, with that mutant's id. The verdict comes from the exit
code:

- 0 on every one of a mutant's test files: `undetected`;
- anything else on any of them: `detected`, and its other test files aren't
  run. A crash or a load failure is a failed test under the test runner
  too;
- not finishing within the budget (see *The budget follows the baseline*):
  `timeout`.

**Compiled alone.** Some mutants can't be switched: one in a constant
context, a whole local declaration, a statement that has to stay a block (a
function's own body, say), a bare `$name` in a string, any mutant of a part
file, and one that stops the file compiling beside the others. Each of those
is written into the copy as it is, and each of its test files is compiled
again around it and run. The compiler is told exactly which files changed
since its last compile, so it never runs a stale one. A test file that no
longer compiles with the mutant in is a `detected`, as a load failure is a
failed test under the test command. That costs a compile per test file, for
those mutants only; the statistics count them in `switched.alone`, with why
in `switched.aloneReasons`.

All of it happens in temporary copies of the package (see *Running mutants
in parallel*), so the package is never written to, and the copies go with
the run's other temporary directories, on an interrupt too. One test file's
compiled program is about 100MB on a large app, so each worker keeps only
one on disk at a time.

Measured with 0.8.0, which ran mutants this way under `flutter test` and
`--select-by-coverage` and sent the rest through `flutter test`, on a
consuming app's review run, 172 mutants across 23 files with the baseline
and coverage map taken from an earlier run's journal: the mutants took
1,079s, with 116 of them switched, 34 test files compiled in 35s in all, and
their unmutated runs 22s. 0.7.0 scored the same code's mutants at about 45s
each, which is about 5,400s for the 120 that ran. Of the 95 mutants both
runs scored, 93 got the same verdict; the other two timed out there and were
`detected` here. Peak memory, the run's own process and its analyzer
included, was 3.0GB, the resident compiler about 1GB of it.

**It runs a test file the way the test runner would.** A compiled test file
starts in `package:dart_mutants/switched_suite.dart`, which reads the same
configuration the test runner does: the global file (`DART_TEST_CONFIG`, or
`~/.dart_test.yaml`), the package's `dart_test.yaml`, and the test command's
own filtering options. It reads the test file's suite-level annotations —
`@Tags`, `@Timeout`, `@Skip`, `@TestOn`, `@OnPlatform` — and applies the
include and exclude tags and the name filters. Under `flutter test` it also
wraps the test in the nearest `flutter_test_config.dart`, as `flutter test`
does, and compares golden files without updating them. A test skipped or
filtered out under the test command is skipped or filtered out here too. So
the package under test has to resolve `package:dart_mutants` — have it in
`dev_dependencies`, which running it with `dart run` needs anyway — and,
under Flutter, `package:flutter_test`.

The test command's options fall into three groups:

- passed on to every compiled test file: `-n`/`--name`,
  `-N`/`--plain-name`, `-t`/`--tags`, `-x`/`--exclude-tags`, `--timeout`,
  `-P`/`--preset` and `--run-skipped`;
- ignored, since they only shape reporting or how many files run at once, or
  only end a failing run sooner: `-j`/`--concurrency`, `-r`/`--reporter`,
  `--file-reporter`, `--no-pub`, `--color`, `--no-color`, `--fail-fast`,
  `--chain-stack-traces` and `--no-chain-stack-traces`;
- anything else, such as `--dart-define` or `--total-shards`, stops the run.

**What stops the run before the baseline**, as `switched-run-unavailable`,
with nothing run: a command that isn't `dart test …` or `flutter test …`; one
that uses `--`, collects coverage itself, runs on a platform other than the
VM, names no `*_test.dart` file, or carries an argument it cannot place
(such as `test/a_test.dart?name=x`); an option from the third group above; a
`dart_test.yaml` that sets `filename`, `include` or a platform, or `paths`
for a command that names none; a target file outside the package; a package
that doesn't resolve `package:dart_mutants` (and `package:flutter_test`
under Flutter); and a missing SDK piece, such as `flutter_tester`, where the
reason says to run `flutter precache`. Under Flutter, `flutter_tester`
exists for macOS and for Linux on x64 and arm64 only.

**What stops it after.** Each test file has to compile, and pass with no
mutant on, before any mutant runs against it. One that doesn't, though the
test command passed with it, stops the whole run as `switched-run-failed`,
naming the file, and nothing is scored: a run that doesn't run what the test
command runs would read every mutant as detected.

**What it leans on.** The flags the compiler, `flutter_tester` and the
`dart` VM are started with are copied from what the test runners pass, and
`switched_suite.dart` uses libraries of `package:test_core` and
`package:test_api` that are not public. None of these is a stable
interface. This package pins `test_core` and `test_api` to the ranges it was
built against, but an SDK upgrade can still change the rest. When one of
them changes, a test file fails to compile or fails unmutated, and the run
stops as `switched-run-failed`, naming that file. It does not score
mutants against the wrong tests.

## Running mutants in parallel

`--workers N` (`-j N`) runs N lanes at once. Each lane has its own copy of
the package, its own compiler and its own test process. Lanes take test
files from a shared queue — each one compiled, run unmutated, and then run
against every switched mutant still waiting on it — and then the mutants
compiled alone. The package itself is never written to, at any number of
workers, 1 included.

A lane's copy is a sandbox made of symbolic links, in which only the target
files are real copies. The directories on the way to them, and every
directory under `lib/` and `test/`, are real directories full of links.
Every other top-level directory is one link, top-level files are copied
(tools rewrite some of them in place), and `.dart_tool/` holds a package
config that resolves the package to the sandbox. `build/`, `.git/` and,
under `flutter test`, the platform directories are left out.

So a sandbox costs a few kilobytes of its own, plus the test entry it
compiles. The compiled program goes to a work directory of its own. Each
sandbox is deleted with the run's other temporary directories, and the
statistics record how much each one held at the end.

The compile-safety gate is shared: the default in-process analyzer judges a
mutant's content in memory, one question at a time, so a mutant that does not
compile is never written anywhere. `--analyze-command` reads the mutant from
a copy of the package kept for it alone.

A copy the tools can't work in fails the unmutated run of the first test
file a lane takes, which stops the run as `switched-run-failed` (see *How a
mutant runs*). There is no fallback to running in the package.

Memory is usually the limit, not processors: under Flutter, a lane's
compiler and its `flutter_tester` can take a gigabyte or two each.

Don't expect N times the speed: the lanes compete for the same cores and
memory, and how much they win on a switched run has not been measured here
yet. The baseline and the coverage pass still run once, in the package,
before the lanes start.

## Run statistics

Every report carries `stats`: what the run cost and where the time went, so
the next change to this package, or to a suite, can be measured against
real runs instead of guessed at. `--history <path>` appends each run's
whole report, statistics included, to a JSON Lines file. Aborted runs are
appended too. A run of a few thousand mutants adds on the order of a
megabyte, so prune the file as you see fit.

```bash
dart run dart_mutants --select-by-coverage \
  --output build/mutation.json --history .mutation/history.jsonl \
  --test-command "flutter test" lib/foo.dart
```

`stats` holds:

- `startedAt`, `finishedAt` (UTC) and `wallSeconds`;
- `environment`: this package's version, the Dart version, the OS, the
  processor count, the test command, the timeout options and the operators;
- `loadAverage` at `start` and `end` (1-, 5- and 15-minute), where the OS
  gives one. The same suite has taken 9s and 29s on one machine depending on
  what else ran, so a slow run needs this to be read at all;
- `phases`: `baselineSeconds`, `gateCheckSeconds` (every target put to the
  gate unmodified), `coveragePassSeconds` and `mutantsSeconds`. A phase that
  did not run is absent;
- `workers`: how many lanes ran the mutants;
- `switched`, when any mutant ran a test: how many mutants were `switched`
  and how many compiled `alone`, with `aloneReasons` counting why;
  `compiledTestFiles`; `switchSeconds` (writing the switched files),
  `compileSeconds` and `unmutatedSeconds` (the test files' unmutated runs);
  and `workerDiskBytes`, what each lane's copy held of its own at the end;
- `verdicts` and `operators`: count and seconds for each, and for each
  operator its verdicts. `uncovered` is counted apart from `undetected`;
- `selection`: `selectedMutants`, how many mutants ran against test files
  coverage chose;
- `mutants`: one entry per mutant, `detected` ones included, with its
  location, operator, verdict, the `worker` (lane) that settled it,
  `seconds`, `gateSeconds`, whether it was `selected`, and `testSeconds` and
  `timeoutSeconds` where they apply.

The statistics are for comparing runs. They are not part of the output
contract below: keys may be added.

## What this package does not decide

Which files to run against, how big a mutant budget to spend, what
detection rate is acceptable, and what a surviving mutant's write-up should
look like are policy — that lives one layer up, in whatever calls this. The
contract here is a file list and a test command in, per-file
detected/undetected/invalid/timeout counts and the actual undetected,
invalid, and timed-out mutants out.

## The output contract

These eight are guaranteed, not incidental — a caller with its own
pass/fail policy (a per-file threshold other than "zero undetected", for
instance) depends on all eight, and each is covered by a test against the
real CLI binary, not just the internal report types:

- **`--json` always prints a complete report to stdout, and `--output`
  always writes one to its file, even when the exit code is non-zero** — an
  aborted run, or any file with undetected mutants. The file is written
  through a temporary sibling and a rename, so it never holds half a report.
  Nothing about this binary's own exit-code opinion suppresses the report a
  caller needs to read to form its own.
- **A file with zero candidate mutants still appears in `files`**, at
  `total: 0`. "This file had no mutants" and "this file was never passed
  in" are different facts; only the JSON, not the exit code or the absence
  of a key, can tell a caller which one happened.
- **`invalid` and `timeout` stay in the per-file output**, not folded into
  `total` or summed away. A file where most candidates ended up `invalid`
  or `timeout` has a hollow-looking 100% the same way a file with only one
  real mutant does — comparing either against `total` is how a policy layer
  catches that, so both are reported, not just counted internally.
- **A timed-out or invalid mutant is reported with its identity**, in
  `timedOutMutants` and `invalidMutants`, alongside their counts. Comparing
  either count against `total` tells a caller THAT something was excluded
  from the score and never WHICH, so on its own a count is a number nobody
  can act on: you cannot see which line, whether it is the same mutant every
  run, or go and look at it.

  Measured, twice, for two different reasons. A file carried a mutant that
  timed out on *every* round, was therefore never scored once, and stayed
  invisible behind that count. Separately, a report reading `invalid: 27`
  with no per-file breakdown left a caller unable to name even one of the 27
  without spending a whole extra mutation run to reverse-engineer which
  lines they were — an invalid mutant is not legal code and was never going
  to move the score, but the gate rejecting it is still a fact about that
  line, and a bare integer cannot say which ones, or surface an operator
  that is consistently misfiring against one file.

  A timeout specifically is excluded from the numerator *and* the
  denominator, so it moves the score in **either** direction and you cannot
  tell which without running the mutant: had it been detected, excluding it
  lowers the score; had it been undetected, excluding it raises one. (An
  invalid mutant carries no equivalent ambiguity — it was never legal code,
  so it was never going to land on either side.) Both measured, on two files
  of one consuming PR — 71% with a timeout at a 90s budget against 75% with
  none at 300s (the mutant resolved to detected and rejoined the
  denominator), and, in the direction that shipped, a file reading **PASS
  100% with two of its three mutants timed out** at the 30s default, which
  reported FAIL 33% at 90s once all three scored. A percentage computed from
  one surviving mutant is not a percentage — and catching that is a policy
  layer's job, not this one's: it is the caller who knows what threshold it
  is gating on and can therefore tell that a thin denominator has not
  measured anything. Raising the budget is not a substitute for the list: it
  identifies the mutant only when the timeout disappears, and tells you
  nothing at all about one that genuinely does not terminate.
- **A path comes back exactly as it was passed in.** Paths are echoed, never
  normalised — pass `lib/foo.dart` and the report says `lib/foo.dart`; pass
  it absolute and the report says it absolute. This matters more than it
  looks, because `files` is *keyed* by that path: a caller checking that
  every file it asked for came back has to compare the same form it sent, and
  one that assumes either form will silently match nothing. Echoing is the
  only behaviour that lets a caller use its own paths as lookup keys without
  this package deciding what a path should look like.
- **An aborted run says which kind of abort it was, in `abortKind`** —
  `baseline-timeout`, `baseline-failed`, `gate-rejects-unmodified`,
  `over-budget`, `selection-unavailable`, `switched-run-unavailable` (the
  mutants can't run as switched files; found before the baseline, nothing
  run), `switched-run-failed` (a test file didn't compile or pass
  unmutated in the switched run, though the test command passed with it)
  or `stopped` (`dart_mutants stop`, `SIGTERM` or Ctrl-C ended it).
  Branch on that, never on `abortReason`, whose wording is for people and is
  free to change. The kinds call for opposite responses — a red suite needs
  fixing, a slow one needs a bigger `--baseline-timeout`, a rejected file
  needs a look at both the file and the analyzer judging it, a refused
  command needs a different command — so a caller that guesses the
  kind from the prose gets
  the advice backwards the day the prose is reworded, and nothing goes red
  to say so. New kinds may be added; an existing name is never renamed.
- **The budget each mutant got is in the report.** Every mutant that ran a
  test carries its own, `timeoutSeconds`: the budget on the test file that
  decided it, derived from that file's unmutated run (see *The budget
  follows the baseline*). It is not the `--mutant-timeout` a caller passed,
  and a caller reading `timedOutMutants` needs to know what they timed out
  against. An `invalid` or `uncovered` mutant ran nothing and has no
  `timeoutSeconds`. Beside them, `mutantTimeoutSeconds` is the
  `--mutant-timeout` the floor was built from, and `baselineSeconds` the
  test command's wall time against unmodified code. Both are present on
  every run whose baseline passed; a red baseline has only
  `baselineSeconds`, and a baseline that never finished, or a run stopped
  before it, has neither.
- **A survivor no test ran is marked as one.** Under `--select-by-coverage`
  an undetected mutant in a function no test enters carries
  `uncovered: true`, and each file counts them in `uncovered`, a subset of
  `undetected` — the score is unchanged. `selectedByCoverage` on every
  completed run says whether selection happened; a run that asked for it
  and could not have it aborts instead of completing without it.

## Known limitations

- **A verdict is not perfectly reproducible, and the error is one-sided.**
  Observed once, before 0.9.0, when mutants still ran through the test
  command: two runs of the same 430-mutant corpus, same inputs, differed on
  one mutant. The outlier said `detected` where hand-checking proved the
  mutant `undetected` — and a second mutant in the same run, deleting the
  *enclosing* `if` rather than its body and so semantically identical, was
  scored `undetected` in that very run. It did not reproduce: 0 failures in
  500 runs of unmodified code and 0 spurious failures in 150 targeted runs of
  exactly that mutant. The cause is **unknown**, and whether the way mutants
  run now can produce it has not been measured.

  What makes it worth a bullet rather than a shrug is the **direction**.
  This package reads any non-zero exit as `detected`, so a spurious failure
  can only ever move a score *up*, never down. Treat a single run's
  percentage as carrying a small one-sided error. One free signal is already
  in the report: two mutants that are *semantically the same edit* must score
  the same, so when they do not, one verdict is wrong. That is how this one
  surfaced — deleting a `return null;` was reported caught, while deleting
  the whole `if` whose entire body was that `return` was not. Re-run the pair
  to find out which.

  This only works when the two really are equivalent, which containment alone
  does not make them. Deleting `if (a > b) { … }` and mutating its `>` to
  `>=` perturb different inputs, so a suite covering only `a == b` can
  legitimately catch one and miss the other — that pair disagrees for a good
  reason and is not evidence of anything.
- **Every run rests on symbolic links.** Mutants run in copies of the
  package (see *Running mutants in parallel*) made of links, at any number
  of workers. This package never writes through one, but a tool or a test
  that writes to a linked file in place would write to the package itself;
  the known ones are handled (top-level files are copied, platform
  directories left out, golden files compared and never updated), and a
  copy the tools cannot work in stops the run, but a stray write is not
  caught. A test that updates a checked-in file should not run under this
  package. Runs are untested on Windows, where creating a link can need
  extra privileges, and a Flutter package has no `flutter_tester` to run on
  there at all.
- **`SIGKILL` cannot be caught.** `SIGINT`/`SIGTERM` kill every running
  test process and compiler and delete the run's temporary directories
  before exiting (tested against the real CLI binary, not simulated); no
  process can catch `SIGKILL`, so a `kill -9` or a timeout wrapper
  configured to skip straight to it is still a real gap, and there it leaves
  orphaned processes behind. It can't leave a mutated file: the package is
  never written to. The temporary directories recover too: each is named
  `dart_mutants_<pid>_…`, and the next run deletes those whose pid is no
  longer running.
- **Process enumeration is `ps`.** The tree kill needs it. On a platform
  without `ps` this says so on stderr and degrades to killing the direct
  child, which is the pre-0.2.3 behaviour and leaks a `flutter test` engine.
- **Command splitting is whitespace-only.** `--test-command`/
  `--analyze-command` are split on whitespace; an argument that itself needs
  a literal space is not supported yet.
- **Equivalent mutants are not detected.** `statement_deletion` can delete a
  statement that provably changes nothing — a trailing bare `return;` in a
  void function is the common one. Recognising those needs flow analysis this
  package does not do, so they surface as survivors for a person to dismiss
  rather than being filtered out on a guess. A caller gating on a percentage
  should expect a small floor of these.
- **A green baseline is not proof that tests assert anything.** The
  pre-flight check confirms the test command exits 0 against unmodified
  code, and `dart test` and `flutter test` both exit 79 when no test ran at
  all, which aborts as `baseline-failed`. A suite that runs tests asserting
  nothing passes it, and every mutant survives, so the file scores 0% and
  this binary exits 1. A caller that wants this *named* rather than merely blocked should treat
  "zero detected across every file" as ambiguous between "the suite asserts
  nothing" and "the suite never ran". Those are indistinguishable from this
  report, and this package does not guess between them.
- **No per-project operator selection.** `defaultOperators()` is a flat list;
  every operator runs on every file. A caller wanting to stage the deletion
  and negation operators in gradually would be the reason to build a config
  layer, which does not exist yet.
