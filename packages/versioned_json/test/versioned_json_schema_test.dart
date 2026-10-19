import 'dart:convert';
import 'dart:typed_data';

import 'package:json_annotation/json_annotation.dart';
import 'package:test/test.dart';
import 'package:versioned_json/versioned_json.dart';

import 'support/note_dto.dart';
import 'support/note_schema.dart';

/// Every in-memory read a caller has.
///
/// The lenient read ([VersionedJsonFileSchema.readString]) parses a migrated
/// document, and reads one this build may not act on — a newer version, one
/// below 1, one holding an unknown code, one that does not decode — as
/// `null`, never as a DTO with the unknown shape forced into today's.
///
/// The strict decode refuses each of those with the
/// [VersionedJsonReadException] variant that names why, carrying the stored
/// version. The document-within-a-document read reports the containing
/// document's version on every refusal, and the salvage read hands the
/// migrated map to the reader it is given.
///
/// Versions run 1 (the floor), 2, 3 (current), 4 (above current) and 0
/// (below the floor).
void main() {
  final DateTime modifiedAt = DateTime.utc(2026, 10, 18);

  Uint8List bytesOf(Object? document) =>
      Uint8List.fromList(utf8.encode(jsonEncode(document)));

  group('readString', () {
    const NoteSchema schema = NoteSchema();

    NoteDto? read(Object? document) =>
        schema.readString(jsonEncode(document), modifiedAt);

    test('a document at version 1 runs every step, then is parsed', () {
      final NoteDto? dto = read(<String, dynamic>{
        'schemaVersion': 1,
        'payload': 'old',
      });

      expect(dto?.payload, 'old');
      expect(dto?.steps, <String>['1to2', '2to3']);
    });

    test('a missing version and a null one both read as version 1', () {
      expect(read(<String, dynamic>{'payload': 'p'})?.steps, <String>[
        '1to2',
        '2to3',
      ]);
      expect(
        read(<String, dynamic>{'schemaVersion': null, 'payload': 'p'})?.steps,
        <String>['1to2', '2to3'],
      );
    });

    test('a document at version 2 runs only the last step', () {
      expect(
        read(<String, dynamic>{'schemaVersion': 2, 'payload': 'p'})?.steps,
        <String>['2to3'],
      );
    });

    test('a document at the current version is parsed as it is', () {
      final NoteDto? dto = read(<String, dynamic>{
        'schemaVersion': 3,
        'payload': 'today',
        'colour': 'yellow',
      });

      expect(dto?.payload, 'today');
      expect(dto?.colour, NoteColour.yellow);
      expect(dto?.steps, isEmpty);
    });

    test('a document above the current version reads as null', () {
      expect(
        read(<String, dynamic>{'schemaVersion': 4, 'payload': 'p'}),
        isNull,
      );
    });

    test('a document at version 0 reads as null: no build wrote it', () {
      expect(
        read(<String, dynamic>{'schemaVersion': 0, 'payload': 'p'}),
        isNull,
      );
    });

    test('a version that is present but no integer reads as null, not as '
        'version 1', () {
      expect(
        read(<String, dynamic>{'schemaVersion': '3', 'payload': 'p'}),
        isNull,
      );
      expect(
        read(<String, dynamic>{'schemaVersion': 3.0, 'payload': 'p'}),
        isNull,
      );
    });

    test('text that is not JSON, and JSON that is no object, read as null', () {
      expect(schema.readString('{not json', modifiedAt), isNull);
      expect(schema.readString('', modifiedAt), isNull);
      expect(schema.readString('[1, 2, 3]', modifiedAt), isNull);
    });

    test(
      'a document holding a code this build does not know reads as null',
      () {
        expect(
          read(<String, dynamic>{
            'schemaVersion': 3,
            'payload': 'p',
            'colour': 'ultraviolet',
          }),
          isNull,
        );
      },
    );

    test('a field fromJson cannot parse propagates rather than reading as '
        'null', () {
      expect(
        () => read(<String, dynamic>{'schemaVersion': 3, 'payload': 7}),
        throwsA(isA<CheckedFromJsonException>()),
      );
    });

    test('the first step receives modifiedAt', () {
      expect(
        jsonDecode(
          const _WholeDocumentNoteSchema().encodedMigration(
            <String, dynamic>{'payload': 'p'},
            modifiedAt,
          ),
        ),
        containsPair('migratedAt', '2026-10-18T00:00:00.000Z'),
      );
    });
  });

  group('encode', () {
    test('stamps the current version the DTO does not carry', () {
      final String text = const NoteSchema().encode(
        const NoteDto(payload: 'p'),
      );

      expect(jsonDecode(text), <String, dynamic>{
        'payload': 'p',
        'colour': 'plain',
        'steps': <dynamic>[],
        'schemaVersion': 3,
      });
    });

    test('reads back through readString without running a step', () {
      const NoteSchema schema = NoteSchema();
      final String text = schema.encode(
        const NoteDto(payload: 'round trip', colour: NoteColour.yellow),
      );

      final NoteDto? dto = schema.readString(text, modifiedAt);

      expect(dto?.payload, 'round trip');
      expect(dto?.colour, NoteColour.yellow);
      expect(dto?.steps, isEmpty);
    });
  });

  group('decodeBytes', () {
    // Built at run time, not as a constant, so the base constructors run
    // under coverage.
    final _OpenNoteSchema schema = _OpenNoteSchema();

    test('a document at version 1 runs every step, then is parsed', () {
      final NoteDto dto = schema.decode(
        bytesOf(<String, dynamic>{'schemaVersion': 1, 'payload': 'old'}),
        modifiedAt,
      );

      expect(dto.payload, 'old');
      expect(dto.steps, <String>['1to2', '2to3']);
    });

    test('a document above the current version is refused as newer, '
        'carrying its version', () {
      expect(
        () => schema.decode(
          bytesOf(<String, dynamic>{'schemaVersion': 4, 'payload': 'p'}),
          modifiedAt,
        ),
        _refusal<VersionedJsonReadNewerException>(4),
      );
    });

    test('a document at version 0 is refused as corrupt, carrying its '
        'version', () {
      expect(
        () => schema.decode(
          bytesOf(<String, dynamic>{'schemaVersion': 0, 'payload': 'p'}),
          modifiedAt,
        ),
        _refusal<VersionedJsonReadCorruptException>(0),
      );
    });

    test('bytes that are not UTF-8, text that is not JSON, and JSON that is '
        'no object or declares no integer version are refused as corrupt with '
        'no version', () {
      for (final Uint8List bytes in <Uint8List>[
        Uint8List.fromList(<int>[0x7b, 0xff, 0xfe, 0x7d]),
        Uint8List.fromList(utf8.encode('{not json')),
        Uint8List(0),
        bytesOf(<int>[1, 2, 3]),
        bytesOf(<String, dynamic>{'schemaVersion': '3', 'payload': 'p'}),
      ]) {
        expect(
          () => schema.decode(bytes, modifiedAt),
          _refusal<VersionedJsonReadCorruptException>(null),
        );
      }
    });

    test('a document holding a code this build does not know is refused as '
        'such, carrying its version', () {
      expect(
        () => schema.decode(
          bytesOf(<String, dynamic>{
            'schemaVersion': 1,
            'payload': 'p',
            'colour': 'ultraviolet',
          }),
          modifiedAt,
        ),
        _refusal<VersionedJsonReadUnknownCodeException>(1),
      );
    });

    test('a field fromJson cannot parse is refused as corrupt, carrying the '
        'version and the parse failure\'s stack trace', () {
      Object? caught;
      StackTrace? trace;
      try {
        schema.decode(
          bytesOf(<String, dynamic>{'schemaVersion': 2, 'payload': 7}),
          modifiedAt,
        );
      } on VersionedJsonReadCorruptException catch (e, s) {
        caught = e;
        trace = s;
      }

      expect(
        caught,
        isA<VersionedJsonReadCorruptException>().having(
          (VersionedJsonReadCorruptException e) => e.storedVersion,
          'storedVersion',
          2,
        ),
      );
      expect(trace.toString(), contains('note_dto.dart'));
    });

    group('within another document', () {
      Uint8List container(int version, Map<String, dynamic> inner) =>
          bytesOf(<String, dynamic>{'schemaVersion': version, 'inner': inner});

      test('the container is migrated, its section cut out, then migrated '
          'and parsed as this file', () {
        final NoteDto dto = schema.decodeWithin(
          container(1, <String, dynamic>{'schemaVersion': 1, 'payload': 'in'}),
          modifiedAt,
        );

        expect(dto.payload, 'in');
        expect(dto.steps, <String>['1to2', '2to3']);
      });

      test('a container this build may not act on is refused with its own '
          'version', () {
        expect(
          () => schema.decodeWithin(
            container(4, <String, dynamic>{'payload': 'p'}),
            modifiedAt,
          ),
          _refusal<VersionedJsonReadNewerException>(4),
        );
        expect(
          () => schema.decodeWithin(
            container(0, <String, dynamic>{'payload': 'p'}),
            modifiedAt,
          ),
          _refusal<VersionedJsonReadCorruptException>(0),
        );
        expect(
          () => schema.decodeWithin(
            Uint8List.fromList(utf8.encode('{not json')),
            modifiedAt,
          ),
          _refusal<VersionedJsonReadCorruptException>(null),
        );
      });

      test("every refusal of the section reports the container's version, "
          'the file on disk', () {
        expect(
          () => schema.decodeWithin(
            container(1, <String, dynamic>{'schemaVersion': 9, 'payload': 'p'}),
            modifiedAt,
          ),
          _refusal<VersionedJsonReadNewerException>(1),
        );
        expect(
          () => schema.decodeWithin(
            container(1, <String, dynamic>{'schemaVersion': 0, 'payload': 'p'}),
            modifiedAt,
          ),
          _refusal<VersionedJsonReadCorruptException>(1),
        );
        expect(
          () => schema.decodeWithin(
            container(1, <String, dynamic>{'schemaVersion': '1'}),
            modifiedAt,
          ),
          _refusal<VersionedJsonReadCorruptException>(1),
        );
        expect(
          () => schema.decodeWithin(
            container(1, <String, dynamic>{
              'payload': 'p',
              'colour': 'ultraviolet',
            }),
            modifiedAt,
          ),
          _refusal<VersionedJsonReadUnknownCodeException>(1),
        );
        expect(
          () => schema.decodeWithin(
            container(1, <String, dynamic>{'schemaVersion': 3, 'payload': 7}),
            modifiedAt,
          ),
          _refusal<VersionedJsonReadCorruptException>(1),
        );
      });
    });

    group('salvage', () {
      test('the reader gets the migrated map', () {
        expect(
          schema.salvage(
            bytesOf(<String, dynamic>{'schemaVersion': 1, 'payload': 7}),
            modifiedAt,
          ),
          <dynamic>['1to2', '2to3'],
        );
      });

      test('a document this build may not act on salvages nothing', () {
        for (final Uint8List bytes in <Uint8List>[
          bytesOf(<String, dynamic>{'schemaVersion': 4}),
          bytesOf(<String, dynamic>{'schemaVersion': 0}),
          Uint8List.fromList(utf8.encode('{not json')),
        ]) {
          expect(schema.salvage(bytes, modifiedAt), isNull);
        }
      });
    });
  });

  group('an unversioned shape', () {
    test('JSON that is no object enters the steps at version 1 when the '
        'schema wraps it', () {
      final NoteDto? dto = const _BareStringNoteSchema().readString(
        jsonEncode('just text'),
        modifiedAt,
      );

      expect(dto?.payload, 'just text');
      expect(dto?.steps, <String>['1to2', '2to3']);
    });

    test('a shape the schema does not wrap is still malformed', () {
      expect(
        const _BareStringNoteSchema().readString('[1]', modifiedAt),
        isNull,
      );
    });
  });

  test('a schema that keeps the default holdsUnknownCode refuses no '
      'document for its codes', () {
    expect(
      _SteplessNoteSchema()
          .readString('{"schemaVersion": 2, "payload": "p"}', modifiedAt)
          ?.payload,
      'p',
    );
  });

  group('throwNoStepFrom', () {
    test('a schema raised to version 2 without the step that reaches it '
        'throws VersionedJsonMigrationException naming the version asked for '
        'and the current one', () {
      expect(
        () => _SteplessNoteSchema().readString('{}', modifiedAt),
        throwsA(
          isA<VersionedJsonMigrationException>()
              .having(
                (VersionedJsonMigrationException e) => e.sourceVersion,
                'sourceVersion',
                1,
              )
              .having(
                (VersionedJsonMigrationException e) => e.currentVersion,
                'currentVersion',
                2,
              )
              .having(
                (VersionedJsonMigrationException e) => e.message,
                'message',
                'No migration step from schema v1 (current v2)',
              )
              .having(
                (VersionedJsonMigrationException e) => e.toString(),
                'toString',
                'VersionedJsonMigrationException: '
                    'No migration step from schema v1 (current v2)',
              ),
        ),
      );
    });

    test('is an Exception that a catch for bad input does not swallow', () {
      expect(() {
        try {
          _SteplessNoteSchema().readString('{}', modifiedAt);
        } on FormatException {
          fail('caught as a FormatException');
        }
      }, throwsA(allOf(isA<Exception>(), isNot(isA<Error>()))));
    });
  });

  group('read exceptions', () {
    test('are FormatExceptions that name their class and never the '
        'document', () {
      final Map<VersionedJsonReadException, String> expected =
          <VersionedJsonReadException, String>{
            const VersionedJsonReadNewerException(storedVersion: 4):
                'VersionedJsonReadNewerException: '
                'Document is schema v4, newer than this build reads',
            const VersionedJsonReadUnknownCodeException(storedVersion: 3):
                'VersionedJsonReadUnknownCodeException: '
                'Document holds an enum code this build does not know',
            const VersionedJsonReadCorruptException():
                'VersionedJsonReadCorruptException: Document does not decode',
          };

      for (final MapEntry<VersionedJsonReadException, String> entry
          in expected.entries) {
        expect(entry.key, isA<FormatException>());
        expect(entry.key.toString(), entry.value);
      }
    });
  });
}

