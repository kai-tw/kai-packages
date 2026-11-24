/// What happened when one [Mutant] was run.
enum MutantVerdict {
  /// The compile check rejected it before the test command ever saw
  /// it: it doesn't compile, or it deletes a `super` call the analyzer
  /// requires (see `RequiredSuperCallCheck`). Excluded from both the
  /// numerator and denominator of a score — an invalid mutant is not
  /// evidence of anything, in either direction.
  invalid,

  /// The test command did not finish within the configured timeout and was
  /// killed. Excluded from the score, the same as [invalid] — not folded
  /// into `detected`, even though a hang often means the mutation did
  /// change behaviour (a genuine infinite loop): counting it as caught
  /// would let a hung test inflate the score the same way a mutant that
  /// fails to compile would, which is exactly the failure shape the
  /// compile check exists to prevent for that case. Not folded into
  /// `undetected` either — nothing actually ran to a real assertion, so
  /// there is no basis to call it a survivor.
  timeout,

  /// A process running the test command went over `--max-memory` and was
  /// killed. Excluded from the score, for the reason [timeout] is: from
  /// outside, two causes look the same. A mutant that deletes a
  /// `controller.close()` leaks until it is killed, and no test noticed,
  /// which is a gap. A mutant that turns a loop infinite while it allocates
  /// never reaches an assertion at all. Neither ran to a real verdict.
  ///
  /// Listed in the report all the same, so it isn't lost: when the cause is
  /// a release a test never checked, the fix is a test that checks it (for
  /// a Flutter object, `leak_tracker` turns a missing `dispose()` into a
  /// failing test), and then the mutant is [detected] before memory grows.
  overMemory,

  /// It compiles, and it changes nothing but a call to a declaration marked
  /// `@pragma('dart_mutants:diagnostic')` — see `DiagnosticCallCheck`. Never
  /// run, and excluded from the score like [invalid]: the only test that
  /// kills it asserts the diagnostic output itself. Not folded into
  /// [invalid], which means it was never legal code; this one is.
  diagnostic,

  /// The test command exited non-zero against a mutant that compiled: some
  /// test noticed. Counts toward the denominator and is good news.
  detected,

  /// The test command exited zero against a mutant that compiled: nothing
  /// noticed. Counts toward the denominator and is the number a mutation
  /// score exists to surface — some of these are real gaps, some are
  /// equivalent mutants no test suite could ever kill, and telling the two
  /// apart is a judgment call for whoever reads the report, not this tool.
  undetected,
}
