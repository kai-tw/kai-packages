/// Checks for a consumer's own tests: that a `FieldwiseJson`'s `toJson` names
/// exactly the value fields, round-trips, and is canonical, and that every
/// migration step has a worked example.
///
/// Each check returns a list of human-readable mismatches rather than
/// asserting, so this library depends on no test framework:
/// `expect(fieldwise.keyMismatches(sample), isEmpty)`.
library;

export 'src/testing/fieldwise_json_testing.dart';
export 'src/testing/versioned_json_migrator_testing.dart';
export 'src/testing/versioned_json_step_example.dart';
