import 'package:test/test.dart';
import 'package:versioned_json/versioned_json.dart';

import 'note_dto.dart';

/// A schema at version 3, so a version-1 document exercises the loop across
/// two steps. Each step appends its name to `steps`, and the first records
/// the `modifiedAt` it was handed.
class NoteSchema extends VersionedJsonFileSchema<NoteDto> {
  const NoteSchema();

  @override
  int get currentVersion => 3;

  @override
  Map<String, dynamic> migrateOneStep(
    Map<String, dynamic> source,
    int sourceVersion,
    DateTime modifiedAt,
  ) {
    // A loop that stops advancing its version would hand a step the map it
    // just produced under the same number, forever: failed here, so that
    // regression fails at the second step instead of hanging the run.
    if ((source['schemaVersion'] ?? 1) != sourceVersion) {
      fail('step from v$sourceVersion handed another version');
    }
    final List<dynamic> steps = <dynamic>[
      ...source['steps'] as List<dynamic>? ?? <dynamic>[],
    ];
    return switch (sourceVersion) {
      1 => <String, dynamic>{
        ...source,
        'schemaVersion': 2,
        'steps': <dynamic>[...steps, '1to2'],
        'migratedAt': modifiedAt.toUtc().toIso8601String(),
      },
      2 => <String, dynamic>{
        ...source,
        'schemaVersion': 3,
        'steps': <dynamic>[...steps, '2to3'],
      },
      _ => throwNoStepFrom(sourceVersion),
    };
  }

  @override
  NoteDto fromJson(Map<String, dynamic> json) => NoteDto.fromJson(json);

  @override
  bool holdsUnknownCode(Map<String, dynamic> json) => !<Object?>{
    null,
    for (final NoteColour colour in NoteColour.values) colour.name,
  }.contains(json['colour']);
}
