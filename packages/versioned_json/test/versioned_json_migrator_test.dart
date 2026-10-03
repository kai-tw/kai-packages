import 'package:test/test.dart';
import 'package:versioned_json/versioned_json.dart';

import 'support/three_version_migrator.dart';

void main() {
  const VersionedJsonMigrator migrator = ThreeVersionMigrator();
  final DateTime modifiedAt = DateTime.utc(2026, 1, 2, 3, 4, 5);

  group('migrateJson across the version axis', () {
    test('version 1 runs every step in order', () {
      final Map<String, dynamic> result = migrator.migrateJson(
        <String, dynamic>{'schemaVersion': 1, 'payload': 'hello'},
        modifiedAt,
      );

      expect(result, <String, dynamic>{
        'schemaVersion': 3,
        'payload': 'hello',
        'step1to2': true,
        'migratedAt': '2026-01-02T03:04:05.000Z',
        'step2to3': true,
      });
    });

    test('version 2 runs only the last step', () {
      final Map<String, dynamic> result = migrator.migrateJson(
        <String, dynamic>{'schemaVersion': 2, 'payload': 'mid'},
        modifiedAt,
      );

      expect(result['schemaVersion'], 3);
      expect(result.containsKey('step1to2'), isFalse);
      expect(result['step2to3'], isTrue);
    });

    test('the current version is returned as the same map', () {
      final Map<String, dynamic> json = <String, dynamic>{
        'schemaVersion': 3,
        'payload': 'current',
      };

      expect(migrator.migrateJson(json, modifiedAt), same(json));
    });

    test('a missing version key reads as version 1', () {
      final Map<String, dynamic> result = migrator.migrateJson(
        <String, dynamic>{'payload': 'legacy'},
        modifiedAt,
      );

      expect(result['schemaVersion'], 3);
      expect(result['step1to2'], isTrue);
      expect(result['step2to3'], isTrue);
    });

    test('a format born versioned may stay at version 1', () {
      const VersionedJsonMigrator born = _SingleVersionMigrator();
      final Map<String, dynamic> json = <String, dynamic>{
        'schemaVersion': 1,
        'payload': 'first',
      };

      expect(born.migrateJson(json, modifiedAt), same(json));
      expect(
        born.migrateJson(<String, dynamic>{'payload': 'first'}, modifiedAt),
        <String, dynamic>{'payload': 'first'},
      );
    });
  });

  group('migrateJson rejects a version newer than it supports', () {
    final Map<String, dynamic> future = <String, dynamic>{
      'schemaVersion': 4,
      'payload': 'secret-payload',
      'futureOnlyField': <String, int>{'a': 1},
    };

    test('with a SchemaVersionTooNewException carrying both versions', () {
      expect(
        () => migrator.migrateJson(future, modifiedAt),
        throwsA(
          isA<SchemaVersionTooNewException>()
              .having(
                (SchemaVersionTooNewException e) => e.version,
                'version',
                4,
              )
              .having(
                (SchemaVersionTooNewException e) => e.supportedVersion,
                'supportedVersion',
                3,
              ),
        ),
      );
    });

    test('which is a FormatException that names no content', () {
      expect(
        () => migrator.migrateJson(future, modifiedAt),
        throwsA(
          isA<FormatException>()
              .having((FormatException e) => e.source, 'source', isNull)
              .having(
                (FormatException e) => e.toString(),
                'toString()',
                allOf(
                  isNot(contains('secret-payload')),
                  isNot(contains('futureOnlyField')),
                ),
              ),
        ),
      );
    });

    test('and leaves the input map as it was', () {
      final Map<String, dynamic> before = Map<String, dynamic>.of(future);

      expect(
        () => migrator.migrateJson(future, modifiedAt),
        throwsA(isA<SchemaVersionTooNewException>()),
      );
      expect(future, before);
    });
  });

  group('migrateJson rejects a version field that is not an integer >= 1', () {
    final Map<String, Object?> invalid = <String, Object?>{
      'zero': 0,
      'negative': -1,
      'double': 2.0,
      'string': '2',
      'null': null,
    };

    for (final MapEntry<String, Object?> entry in invalid.entries) {
      test('${entry.key} throws SchemaVersionInvalidException', () {
        final Map<String, dynamic> json = <String, dynamic>{
          'schemaVersion': entry.value,
          'payload': 'secret-payload',
        };

        expect(
          () => migrator.migrateJson(json, modifiedAt),
          throwsA(
            isA<SchemaVersionInvalidException>()
                .having((FormatException e) => e.source, 'source', isNull)
                .having(
                  (FormatException e) => e.toString(),
                  'toString()',
                  isNot(contains('secret-payload')),
                ),
          ),
        );
      });
    }
  });

  group('readVersion', () {
    test('returns the declared version', () {
      expect(
        VersionedJsonMigrator.readVersion(<String, dynamic>{
          'schemaVersion': 7,
        }),
        7,
      );
    });

    test('returns 1 when the key is absent', () {
      expect(VersionedJsonMigrator.readVersion(<String, dynamic>{}), 1);
    });

    test('throws when the key holds null', () {
      expect(
        () => VersionedJsonMigrator.readVersion(<String, dynamic>{
          'schemaVersion': null,
        }),
        throwsA(isA<SchemaVersionInvalidException>()),
      );
    });
  });
}

class _SingleVersionMigrator extends VersionedJsonMigrator {
  const _SingleVersionMigrator();

  @override
  int get currentVersion => 1;

  @override
  Map<String, dynamic> migrateOneStep(
    Map<String, dynamic> source,
    int sourceVersion,
    DateTime modifiedAt,
  ) => throw StateError('a version-1 format has no steps');
}
