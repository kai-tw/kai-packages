import 'dart:io';

import '../versioned_json_dto.dart';
import '../versioned_json_migrator.dart';
import '../versioned_json_schema.dart';
import 'json_file_atomic_writer.dart';
import 'versioned_json_migrator_io.dart';

/// Reads and writes a schema's DTO as a JSON file.
extension VersionedJsonSchemaIo<T extends VersionedJsonDto>
    on VersionedJsonSchema<T> {
  /// Migrates [file] in place (see [VersionedJsonMigratorIo.migrateFile]) and
  /// parses the result.
  ///
  /// Returns null exactly when `migrateFile` does: no file, or no JSON object
  /// in it. Its version exceptions and [FileSystemException]s propagate, and so
  /// does anything [fromJson] throws.
  Future<T?> readFile(File file) async {
    final Map<String, dynamic>? json = await migrator.migrateFile(file);
    return json == null ? null : fromJson(json);
  }

  /// Writes [dto] to [file], replacing its content atomically.
  ///
  /// The version written under [VersionedJsonMigrator.versionKey] is
  /// [VersionedJsonDto.schemaVersion], set here rather than trusted to
  /// `toJson`: a generated serialiser skips a getter, and JSON without the key
  /// reads back as version 1 and is migrated again over current data.
  ///
  /// Throws an [ArgumentError], writing nothing, when [dto] is not at
  /// [currentVersion]: an older shape written as current is never migrated,
  /// and one written as its own version is taken for a legitimate older file.
  Future<void> writeFile(File file, T dto) async {
    if (dto.schemaVersion != currentVersion) {
      throw ArgumentError.value(
        dto.schemaVersion,
        'dto.schemaVersion',
        'must be the current version $currentVersion',
      );
    }
    await const JsonFileAtomicWriter().write(file, <String, dynamic>{
      ...dto.toJson(),
      VersionedJsonMigrator.versionKey: dto.schemaVersion,
    });
  }
}
