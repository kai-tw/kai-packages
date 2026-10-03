import 'package:versioned_json/versioned_json.dart';

import 'note_dto.dart';
import 'three_version_migrator.dart';

class NoteSchema extends VersionedJsonSchema<NoteDto> {
  const NoteSchema();

  @override
  VersionedJsonMigrator get migrator => const ThreeVersionMigrator();

  @override
  NoteDto fromJson(Map<String, dynamic> json) => NoteDto.fromJson(json);
}
