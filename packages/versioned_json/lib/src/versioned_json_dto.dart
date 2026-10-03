import 'versioned_json_migrator.dart';
import 'versioned_json_schema.dart';

/// A data transfer object whose JSON carries its own schema version.
///
/// An interface rather than a base class, so a generated data class (which
/// usually cannot extend anything) can still implement it.
abstract interface class VersionedJsonDto {
  /// The schema version this instance is shaped for. A DTO built to be written
  /// carries its schema's [VersionedJsonSchema.currentVersion].
  int get schemaVersion;

  /// Serialises this DTO, including [schemaVersion] under
  /// [VersionedJsonMigrator.versionKey]. Without that key the written JSON
  /// reads back as version 1 and is migrated a second time.
  Map<String, dynamic> toJson();
}
