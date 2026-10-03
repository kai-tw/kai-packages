import 'package:test/test.dart';
import 'package:versioned_json/versioned_json.dart';

import 'support/note_dto.dart';
import 'support/note_schema.dart';

void main() {
  const NoteSchema schema = NoteSchema();
  final DateTime modifiedAt = DateTime.utc(2026);

  test('currentVersion is the migrator\'s', () {
    expect(schema.currentVersion, 3);
  });

  test('readJson migrates an older map, then parses it', () {
    final NoteDto dto = schema.readJson(<String, dynamic>{
      'schemaVersion': 1,
      'payload': 'hello',
    }, modifiedAt);

    expect(dto.schemaVersion, 3);
    expect(dto.payload, 'hello');
  });

  test('readJson lets a too-new version propagate', () {
    expect(
      () => schema.readJson(<String, dynamic>{
        'schemaVersion': 4,
        'payload': 'future',
      }, modifiedAt),
      throwsA(isA<SchemaVersionTooNewException>()),
    );
  });

  test('readJson lets an invalid version propagate', () {
    expect(
      () => schema.readJson(<String, dynamic>{
        'schemaVersion': '3',
        'payload': 'x',
      }, modifiedAt),
      throwsA(isA<SchemaVersionInvalidException>()),
    );
  });

  test('readJson lets a fromJson failure propagate', () {
    expect(
      () => schema.readJson(<String, dynamic>{'schemaVersion': 3}, modifiedAt),
      throwsA(isA<TypeError>()),
    );
  });
}
