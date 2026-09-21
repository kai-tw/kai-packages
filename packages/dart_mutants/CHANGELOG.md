## 0.3.0

**How long the run will take, before and during it.** The plan line now
reads as time too: every mutant at one baseline, divided over the workers.
It is an upper bound — a mutant the compile-safety gate rejects runs no
test, and a selected command runs a fraction of the suite — so every
progress line carries a measured `left` beside its own elapsed time: the
pace held since the first mutant, over the mutants still to come. `RunPlan`
gains `workers`, `estimate` and `floor`; `MutantProgress` gains
`projectedRemaining`.

**`--max-minutes <n>` stops a run that will not fit, scoring nothing.** A
plan whose floor — every worker busy, nothing rejected, no selection — is
already over the limit is refused before a file is written. Past that the
measured pace is compared against it, once enough mutants have finished for
that pace to mean anything, and the run stops between mutants with the tree
restored. The new abort kind is `over-budget`.

There is no dry-run mode to estimate against instead: the count and the
pace both need the baseline, which is the run's own first step, so a
counting pass would run the suite an extra time to learn what the run
learns on the way past. The limit covers the mutants alone — the baseline,
the coverage pass and the sandbox check are what make the estimate
possible.

## 0.2.9

**Under `--select-by-coverage`, a selected run gets a budget measured
against its own tests.** Before this, every mutant got the full suite's
budget, even one running a two-second selection. On one consuming app's
250-file run, with a 190s baseline, each of eight hanging mutants waited out
760s, about 18% of 9.4 hours. Now the first mutant that needs a selection
runs it once against unmodified code, and the budget is that time times
`--baseline-factor`, never less than `--mutant-timeout` and never more than
the full command's budget. Mutants sharing the selection reuse it. A
selection that does not pass unmodified keeps the full budget, and so does
the full-command retry after a selected exit 79. With the factor at 0 no
measurement is made.

- Every mutant that ran a test now carries `timeoutSeconds` in the JSON: the
  budget its last run had. `mutantTimeoutSeconds` stays, as the full
  command's budget.

**Progress while it runs.** After the baseline, stdout gets one line with
the number of mutants and files and the budget, then one line per mutant as
it finishes: `[12/3709] detected lib/foo.dart:10:5 ternary_swap (4.2s)`.
Mutants are listed once per run; they used to be listed a second time for
each file as it ran. The runner exposes the same lines as the `onPlan` and
`onProgress` callbacks.

**`--output <path>` writes the JSON report to a file**, aborted runs
included, through a temporary sibling and a rename. stdout keeps the
progress and the text report. A path naming a directory is refused before
anything runs, with exit 64.

**Run statistics, kept across runs.** Every report now carries `stats`:
start and end times, the environment (this package's version, Dart, OS,
processors, the test command and options), the load average at the start
and end, time per phase, count and time per verdict and per operator, what
selection cost, and a timing entry for every mutant, `detected` ones
included. `--history <path>` appends each run's report to a JSON Lines
file, aborted runs included. See *Run statistics* in the README.

**`--workers N` runs mutants in parallel, without copying the package.**
Each worker gets a sandbox made of symbolic links, where only the target
files are real copies, and the package itself is never written to while
more than one worker runs. A sandbox holds a few kilobytes of its own plus
what the test command builds there (46MB of `build/` for `flutter test` on a
small Flutter package). Before the workers start, the full test command runs
once in one sandbox against unmodified code, and a run whose sandbox fails
that check falls back to one worker, in place, saying why. The default is 1,
which runs as before. See *Running mutants in parallel* in the README.

- The in-process compile-safety gate now judges a mutant's content in
  memory, one question at a time, so it can serve every worker, and a
  mutant that does not compile is never written to disk.
- Statistics add `workers`, each sandbox's disk use, the sandbox setup time
  and, per mutant, the `worker` that ran it.

**Temporary directories are always cleaned up.** The coverage pass's
report directory used to be left behind when a run was interrupted with
`SIGINT` or `SIGTERM`. Every temporary directory now goes through one
owner and is deleted at the end of a run, on an interrupt too, and each
is named `dart_mutants_<pid>_…`. A run that was killed outright (`kill
-9`) cannot clean up after itself, so each run starts by deleting the
directories left by earlier runs whose pid is no longer running. A
directory whose run is still going is left alone.

`--json` is unchanged apart from the added `stats`: the JSON report on
stdout, and no progress lines, so stdout still parses as a whole. The text report's timed-out lines now name
the budget they ran out of.

