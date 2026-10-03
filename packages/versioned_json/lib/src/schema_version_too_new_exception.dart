/// Raised when JSON declares a schema version above what this reader supports.
///
/// Newer data written by a newer build: it must be neither read with today's
/// shape nor overwritten, because the build that wrote it needs it back intact.
///
/// Carries only the two version numbers, never the JSON: the data usually
/// comes from storage this code does not control, and the message tends to
/// end up in a log.
class SchemaVersionTooNewException extends FormatException {
  const SchemaVersionTooNewException({
    required this.version,
    required this.supportedVersion,
  }) : super(
         'schema version $version is newer than the supported $supportedVersion',
       );

  /// The version the JSON declares.
  final int version;

  /// The highest version this reader can migrate to.
  final int supportedVersion;

  @override
  String toString() => 'SchemaVersionTooNewException: $message';
}
