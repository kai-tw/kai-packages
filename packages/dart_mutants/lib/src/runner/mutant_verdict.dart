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