## 0.2.8

No behaviour change to a run.

**No more `// coverage:ignore` blocks in this package's own source.** The
three branches they hid are now run in process by a test:

- `MutatedFileRegistry` takes optional `watchSignal` and `exitProcess`
  functions, defaulting to `ProcessSignal.watch` and `exit`. A test delivers a
  signal and checks the restore → `beforeExit` → exit(1) order, and makes
  SIGTERM unwatchable to reach the warning path.
  `test/runner/signal_restore_test.dart` still covers the real signal in a
  subprocess.
- `ProcessCommand`'s process-table read takes the `ps` call as a parameter
  (`processTableForTest`), so the no-`ps` fallback is tested too.

How the tool treats `coverage:ignore` comments in the code it mutates is
unchanged.

## 0.2.7

**`--select-by-coverage` runs each mutant against only the tests that
reach it.** Measured on a consuming app's real mutation scope, 44 test files
and 314 tests, one `flutter test` took 23–24s, of which 22.3–22.7s was
loading and compiling the 44 test files. The tests themselves barely
registered, and every mutant paid for every file whether or not any of them
could reach it.

With the flag, each test file runs once with coverage on after the baseline
(`dart test` in one run; `flutter test` once per file, since it writes one
combined report per run), recording which test files entered which
functions. Each mutant then runs only the test files that entered the
function it sits in. A mutant in a function no test entered is scored
`undetected` without a run, and marked `uncovered`. A mutant coverage
cannot speak for — outside any function, in a `const` constructor, or in a
file no report mentions — runs the full command.

**Functions, not lines, because the VM's line coverage undercounts.**
Measured: `final s = b ? 'x' : g();` run with `b` true is reported at zero
hits, since its only instrumented point is the call it skipped. An early
line-level version of this change called the ternary swap on such a line
uncovered while a test catches it; a function's entry is always
instrumented. A regression test pins this, and fails against the
line-level version.

A test that fails in a selected run fails in the full command too, so
selection can lose a detection but not invent one. A selected outcome that
is neither a pass nor a failed test, such as exit 79 when the chosen files
ran no test at all, is re-asked of the full command. Known ways a detection
is lost: a mutant that changes an inferred type and breaks the compilation
of a test file that never enters its function; code reached only through a
subprocess or `Isolate.spawnUri`; code that runs only sometimes.

Selection is refused wherever the coverage pass could see different tests
than the full command runs, with a note on stderr and
`selectedByCoverage: false`: a `--test-command` that is not `dart test …`
or `flutter test …`; one that collects coverage itself, uses `--`, runs off
the VM, or has an argument that is neither a known option's value nor an
existing path; a `dart_test.yaml` setting `filename`, `include`, a platform,
or `paths` for a command naming none; under `flutter test`, a test that
imports `lib/` by relative path; and a coverage pass that fails, writes no
report, or writes one in an unexpected shape. Under `flutter test` a file
with `coverage:ignore` comments runs its mutants in full, since those
comments can delete a function's entry from the report.

Measured on three packages in this repository, in two rounds, with every
verdict identical mutant by mutant (full → selected, round 1 / round 2):
`clock_anchor` (430 mutants, `dart test`) 343s → 281s / 328s → 236s;
`log_system` (182, `flutter test`) 317s → 174s / 260s → 185s; `ui_kit`
(243, `flutter test`) 556s → 145s / 356s → 103s, where 118 of 132 survivors
are in functions no test enters and are no longer run. Machine load moved
the full runs by up to 200s between rounds, so compare within a round. A
large app's scope has not been measured with the flag yet.

The report gains `uncovered` on a mutant and a per-file count of them
(inside `undetected`; the score is unchanged), and `selectedByCoverage` on
every completed run, `false` included.

Also documented: `flutter test --no-pub` skips a dependency check on every
invocation — 0.17s a run on a small package here, 0.5–0.6s on one test file
of a consuming app.

**The compile-safety gate now runs in process by default.** Every mutant
used to cost a fresh `dart analyze` process, which rebuilt the package's
entire element model to type-check the one file that changed. The gate now
keeps a single analyzer alive for the run and re-resolves what changed. How
much of a run that saves depends on how expensive the test command is next
to it; the one end-to-end measurement below is a pure-Dart package with a
fast `dart test`.

