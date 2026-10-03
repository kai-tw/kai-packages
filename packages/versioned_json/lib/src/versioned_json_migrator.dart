import 'schema_version_invalid_exception.dart';
import 'schema_version_too_new_exception.dart';

/// Brings one persisted JSON format from any older schema version up to
/// [currentVersion], one step at a time.
///
/// One migrator per format, owning that format's whole history: [migrateJson]
/// loops from the JSON's own version to [currentVersion], calling
/// [migrateOneStep] once per transition.
///
/// The version lives under [versionKey]. A missing key reads as version 1, so
/// that JSON written before the format was versioned stays readable.
abstract class VersionedJsonMigrator {
  const VersionedJsonMigrator();

  /// The JSON key holding the schema version.
  ///
  /// Fixed rather than configurable: renaming it is a data migration, because
  /// every file already written would read as version 1.
  static const String versionKey = 'schemaVersion';

  /// The version [migrateJson] produces.
  ///
  /// A format that was already on disk before it carried a version starts at 2
  /// at the earliest: its unversioned files read as version 1 and need a 1→2
  /// step. A format that carried a version from its first write may stay at 1.
  ///
  /// Raising it from N to N + 1 means teaching [migrateOneStep] the N → N + 1
  /// transition.
  int get currentVersion;

  /// Transforms [source], which is at [sourceVersion], into the shape of
  /// `sourceVersion + 1`, and writes `sourceVersion + 1` under [versionKey] in
  /// the result. Nothing else stamps the new version: a step that leaves it out
  /// produces JSON that is migrated again the next time it is read.
  ///
  /// Called only with `1 <= sourceVersion < currentVersion`.
  ///
  /// **A shipped step is frozen.** Its job is to turn JSON written years ago
  /// into the shape the next version had *when that version shipped*. It must
  /// therefore work on maps alone and must not use today's DTOs or domain
  /// types, nor any helper they share: those keep changing, and a step built on
  /// them silently rewrites what an old file migrates into.
  ///
  /// [modifiedAt] is when the source was last written — a file's modification
  /// time, or the moment a downloaded copy arrived. A step uses it to
  /// synthesise timestamps for fields the source version did not record.
  ///
  /// A typical implementation dispatches on [sourceVersion]:
  ///
  /// ```dart
  /// @override
  /// Map<String, dynamic> migrateOneStep(
  ///   Map<String, dynamic> source,
  ///   int sourceVersion,
  ///   DateTime modifiedAt,
  /// ) {
  ///   return switch (sourceVersion) {
  ///     1 => _v1ToV2(source, modifiedAt),
  ///     2 => _v2ToV3(source),
  ///     _ => throw StateError('no step from version $sourceVersion'),
  ///   };
  /// }
  /// ```
  Map<String, dynamic> migrateOneStep(
    Map<String, dynamic> source,
    int sourceVersion,
    DateTime modifiedAt,
  );

  /// Returns [json] migrated to [currentVersion]. JSON already at
  /// [currentVersion] is returned as the same map.
  ///
  /// Throws [SchemaVersionTooNewException] when [json] is newer than
  /// [currentVersion], and [SchemaVersionInvalidException] when its version
  /// field is not an integer of at least 1. Both are [FormatException]s, so a
  /// caller that already skips malformed input skips these too. Neither leaves
  /// a caller anything it could safely write back.
  Map<String, dynamic> migrateJson(
    Map<String, dynamic> json,
    DateTime modifiedAt,
  ) {
    int version = readVersion(json);
    if (version > currentVersion) {
      throw SchemaVersionTooNewException(
        version: version,
        supportedVersion: currentVersion,
      );
    }
    Map<String, dynamic> current = json;
    while (version < currentVersion) {
      current = migrateOneStep(current, version, modifiedAt);
      version++;
    }
    return current;
  }

  /// The schema version [json] declares: 1 when [versionKey] is absent.
  ///
  /// Throws [SchemaVersionInvalidException] when the key is present but its
  /// value is not an integer of at least 1.
  static int readVersion(Map<String, dynamic> json) {
    if (!json.containsKey(versionKey)) {
      return 1;
    }
    final Object? raw = json[versionKey];
    if (raw is int && raw >= 1) {
      return raw;
    }
    throw const SchemaVersionInvalidException();
  }
}
