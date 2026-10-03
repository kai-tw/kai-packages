import 'dart:convert';
import 'dart:io';

import '../versioned_json_dto.dart';
import '../versioned_json_migrator.dart';
import '../versioned_json_schema.dart';
import 'versioned_json_migrator_io.dart';

/// Reads and writes a schema's DTO as a JSON file.
extension VersionedJsonSchemaIo<T extends VersionedJsonDto>
    on VersionedJsonSchema<T> {
  /// Migrates [file] in place (see [VersionedJsonMigratorIo.migrateFile]) and
  /// parses the result.
  ///
  /// Returns null exactly when `migrateFile` does: no file, or no JSON object
  /// in it. Its version exceptions propagate, and so does anything [fromJson]
  /// throws.
  Future<T?> readFile(File file) async {
    final Map<String, dynamic>? json = await migrator.migrateFile(file);
    return json == null ? null : fromJson(json);
  }

  /// Writes [dto] to [file], replacing its content.
  ///
  /// [dto] must already be at [currentVersion]: a DTO in an older shape is
  /// written as it is, and the next read takes it for a legitimate older file
  /// and migrates it again. Its `toJson` must include
  /// [VersionedJsonMigrator.versionKey].
  Future<void> writeFile(File file, T dto) async {
    await file.writeAsString(jsonEncode(dto.toJson()), flush: true);
  }
}