Measured against the gate it replaces, over 384 mutants: 264 across three
pure-Dart packages in this repository and 120 across two Flutter ones, where
`dart:ui` and `package:flutter` resolve like any other dependency. The two
agreed on every verdict, at 9–89ms per mutant against 1.2–2.2s. End to end,
the real CLI over `clock_anchor`'s whole `lib/` (430 mutants) went from 852s
to 332s and produced a byte-identical JSON report. (An earlier build of this
change measured 360s. That 8% gap is inside the spread of three identical
runs of this same package on this same machine, reported further down in
this entry: 856s to 938s.)

What changes for a caller:

- **Passing nothing** now gets the in-process gate. `--analyze-command` no
  longer defaults to `dart analyze`.
- **Passing `--analyze-command`** keeps the old behaviour exactly: that
  command, once per mutant, judged by its exit code.
- **What counts as compiling differs where a project re-rates a
  diagnostic**, in both directions and each time on the compiler's side. The
  in-process gate judges each diagnostic on its own severity, so a lint that
  `analysis_options.yaml` **promotes** to an error no longer makes a mutant
  invalid — it compiles and runs, so it is now measured — while a real
  compile error that it **downgrades** to a warning now does. The second is a
  fix: `dart analyze` accepted such a file, the compiler does not, and the
  test command's failure was read as `detected`. A project that re-rates
  diagnostics can see mutants move between `invalid` and the score in
  either direction. Both are pinned by tests against both gates; no package
  in this repository re-rates anything, so the corpus above could not have
  exercised either.
- **Every target file with mutants is put to the gate unmodified, before
  anything is mutated** — the rule the baseline test run already applies to
  the test command, applied to the gate. A gate that rejects a target's
  unmodified code would score every one of its mutants `invalid`, which
  reads downstream as a file with nothing to measure. The in-process gate
  can hit this: it is the
  `package:analyzer` this package resolved, not the SDK's own analyzer, and
  a file using language features newer than that analyzer knows reads as
  broken. Reproduced with a primary constructor on a 3.13 SDK — every mutant
  `invalid` in process, `2/3 detected` with one real survivor under
  `dart analyze`. Such a file is now judged by `dart analyze`, with a note on
  stderr. With `--analyze-command` there is no fallback, and a gate that
  rejects an unmodified file aborts the run before anything is touched. So
  does a file both gates reject — which can also mean the file itself does
  not compile, since the baseline only vouches for files a test loads.

**An aborted run now says which kind of abort it was**, in a new `abortKind`
field: `baseline-timeout`, `baseline-failed`, or `gate-rejects-unmodified`
for the abort the item above adds. The kinds call for opposite responses,
and a downstream caller was telling them apart by matching words in
`abortReason` — which the new kind would have slipped past, landing on the
"fix your suite" advice for a problem that is not in the suite. `abortKind`
is part of the output contract; `abortReason` is for people and is not. The
existing reason texts keep the words a caller was matching on in this
release (the baseline-timeout one gains a number and a hint, below), so a
caller still matching on them keeps working until it moves to the field.

`flutter analyze` was documented as a valid `--analyze-command` and is not,
as-is. Its exit code treats infos and warnings as fatal, so it rejects a
mutant that compiles fine but trips a lint, and this package reads that as
`invalid`. `statement_deletion` trips one almost every time — it leaves a
bare `;`, and `empty_statements` flags it. Over 120 mutants of two Flutter
packages, bare `flutter analyze` threw out 42 valid mutants; with
`--no-fatal-infos --no-fatal-warnings` it agreed with `dart analyze` on all
120. The README, the CLI help and the gate's doc now say so. Nothing that
invoked this package without `--analyze-command` was affected. The
unmodified-file check above catches a misconfigured `flutter analyze` only
when the file already trips a lint before mutation; the flags are still what
fixes it.

**A slow green suite no longer aborts as if it had hung, and each mutant's
budget now follows the baseline.** The baseline ran under `--mutant-timeout`,
so a suite whose cold run took longer than one mutant's budget aborted the
whole run as `baseline-timeout`. Its code comment already called it the
longest run of the session. What changes:

- **`--baseline-timeout`** is the baseline's own budget, ten times
  `--mutant-timeout` by default. The abort text still says the command "did
  not finish ... within the timeout", now with the number of seconds and a
  hint to raise this flag. The other side of that trade: a suite that
  genuinely hangs now takes 300s to abort at the defaults, not 30s.
