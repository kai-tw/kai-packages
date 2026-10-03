import 'package:versioned_json/versioned_json.dart';

/// A DTO at version 3 of `ThreeVersionMigrator`'s format.
class NoteDto implements VersionedJsonDto {
  const NoteDto({required this.payload, this.schemaVersion = 3});

  /// Throws a [TypeError] when `payload` is missing — the stand-in for a
  /// migrated map today's DTO cannot parse.
  factory NoteDto.fromJson(Map<String, dynamic> json) => NoteDto(
    payload: json['payload'] as String,
    schemaVersion: json[VersionedJsonMigrator.versionKey] as int,
  );

  final String payload;

  @override
  final int schemaVersion;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    VersionedJsonMigrator.versionKey: schemaVersion,
    'payload': payload,
  };
}
