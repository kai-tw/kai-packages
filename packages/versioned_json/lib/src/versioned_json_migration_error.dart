part of 'versioned_json_schema.dart';

/// Thrown when a [VersionedJsonSchema] is asked for a migration step it does
/// not hold.
///
/// The library asks only for versions from 1 up to the one below the
/// schema's current version, so reaching this is a schema whose version was
/// raised without the step that reaches it — never something a stored file
/// can cause. A [StateError] rather than a [FormatException] for that reason:
/// a caller's `on FormatException` that skips bad input must not swallow a
/// programming error.
final class VersionedJsonMigrationError extends StateError {
  VersionedJsonMigrationError({
    required this.sourceVersion,
    required this.currentVersion,
  }) : super(
         'No migration step from schema v$sourceVersion '
         '(current v$currentVersion)',
       );

  /// The version a step was asked to migrate from.
  final int sourceVersion;

  /// The version the schema that was asked declares as current.
  final int currentVersion;

  @override
  String toString() => 'VersionedJsonMigrationError: $message';
}
