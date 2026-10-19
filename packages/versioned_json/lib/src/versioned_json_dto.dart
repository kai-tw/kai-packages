/// Marker interface for every DTO a `VersionedJsonSchema` reads and writes.
///
/// An interface rather than a base class, so a generated data class (which
/// usually cannot extend anything) can still implement it.
///
/// The DTO is today's shape and nothing more: it carries no version. The
/// schema stamps its current version when it encodes the DTO, and reads the
/// stored one before the DTO is ever parsed.
abstract interface class VersionedJsonDto {
  /// Serialises this DTO, without the version. The schema adds it.
  Map<String, dynamic> toJson();
}
