part of 'versioned_json_schema.dart';

/// How one document fared against its schema's migration: brought to the
/// current version, or left alone, and why.
///
/// Private to the library: [_VersionedJsonMigrationCurrentOutcome] holds the
/// document the schema parses, and the reason a document was left alone is
/// decided where its version is read, so no reader outside the library reads
/// the version again to work it out.
sealed class _VersionedJsonMigrationOutcome {
  const _VersionedJsonMigrationOutcome();
}

/// The document, at the current version.
final class _VersionedJsonMigrationCurrentOutcome
    extends _VersionedJsonMigrationOutcome {
  const _VersionedJsonMigrationCurrentOutcome(
    this.json, {
    required this.storedVersion,
  });

  final Map<String, dynamic> json;

  /// The version the stored document declares, which a refusal of the
  /// migrated document still reports — the file on disk is that version.
  final int storedVersion;
}

/// A version above the current one: a newer build wrote it, and this build
/// may neither read it nor write over it.
final class _VersionedJsonMigrationNewerOutcome
    extends _VersionedJsonMigrationOutcome {
  const _VersionedJsonMigrationNewerOutcome({required this.storedVersion});

  final int storedVersion;
}

/// A version below 1, which no build has written: not a document this build
/// can recognise at all.
final class _VersionedJsonMigrationInvalidOutcome
    extends _VersionedJsonMigrationOutcome {
  const _VersionedJsonMigrationInvalidOutcome({required this.storedVersion});

  final int storedVersion;
}

/// Not a document of this file: text that is not UTF-8 or not JSON (an
/// empty file included), JSON that is no object and that the schema does
/// not recognise as an unversioned shape, or a version that is no integer.
final class _VersionedJsonMigrationMalformedOutcome
    extends _VersionedJsonMigrationOutcome {
  const _VersionedJsonMigrationMalformedOutcome();
}