- **`--baseline-factor k`**, default 4: each mutant gets the larger of
  `--mutant-timeout` and `k ×` the baseline's wall time in this run. This
  can make the budget larger than the `--mutant-timeout` a caller passed,
  which is the point; `0` restores the flat budget. The multiple is for load
  drift, not for a cold-versus-warm compile: under `dart test` the kernel
  cache is cleared before the baseline and every mutant alike. One
  unmodified suite on a workstation running several sessions at once spread
  3.2× between its quietest and busiest runs, which 3 would not have
  covered.
- **The report carries `baselineSeconds` and `mutantTimeoutSeconds`**, part
  of the output contract, so a caller reading `timedOutMutants` knows what
  they timed out against.

A budget that is too small is not the safe side: a mutant that would have
survived and timed out instead is dropped from the score and from the
undetected list both.

The three findings below are documentation only — no behaviour change. They
come from measuring where a mutation run's time actually goes, and are written
down so the next person does not have to re-run them. One of the three is a
null result and is labelled as one. Every figure in those three is from one
package: `clock_anchor` — 26 files at the time, 430 mutants, pure Dart,
`dart test`. None of them was measured against a Flutter package or against
any other consumer, so read the ratios rather than the seconds.

**`--fail-fast` belongs in your test command, and the gain is this package's
rather than the flag's.** This package reads nothing but the
test command's exit code, so every test that runs after the first failure is
waste. Measured on `clock_anchor` over 40 detected mutants, timing the test
command alone: mean wall time per run fell from 1.03s to 0.80s. Measured the
same way but with 0.2.6's clearing suppressed, the same flag takes the same
suite from 0.81s to 12.54s — the sign inverts. Why is not established; four
wall-clock means cannot establish a mechanism.

Nothing this package exposes can suppress the clearing, so the recommendation
stands unconditionally for a caller here. It is reported because it locates
the benefit: it belongs to this package's cold-every-run inner loop rather
than to `--fail-fast`, and does not transfer to a mutation runner that reuses
its kernel cache. The README now says so beside the recommendation.

