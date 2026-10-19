part of 'versioned_json_schema.dart';

/// Why a [VersionedJsonSchema] refused a document: the stored document is
/// one this build may not act on.
///
/// The reason is decided where the check fails, inside the library, and
/// travels out as the variant: a newer build's document waits for an update,
/// a corrupt one does not. Each variant carries the version the stored
/// document declares, for the refusal to report, and never the document
/// itself: it usually comes from storage this code does not control, and the
/// message tends to end up in a log.
///
/// A [FormatException], so a caller that already skips malformed input skips
/// these too.
sealed class VersionedJsonReadException extends FormatException {
  const VersionedJsonReadException(super.message);
}

/// The document declares a version above the one this build's schema
/// reaches: a newer build wrote it.
final class VersionedJsonReadNewerException extends VersionedJsonReadException {
  const VersionedJsonReadNewerException({required this.storedVersion})
    : super('Document is schema v$storedVersion, newer than this build reads');

  final int storedVersion;

  @override
  String toString() => 'VersionedJsonReadNewerException: $message';
}

/// The document holds an enum code no member of this build's enum owns: a
/// newer build wrote that too. Read anyway, a default member would stand in
/// for the code and be written back over the newer value.
final class VersionedJsonReadUnknownCodeException
    extends VersionedJsonReadException {
  const VersionedJsonReadUnknownCodeException({required this.storedVersion})
    : super('Document holds an enum code this build does not know');

  final int storedVersion;

  @override
  String toString() => 'VersionedJsonReadUnknownCodeException: $message';
}

/// The document does not decode: not UTF-8, not JSON (an empty file
/// included), JSON that is no object, a version that is no integer or is
/// below 1, or a field that is missing, of the wrong type or fails to parse.
final class VersionedJsonReadCorruptException
    extends VersionedJsonReadException {
  const VersionedJsonReadCorruptException({this.storedVersion})
    : super('Document does not decode');

  /// `null` when the document did not decode far enough to declare one.
  final int? storedVersion;

  @override
  String toString() => 'VersionedJsonReadCorruptException: $message';
}