/// A matcher for the refusal [T], carrying [storedVersion].
Matcher _refusal<T extends VersionedJsonReadException>(int? storedVersion) =>
    throwsA(
      isA<T>().having(
        (T e) => switch (e) {
          VersionedJsonReadNewerException(:final int storedVersion) =>
            storedVersion,
          VersionedJsonReadUnknownCodeException(:final int storedVersion) =>
            storedVersion,
          VersionedJsonReadCorruptException(:final int? storedVersion) =>
            storedVersion,
        },
        'storedVersion',
        storedVersion,
      ),
    );

/// [NoteSchema] with its protected reads opened to the test.
class _OpenNoteSchema extends NoteSchema {
  _OpenNoteSchema();

  NoteDto decode(Uint8List bytes, DateTime modifiedAt) =>
      decodeBytes(bytes, modifiedAt);

  NoteDto decodeWithin(Uint8List bytes, DateTime modifiedAt) =>
      decodeBytesWithin(
        bytes,
        modifiedAt,
        container: const NoteSchema(),
        sectionOf: (Map<String, dynamic> stored) =>
            stored['inner'] as Map<String, dynamic>,
      );

  /// The steps the migrated document says ran.
  List<dynamic>? salvage(Uint8List bytes, DateTime modifiedAt) => readMigrated(
    bytes,
    modifiedAt,
    (Map<String, dynamic> json) => json['steps'] as List<dynamic>?,
  );
}

/// [NoteSchema] whose salvage read hands back the whole migrated document.
class _WholeDocumentNoteSchema extends NoteSchema {
  const _WholeDocumentNoteSchema();

  String encodedMigration(Map<String, dynamic> json, DateTime modifiedAt) =>
      jsonEncode(
        readMigrated(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
          modifiedAt,
          (Map<String, dynamic> migrated) => migrated,
        ),
      );
}

/// [NoteSchema] for a format whose first shape was a bare JSON string.
class _BareStringNoteSchema extends NoteSchema {
  const _BareStringNoteSchema();

  @override
  Map<String, dynamic>? wrapUnversioned(Object? document) => switch (document) {
    final String payload => <String, dynamic>{'payload': payload},
    _ => null,
  };
}

/// A schema raised to version 2 that holds no step: the base's default
/// answers every version. Built at run time, so its constructor runs under
/// coverage.
class _SteplessNoteSchema extends VersionedJsonFileSchema<NoteDto> {
  _SteplessNoteSchema();

  @override
  int get currentVersion => 2;

  @override
  NoteDto fromJson(Map<String, dynamic> json) => NoteDto.fromJson(json);
}
