import '../versioned_json_migrator.dart';

/// One migration step's expected input and output, for
/// `VersionedJsonMigratorTesting.stepExampleMismatches`.
class VersionedJsonStepExample {
  const VersionedJsonStepExample({
    required this.before,
    required this.after,
    required this.modifiedAt,
  });

  /// JSON at the step's source version.
  final Map<String, dynamic> before;

  /// What the step must turn [before] into, including the new version under
  /// [VersionedJsonMigrator.versionKey].
  final Map<String, dynamic> after;

  /// Passed to the step as its `modifiedAt`.
  final DateTime modifiedAt;
}
