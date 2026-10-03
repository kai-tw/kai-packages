import '../json_deep_equality.dart';
import '../versioned_json_migrator.dart';
import 'versioned_json_step_example.dart';

/// Checks of a [VersionedJsonMigrator]'s steps, for a consumer's own tests.
extension VersionedJsonMigratorTesting on VersionedJsonMigrator {
  static const JsonDeepEquality _equality = JsonDeepEquality();

  /// Runs each example in [examples], keyed by source version, through
  /// [VersionedJsonMigrator.migrateOneStep] and returns human-readable
  /// mismatches, empty when every step from version 1 to
  /// [VersionedJsonMigrator.currentVersion] has an example and every example
  /// passes.
  ///
  /// A missing example is a mismatch, so raising the current version without
  /// adding an example for the new step fails the consumer's test.
  List<String> stepExampleMismatches(
    Map<int, VersionedJsonStepExample> examples,
  ) {
    final int lastStep = currentVersion - 1;
    return <String>[
      for (int version = 1; version <= lastStep; version++)
        if (!examples.containsKey(version))
          'no example for the step from version $version',
      for (final int version in examples.keys)
        if (version < 1 || version >= currentVersion)
          'example for version $version, but steps run from 1 to $lastStep'
        else
          ..._stepMismatches(version, examples[version]!),
    ];
  }

  List<String> _stepMismatches(int version, VersionedJsonStepExample example) {
    final Map<String, dynamic> output = migrateOneStep(
      example.before,
      version,
      example.modifiedAt,
    );
    const String versionKey = VersionedJsonMigrator.versionKey;
    final Object? written = output[versionKey];
    return <String>[
      if (written != version + 1)
        'step from version $version writes $versionKey $written, not ${version + 1}',
      for (final String key in _equality.differingKeys(output, example.after))
        if (key != versionKey)
          'step from version $version: key "$key" differs from the example',
    ];
  }
}
