/// Versioned JSON: persisted JSON that carries its own schema version and is
/// brought up to date one step at a time.
///
/// What is here:
///
/// * [VersionedJsonMigrator] — reads the version, runs one step per version
///   transition, and refuses JSON newer than it understands.
/// * [VersionedJsonDto] and [VersionedJsonSchema] — pair today's DTO with the
///   migrator for its format, so a read is "migrate, then parse".
/// * [SchemaVersionTooNewException] and [SchemaVersionInvalidException] — the
///   two ways a version can be unreadable, both [FormatException]s.
/// * [FieldwiseJson] — copy chosen fields from one record into another, and
///   list which fields changed, through the record's JSON.
///
/// This library does no I/O and imports no `dart:io`. Reading and writing
/// files is `package:versioned_json/versioned_json_io.dart`; checks for a
/// consumer's own tests are `package:versioned_json/testing.dart`.
library;

export 'src/fieldwise_json.dart';
export 'src/schema_version_invalid_exception.dart';
export 'src/schema_version_too_new_exception.dart';
export 'src/versioned_json_dto.dart';
export 'src/versioned_json_migrator.dart';
export 'src/versioned_json_schema.dart';
