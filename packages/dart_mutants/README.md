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
dart run dart_mutants --json --test-command "dart test" lib/foo.dart
```

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
still makes the test command exit non-zero, which — read naively — counts
as "detected": a broken mutant would make the score go *up*, not down, for
a file the mutation never actually ran against. Every mutant is checked
against the analyzer before it is ever handed to the test command; one that
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
  analyze` accepts that file, the compiler does not, and the test command's
  resulting failure would otherwise read as `detected`.

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
configuration is exactly what then decides, including a downgraded error:

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
package's own subprocess would then wait on the test command forever. Every
mutant's test run is bounded by a budget (below) and killed with `SIGKILL` —
which cannot be ignored — if it does not finish in time. A timed-out mutant is scored
`timeout`, not `detected`: a hang is not the same evidence as an assertion
actually catching the wrong output, and counting it as caught would inflate
the score the same way an uncompilable mutant would.

### The budget follows the baseline

Each mutant gets the larger of `--mutant-timeout` (default 30s) and
`--baseline-factor` (default 4) times the baseline's own wall time in
this run. The report carries both numbers, `baselineSeconds` and
`mutantTimeoutSeconds`, so a caller can see what the budget actually was.
`--baseline-factor 0` turns the derivation off and leaves the flat
floor.

The baseline is one sample, and the factor is there for load, not for
compilation. Under `dart test` this package clears the kernel cache before
the baseline and before every mutant, so every run compiles from scratch and
`k × baseline` is not a generous allowance for a cold compile against warm
ones.
What it covers is the machine getting busier mid-run. The same unmodified
suite, on a workstation running several sessions at once, took 9s at its
quietest and 29s at its busiest, a 3.2× spread; 3 would not have covered
that, so the default is 4. How cold a `flutter test` run is between mutants
has not been measured here; the load argument applies either way.

A budget that is too small does not fail safe. A timeout moves the score in
either direction (see the output contract below), but one harm is certain:
a mutant that would have survived and timed out instead leaves both the
score and the undetected list, which is the survivor a caller most needed
to see. A budget that is too large costs time on mutants that genuinely
hang, each of which runs for the full budget, and memory (see below).

The baseline itself gets `--baseline-timeout`, ten times `--mutant-timeout`
by default. It used to get the mutant budget, so a green suite whose cold
run took longer than one mutant's floor aborted the whole run as
`baseline-timeout`, as if it had hung. Its only job is to tell a suite that
finishes from one that does not.

### The kill goes to the whole process tree

`flutter test` is three processes, not one — the `flutter` wrapper spawns
`dartaotruntime`, which spawns the `flutter_tester` engine that actually runs
the test. A signal to the wrapper does not propagate downward, and POSIX
reparents an orphan to init rather than killing it, so killing the direct
child left the engine **running the mutant's infinite loop forever**, with
nothing that would ever reap it.

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

`SIGINT`/`SIGTERM` take the in-flight test command down the same way, so a
Ctrl-C mid-run is not a second route to the same leak.

### Your timeout is also your memory budget

The budget bounds how long a runaway mutant runs *before* the kill, and a
mutant that allocates inside its loop allocates for that whole window. At
the 30s default that is a bounded spike; at a 300s budget, whether passed as
`--mutant-timeout 300` or derived from a 75s baseline, the same mutant has
ten times as long to grow. Raising the budget to resolve timeouts
is the right move for score accuracy (see the output contract below) and it
buys that accuracy with peak memory — worth knowing before raising it on a
machine that is also running other suites.

## `--fail-fast` belongs in your test command

Runtime is mutant count times one test run, so the cheapest thing a caller
can do is make that one run cheaper. This package only ever reads the test
command's **exit code**; every test that runs after the first failure has
already told it what it needed to know. Both `dart test` and `flutter test`
support stopping there:

```bash
dart run dart_mutants \
  --test-command "dart test --fail-fast" \
  lib/foo.dart
```

Measured on `clock_anchor` over 40 detected mutants, timing the test
command alone: mean wall time per run fell from **1.03s to 0.80s**, about a
fifth. It does nothing for an undetected mutant — that one runs the whole
suite either way — so the saving scales with your detection rate.

**That saving depends on something this package does, and does not
generalise.** Between mutants it deletes the test runner's incremental
kernel cache under `.dart_tool/test/`, so every run starts cold. Measured
the same way but with that deletion suppressed, the same flag takes the same
suite from 0.81s to **12.54s** — the sign inverts. Why is not established;
the measurement is four wall-clock means, and a run-to-run compilation
effect is the obvious suspect rather than a demonstrated cause.

Nothing exposed here can turn the deletion off, so the recommendation above
holds as written. It is worth knowing anyway, because it says the benefit is
a property of this package's inner loop rather than of `--fail-fast`: do not
carry the number over to a mutation runner that reuses its kernel cache.

