import 'versioned_json_dto.dart';
import 'versioned_json_migrator.dart';

/// Pairs one DTO type with the migrator for its format, so the two cannot be
/// mismatched: a schema for one DTO cannot be handed another format's migrator
/// without a type error.
///
/// The schema is the one place that knows both today's DTO and the migration
/// history. The migrator must not import the DTO (see
/// [VersionedJsonMigrator.migrateOneStep]); the schema imports both and turns
/// a migrated map into today's DTO.
///
/// ```dart
/// class NoteSchema extends VersionedJsonSchema<NoteDto> {
///   const NoteSchema();
///
///   @override
///   VersionedJsonMigrator get migrator => const NoteMigrator();
///
///   @override
///   NoteDto fromJson(Map<String, dynamic> json) => NoteDto.fromJson(json);
/// }
/// ```
abstract class VersionedJsonSchema<T extends VersionedJsonDto> {
  const VersionedJsonSchema();

  /// Brings older JSON of this format up to [currentVersion].
  VersionedJsonMigrator get migrator;

  /// The version this schema reads and writes, owned by [migrator].
  int get currentVersion => migrator.currentVersion;

  /// Parses JSON that is already at [currentVersion].
  T fromJson(Map<String, dynamic> json);

  /// Migrates [json] to [currentVersion], then parses it.
  ///
  /// The version exceptions of [VersionedJsonMigrator.migrateJson] propagate,
  /// and so does anything [fromJson] throws: a migrated map that today's DTO
  /// cannot parse is a defect in a migration step or in the DTO, not missing
  /// data.
  T readJson(Map<String, dynamic> json, DateTime modifiedAt) =>
      fromJson(migrator.migrateJson(json, modifiedAt));
}
