import '../mutant.dart';

/// One mutant the check accepted, with the test files it runs against — what
/// a `SwitchedRunner` runs.
class SwitchedJob {
  const SwitchedJob(this.id, this.mutant, this.source, this.tests);

  /// Unique within the run; the value `DART_MUTANTS_ID` takes.
  final int id;
  final Mutant mutant;

  /// Its file's unmodified content.
  final String source;

  /// Relative to the package, sorted; never empty.
  final List<String> tests;
}