## What this package does not decide

Which files to run against, how big a mutant budget to spend, what
detection rate is acceptable, and what a surviving mutant's write-up should
look like are policy — that lives one layer up, in whatever calls this. The
contract here is a file list and a test command in, per-file
detected/undetected/invalid/timeout counts and the actual undetected,
invalid, and timed-out mutants out.

## The output contract

These seven are guaranteed, not incidental — a caller with its own
pass/fail policy (a per-file threshold other than "zero undetected", for
instance) depends on all seven, and each is covered by a test against the
real CLI binary, not just the internal report types:

- **`--json` always prints a complete report to stdout, even when the exit
  code is non-zero** — an aborted run, or any file with undetected mutants.
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
  `baseline-timeout`, `baseline-failed` or `gate-rejects-unmodified`. Branch
  on that, never on `abortReason`, whose wording is for people and is free
  to change. The kinds call for opposite responses — a red suite needs
  fixing, a slow one needs a bigger `--baseline-timeout`, a rejected file needs a look at
  both the file and the analyzer judging it — so a caller that guesses the
  kind from the prose gets
  the advice backwards the day the prose is reworded, and nothing goes red
  to say so. New kinds may be added; an existing name is never renamed.
- **The budget each mutant got is in the report**, as
  `mutantTimeoutSeconds`, next to `baselineSeconds`, the baseline's wall time
  it was derived from. Neither is necessarily the `--mutant-timeout` a caller
  passed (see *The budget follows the baseline*), and a caller reading
  `timedOutMutants` needs to know what they timed out against. Both are
  present on every run whose baseline passed; a red baseline has only
  `baselineSeconds`, and a baseline that never finished has neither.

## Known limitations

- **A verdict is not perfectly reproducible, and the error is one-sided.**
  Observed once, and worth knowing before gating on a percentage: two runs
  of the same 430-mutant corpus, same inputs, differed on one mutant. The
  outlier said `detected` where hand-checking against a cold cache proves
  the mutant is `undetected` — and a second mutant in the same run, deleting
  the *enclosing* `if` rather than its body and so semantically identical,
  was scored `undetected` in that very run.

  It has not reproduced: 0 failures in 500 runs of unmodified code, 0
  spurious failures in 150 targeted runs of exactly that mutant, and 0
  non-assertion failures across three instrumented full runs — which is what
  a cache clear colliding with the test command's startup would have looked
  like. One flip in six full runs of 430 mutants is the only denominator
  there is, so call it 1 in ~2,600 mutant evaluations and note that a run of
  0 in 150 bounds the per-mutant rate no tighter than a few percent.

  The cause is **unknown**, and with one event there is nothing to pin it
  on. The flip landed in a per-mutant-clearing run — but three of the six
  runs were per-mutant, so a single event lands there by chance alone, and
  that run was also the first one executed. Three instrumented runs rule out
  one mechanism by which the clearing could produce it, which neither clears
  the clearing nor implicates it.

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
- **Sequential, not parallel.** Runtime is mutant count times one test run.
  Scoping to covered lines and running one file's mutants at a time in
  parallel are both real options for a project that needs it, deliberately
  not attempted here yet — a mutant applied to a shared file while another
  mutant's test run is in flight is a correctness risk this package has not
  solved, and a wrong number is worse than a slow one.
- **`SIGKILL` cannot be caught.** `SIGINT`/`SIGTERM` restore whatever is
  mutated and kill the in-flight test command's process tree before exiting
  (both tested against the real CLI binary, not simulated); no process can
  catch `SIGKILL`, so a `kill -9` or a timeout wrapper configured to skip
  straight to it is still a real gap — and there it leaks in both directions
  at once, leaving a mutated file on disk *and* an orphaned test process.
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
- **A green baseline is not proof that tests ran.** The pre-flight check
  confirms the test command exits 0 against unmodified code. It cannot
  confirm the command actually *executed* anything — that would mean parsing
  one specific runner's output, and this package deliberately accepts any
  `--test-command`. The case is contained rather than prevented: a baseline
  that runs nothing makes every mutant undetected, so the file scores 0% and
  this binary exits 1. Wrong for the wrong reason, but it stops rather than
  waving through. Reaching it takes a custom wrapper command, since `dart
  test` (exit 79) and `flutter test` both refuse loudly on no tests.
  A caller that wants this *named* rather than merely blocked should treat
  "zero detected across every file" as ambiguous between "the suite asserts
  nothing" and "the suite never ran". Those are indistinguishable from this
  report, and this package does not guess between them.
- **No per-project operator selection.** `defaultOperators()` is a flat list;
  every operator runs on every file. A caller wanting to stage the deletion
  and negation operators in gradually would be the reason to build a config
  layer, which does not exist yet.
