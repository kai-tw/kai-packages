/// Versioned JSON: persisted JSON that carries its own schema version and is
/// brought up to date one step at a time.
///
/// What is here:
///
/// * [VersionedJsonSchema] — one persisted format: its current version, the
///   steps from every older one, and the DTO today's shape parses into. Its
///   strict reads return the DTO or throw a [VersionedJsonReadException]
///   that says why not.
/// * [VersionedJsonFileSchema] — a [VersionedJsonSchema] for a file kept on
///   disk: lenient reads that answer `null` for a document this build may
///   not act on, atomic writes, and in-place migration of a file or a
///   directory.
/// * [VersionedJsonDto] — the marker interface every DTO implements.
/// * [VersionedJsonReadNewerException], [VersionedJsonReadUnknownCodeException]
///   and [VersionedJsonReadCorruptException] — the three ways a stored
///   document is refused, all [FormatException]s.
/// * [VersionedJsonMigrationException] — a schema asked for a step it does
///   not hold. No stored file causes it, so it is not a [FormatException].
/// * [FieldwiseJson] — copy chosen fields from one record into another, and
///   list which fields changed, through the record's JSON.
///
/// This library imports `dart:io`, so it does not run on the web. Checks for
/// a consumer's own tests are `package:versioned_json/testing.dart`.
library;

export 'src/fieldwise_json.dart';
export 'src/versioned_json_dto.dart';
export 'src/versioned_json_schema.dart';