**Clearing `.dart_tool/test/` once per file instead of once per mutant was
measured, and the experiment could not tell the two apart.** Six full runs
across four frequencies (per-mutant ×3, per-file, never, and keeping the
cache but forcing invalidation through the file's mtime) produced five
byte-identical verdict files, all four frequencies among them. That is a null
result, not a refutation of per-file: on this corpus per-file was exactly as
correct as per-mutant, and cheaper. The reason it proves nothing in either
direction is that the corpus had no *verified* positive control: the one
mutant known to be sensitive — `NtpPacket.kissCode`, which motivated 0.2.6 —
scores `detected` today even with the cache never cleared. Whether any of the
other 429 would have discriminated the frequencies is not something six
identical verdict files can separate from "the bug is gone"; that ambiguity
is the null result, not an explanation of it.

The saving itself is softer than one number suggests. Per-mutant is the mean
of three runs — 856s, 872s, 938s — so the within-condition spread is about as
wide as the effect, and per-file is a single run at 793s. Every per-mutant run
was slower than every non-per-mutant run (793s, 797s, 803s), so the direction
is solid; the magnitude is not. Against per-file's 793s the three per-mutant
runs give 7.4%, 9.1% and 15.5%, so "~11%" is only the gap between the means,
and measuring the fastest per-mutant run against `never` instead drops the
floor to 6.2%.

The per-mutant clearing is **kept**, and not because the measurement
vindicated it. It stays because what the runs establish is narrow: 0.2.6's
false negative does not reproduce on this package, on this SDK, with the one
mutant known to have caught it no longer sensitive — which is not the same as
the bug being gone.

Worth stating plainly, because it cuts against keeping it: 0.2.6's bug was
**score-deflating**, not inflating. A killed mutant scored `undetected` reads
the detection rate *low*. And this package's own 0.2.1 entry argues that
deflation is the self-correcting direction — "an under-count reads as 'write
more tests' and nobody files it, while the inflating direction is the one that
silently passes a gate". So the guard being kept here protects against the
less dangerous of the two directions, and the case for keeping it is caution
about a bug that has not been shown to be gone, not the severity of the
direction it guards. Buying the 11% honestly needs a corpus containing a
mutant the frequencies actually disagree on.

One thing these runs did **not** re-test: whether `flutter test` populates
this directory. 0.2.6 inferred that it does not — from an absence, no
`log_system` run having reproduced the false negative — and on that basis
treated the clearing as free for a Flutter consumer. Every run here was
`dart test` against a pure-Dart package, so that inference stands exactly
where 0.2.6 left it, neither firmer nor weaker.

**A verdict is not perfectly reproducible, and the error is one-sided.** Two
runs of the same corpus, same inputs, differed on one mutant of 430; the
outlier scored `detected` where hand-checking against a cold cache proves the
mutant is `undetected`, and an equivalent mutant deleting the enclosing `if`
was scored `undetected` in that same run. It has not reproduced — 0 failures
in 500 runs of unmodified code, 0 spurious failures in 150 targeted runs of
that exact mutant, 0 non-assertion failures across three instrumented full
runs. One flip in six runs of 430 is the only denominator available, so
~1 in 2,600 mutant evaluations; 0 in 150 bounds the per-mutant rate no
tighter than a few percent. Cause unknown, and with n=1 there is nothing to
attribute it to: the flip landed in a per-mutant-clearing run, but three of
the six runs were per-mutant, so that is where chance would put a single
event anyway — and it was also the first run executed, which is an equally
available confound. The clearing is not ruled out; neither is it implicated.
It is in the known limitations for the direction rather than the size: any
non-zero exit reads as `detected`, so a spurious failure can only move a
score up.

## 0.2.6

**Fixes a false negative**: a mutant that a project's real test suite
genuinely kills could be scored `undetected` anyway, silently, with no
indication anything was wrong.

Found against `clock_anchor`: a full 24-file run reported
`NtpPacket.kissCode`'s `if (byte < 0x41 || byte > 0x5A)` swapped to `&&` —
guarding against a hostile NTP reply injecting control characters into a log
line — as undetected. Applying that exact mutation by hand and running the
real suite directly failed two tests. Re-running this package against just
that one file in isolation scored it correctly.

Root cause: `dart test` (via `package:test`) keeps a persistent kernel under
`<package>/.dart_tool/test/incremental_kernel.*` to skip recompiling between
runs. This package's own inner loop — mutate one file to a small variant,
test, revert, mutate it again, over and over, very fast — is exactly the
pattern that cache's invalidation was never built against.

`TestCompilationCache` now deletes `.dart_tool/test/` before the baseline run
and before every mutant's test run. Unconditional, not narrowed to a specific
filename: a directory that is not there is a no-op, and `flutter test` does
not appear to populate this path at all, so this costs nothing for a Flutter
consumer. Every mutant becomes a cold compile instead of an incremental one —
accepted deliberately. This package's only product is the score, and a fast
wrong number is worse than a slow right one.

That cost showed up immediately in this package's own test suite —
subprocess-heavy fixture tests started missing their timeouts, mostly from
resource contention when several ran in parallel. `dart_test.yaml` now sets
`concurrency: 1` (confirmed, not guessed, to fix most of it: `-j 1` alone
resolved 10 of 12 failures) and `timeout: 4x` for the two that still needed
real headroom in isolation.

Re-ran the exact 24-file `clock_anchor` batch that exposed the bug as the
definitive check: `ntp_packet.dart` now scores `41/41` (was `40/41`), and
every other file's numbers are unchanged.

**No change to the CLI or JSON report shape** beyond what 0.2.5 already made,
and **no change to the engine version `plan-mutation` requires** — its floor
stays at 0.2.3. A caller who was already correct sees only a slower,
now-trustworthy run.

This package's own coverage and mutation score had never been measured
against itself before this release: 85.5% line coverage, 73.1% mutation,
below the bar every other package in this workspace is now held to. Brought
up to match — dedicated tests for the small report/data classes
(`MutantResult`, `MutationRunReport`, `FileMutationReport`,
`isGeneratedFile`), nested-construct recursion tests for the AST-walking
operators, `MutatedFileRegistry`'s `handleSignal()` extracted as a directly
testable seam, and new tests for `ProcessCommand.killAllRunning()`/
`toString()`/pipe-buffer draining and for `MutationTestRunner`'s
caller-supplied operator list, cache-clearing, and hung-baseline paths —
several confirmed empirically by reintroducing the target mutant and
watching the new test fail. What remains uncovered is a small, individually
justified set of process-boundary and platform-gated lines (a real
`SIGINT`/`SIGTERM` handler body, a Windows-only exception branch, a missing-
`ps` fallback) that cannot be reached from inside this process's own test
suite without either ending it or running on a platform this package is not
developed on; each carries a `coverage:ignore` naming exactly why.

## 0.2.5

`invalidMutants` — an invalid mutant is now reported with its identity, not
just counted. Behaviour is unchanged: the compile-safety gate still rejects
it before the test command ever sees it, it is still excluded from `total`,
and `invalid` still increments exactly as before. Only the report gained
something.

The same shape of gap `timedOutMutants` (0.2.1) closed, on the other bucket
this package excludes from scoring. A consuming session's report read
`invalid: 27` with no per-file breakdown — unlike `undetectedMutants` and
`timedOutMutants`, there was nothing to read off per mutant — and had to
fall back to guessing which lines from the shape of the file's code, calling
it out explicitly as a reasonable guess rather than a verified one, because
naming them for real meant spending a whole extra mutation run just to
reverse-engineer which ones they were.

`FileMutationReport`'s doc used to argue the asymmetry was the point: an
invalid mutant is not legal code and never needed measuring, so there was
supposedly nothing there to go and look at. That conflated two different
questions. Whether an invalid mutant should move the score is a scoring
question, and the answer stays no — `total` is unchanged. Whether its
identity is worth keeping in the report is a different, reporting question,
and the answer is yes for exactly the reason it is yes for a timeout: a bare
count cannot tell a caller — or an agent reading the report — a handful of
unrelated one-off rejections from one operator consistently misfiring
against a single construct in one file, and it cannot point at a single
line to go check.

`invalidMutants` carries the same shape as `timedOutMutants` — file, line,
column, operator, description — via the same `MutantResult`. The CLI's text
output gains a matching `invalid (NOT scored):` line alongside the existing
`undetected:` and `timed out (NOT scored):` ones.

## 0.2.4

Docs only; no behaviour change, and **no change to the engine version
`plan-mutation` requires** — its floor is 0.2.3 and stays there.

The 0.2.1 entry claimed "a gate was passed by a file whose tests killed one
mutant in three". That was wrong, and it was wrong when it was written rather
than overtaken by a later fix: `plan-mutation` already scored a timeout both
ways (worst — all survive; best — all kill), already called the verdict
`undetermined` when the threshold fell between them, and already exited
non-zero on the resulting LOW-SIGNAL row.

How it got written is worth keeping, because it is the failure mode that entry
is *about*. The wrapper had been read — for its report handling — and the exit
code was simply never looked at. The claim was reasoned from this engine's
number straight to a consequence in a layer this package does not own, in a
file already open.

What actually happened, from that layer's own record: the row was **labelled
correctly** and shipped anyway, because the label was prose and only an exit
code is enforcement. The label was never the defect.

So the entry now says the escape is closed, and says the part that did not
change: **the number this engine reports is still wrong in exactly the same
way.** Catching a thin denominator is a policy layer's job, because only the
caller knows what threshold it is gating on — this package deliberately makes
no pass/fail judgement, and that division is the reason the correction reads
as better layering rather than a smaller defect.

## 0.2.3

**A timed-out mutant no longer leaks a runaway test process.** This is the
release to take if you run mutation testing on a machine you also work on.

`flutter test` is three processes, not one: the `flutter` wrapper spawns
`dartaotruntime`, which spawns the `flutter_tester` engine that actually runs
the test. The timeout gate SIGKILLed the direct child, and a signal does not
propagate downward — POSIX reparents an orphan to init rather than killing it.
So the engine survived, went on executing the mutant's infinite loop, and
nothing would ever reap it.

Measured, on the real `flutter test` shape rather than argued from POSIX: one
orphan sat at **1.86 GB at the moment of the kill and 2.25 GB three seconds
later** — roughly 130 MB/s, indefinitely, from a **single** timed-out mutant.
It outlives the run that created it, so the cost accumulates across runs and
does not come back when this binary exits. Two runs exhausted a workstation's
memory, which is how it was found.

The kill now takes the whole process tree. Three details are load-bearing:

- **The tree is snapshotted before anything is killed.** The parent link is
  the only thing connecting the descendants, and killing the root destroys it.
- **They are killed top-down, root first.** Leaves-first was tried and
  measured *worse*: `flutter_tools` is a supervisor, so killing the tester
  while its parent is still alive makes the parent do its job and spawn a
  replacement, which the arriving kill then orphans. The leak survived that
  first attempt, one process smaller — the survivor check below is what caught
  it, on the first real run.
- **Any process that still survives is named on stderr.** A descendant started
  between the snapshot and the kill is missed by construction, and the whole
  point of this release is that such a leak must not be silent. The check
  polls rather than sampling once: a 50 ms sample reported a survivor that was
  in fact already gone, and a warning that cries wolf on every timeout is one
  nobody reads.

**`SIGINT`/`SIGTERM` now kill the in-flight test command too.** Ctrl-C reached
the identical state by a different route — the handler restored files and
called `exit`, leaving the test command it had started running with nobody to
reap it. The signal watch is also armed *before* the baseline run now, which
is the longest single command of a session and was previously outside it.

Both paths are covered against the real CLI binary with real signals, not
simulated. The timeout test carries a deliberate companion assertion that the
fixture genuinely orphans when only the direct child is killed — without it, a
fixture that never spawned a grandchild would pass the real test for the wrong
reason.

Two limits stated rather than hidden: process enumeration is `ps`, so a
platform without it degrades to the old single-process kill and says so on
stderr; and `SIGKILL` to this binary itself still leaks in both directions at
once, because nothing can catch it.

Also documents, in the README, that **`--mutant-timeout` is a memory budget as
well as a time budget**. A mutant that allocates inside its loop allocates for
the whole window, so raising the budget from 30s to 300s to resolve timeouts —
which is the right move for score accuracy — buys that accuracy with peak
memory. Worth knowing before doing it on a machine running other suites.

## 0.2.2

Docs only; no behaviour change.

The 0.2.1 entry below claimed "Measured, on one file, both ends of that" and
then measured one end. The deflating case was real; the inflating one — a
timeout excluded from the denominator raising a score — was reasoning in a
measurement's clothes, in an entry whose whole subject is a defect that hides
by looking measured.

The missing half is now in that entry, from the same consuming PR: a file that
reported PASS 100% at the 30s default with TWO OF ITS THREE mutants timed out,
scoring 1/1 off the one that finished and was killed, and FAIL 33% at 90s once
all three ran. That is the end that shipped — nobody questioned the 100%,
while the 71% got reported, which is the asymmetry the entry asserts happening
to the entry itself. (Present tense in this sentence was itself wrong; see
0.2.4 — the policy layer blocks that row now, and did then.)

Both ends are now attributed as two files of one PR rather than implied to be
independent runs. The README's output-contract section carries the same
correction, plus the line the second case earns: a percentage computed from
one surviving mutant is not a percentage.

## 0.2.1

`timedOutMutants` — a timed-out mutant is now reported with its identity, not
just counted. Behaviour is unchanged: the timeout fires at the same second,
the mutant is still killed, still scored `timeout`, still excluded from
`total`. Only the report gained something.

The count alone was unactionable, and two consuming sessions hit that in one
day. `timedOut: 1` says something went unmeasured without saying WHICH — so
nobody can see the line, tell whether it is the same mutant every run, or go
and look at it. The failure that motivated it: a file carried a mutant that
timed out on EVERY round, was therefore never scored once, and stayed
invisible behind a number no caller reads per-mutant. Its own file kept
reporting a healthy-looking score.

`FileMutationReport`'s doc used to claim that comparing `timedOut` against
`total` is how that gets caught. That was half true — the comparison finds
THAT, never WHICH — and this list is the other half.

`invalid` deliberately gets no equivalent list, and the asymmetry is the
point: an invalid mutant is not legal code and never needed measuring, while
a timed-out one is real code that went unmeasured. Only the second is a gap.

**A timeout moves the score in EITHER direction, and which one is unknowable
without running the mutant.** It is excluded from the numerator and the
denominator both, so:

- had it been detected, excluding it **lowers** the score;
- had it been undetected, excluding it **raises** it.

Both ends measured, on two different files of one consuming PR:

- **Deflating.** At a 90s budget one file reported FAIL 71% with one timeout;
  at 300s the same file reported FAIL 75% with none, because the mutant
  resolved to *detected* and rejoined the denominator. The reported 71% was an
  under-count of a real 75%.
- **Inflating, and this is the one that shipped.** Another file reported
  **PASS 100%** at the 30s default with *two of its three mutants timed out* —
  the single mutant that finished had been killed, so the score was 1/1. At
  90s, with all three scored, the same file reported FAIL 33%.

  It shipped because the policy layer labelled the row LOW-SIGNAL correctly
  and then exited 0 on it, so the discipline lived only in prose. **That
  escape is closed** — `plan-mutation` now scores a timeout both ways (worst:
  all survive; best: all kill), calls the verdict `undetermined` when the
  threshold falls between them, and exits non-zero on a LOW-SIGNAL row. The
  number this engine reports is still wrong in exactly the same way; what
  changed is that the layer whose job is pass/fail now catches it, which is
  the correct division of labour — a thin denominator is a policy judgement,
  and this package deliberately makes none.

That asymmetry is why the defect went unreported for so long: **an under-count
reads as "write more tests" and nobody files it**, while the inflating
direction is the one that silently passes a gate. Same mechanism, and only one
of its two symptoms is uncomfortable enough to chase — which is exactly why the
100%-at-two-timeouts case sat unquestioned and the 71% got reported.

**Raising `--mutant-timeout` is not a substitute for this list.** It works
only when the timeout was a budget problem and disappears — then you can diff
two runs and see which mutant flipped. Against a genuine non-terminating
mutant it tells you nothing at any budget, and that is precisely the case
where knowing which one matters most.

Also fixes a flake in this package's own suite. The integration fixture ran
with a 5s mutant timeout; alone it passed, inside the full suite the BASELINE
run — the cold one, competing with every other test file — exceeded it and
seven tests failed. Raised to 10s. A suite whose job is measuring whether
other suites are trustworthy cannot be the flaky one. Total runtime went DOWN
(52s to 26s): the failures were spending the full timeout before giving up.

## 0.2.0

Four new operators, closing the half of the mutation space the initial
release deliberately left to a tool that no longer runs: `statement_deletion`
(one statement replaced with an empty `;`), `condition_negation`
(`if (x)` -> `if (!(x))`, skipping conditions `relational_operator_replacement`
already covers), `logical_operator_replacement` (`&&` <-> `||`), and
`arithmetic_operator_replacement` (`+` <-> `-`, `*` <-> `/`).

The first four operators all ask "is this expression's branch or boundary
pinned?" — they presume a line runs and probe which way it went. None of them
asks whether a line's effect is asserted at all, so a guard like
`if (mounted) { setState(...) }` — no ternary, no `??`, no comparison —
produced zero mutants and reported a clean score for code nothing measured.
Measured one construct per file under 0.1.0: an `if` guard, `&&`/`||`, plain
statements, and `n - 1` each produced ZERO.

This is not a change of mind about scope. 0.1.0 was scoped to complement a
regex-based mutator running alongside it, which is why the README said
`&&`/`||` were "deliberately not reimplemented". That mutator was then
*replaced* by this package rather than joined by it (`plan-mutation`'s own
script records both the replacement and the removal of its flags), so the
coverage it contributed left with it. The scope never changed; the
arrangement it was scoped against did.

**Expect existing scores to drop.** These operators generate mutants current
suites do not kill, so a file's percentage will fall — that is the first
honest measurement of it, not a regression. A caller gating on a per-file
threshold should expect to revisit that threshold, or stage the rollout.

The output contract gains a fourth guarantee: **a path comes back exactly as
it was passed in**, echoed rather than normalised. This was always the
behaviour and was never written down, so a caller had to infer it — and one
inferred it wrong, keying its report lookup on absolute paths against a run
that had passed relative ones, which matched nothing. `files` is keyed by
that path, so the form has to match; it is now documented and covered by a
CLI test asserting both directions.

Two integration fixtures were rewritten rather than having their expected
counts raised: they exist to isolate one mutant each so the gate-mechanics
assertions stay sharp, and bumping counts would make them churn on every
future operator. `test/operators_test.dart` is a new regression guard
asserting that each previously-blind construct is now reachable by some
operator.

## 0.1.0

Initial release. AST-based mutation testing, built to cover exactly what a
regex-based mutator cannot see: the ternary, a switch expression's arms, and
`??` — plus the comparison operators the regex tool gave up on rather than
risk mangling a generic type parameter. Four operators (`ternary_swap`,
`switch_expression_arm_swap`, `null_coalescing_deletion`,
`relational_operator_replacement`), a compile-safety gate that keeps a
mutant that fails to compile from ever being counted as "detected", a
`--mutant-timeout` gate that keeps a hung mutant from being counted as
"detected" either (or from hanging the whole run — `package:test`'s own
timeout cannot preempt a synchronous infinite loop, so this package kills
the subprocess itself), signal-safe restore on `SIGINT`/`SIGTERM` (tested
against the real CLI binary with a real signal, not simulated), a
red-baseline pre-flight check, and a JSON output contract of per-file
detected/undetected/invalid/timeout counts plus the actual undetected
mutants — guaranteed to print in full even when the exit code is non-zero,
and to include a file with zero candidate mutants rather than omit it.
Every one of those output-contract guarantees is covered by a test against
the real CLI binary, following review from the peer session this package
was commissioned by.

Deliberately out of scope for this release: parallel execution (see the
README's "Known limitations"), and any policy about which files to run
against, budget, or pass/fail thresholds — that stays one layer up.
