import 'package:test/test.dart';
import 'package:versioned_json/testing.dart';
import 'package:versioned_json/versioned_json.dart';

import 'support/plant_values.dart';
import 'support/three_version_migrator.dart';

void main() {
  final DateTime spring = DateTime.utc(2026, 3, 20, 9);
  final PlantValues fern = PlantValues(
    name: 'fern',
    height: 30,
    care: <String, dynamic>{'water': 'weekly'},
    plantedAt: spring,
  );

  group('keyMismatches', () {
    test('is empty when the keys are exactly the value fields', () {
      expect(plantFieldwise.keyMismatches(fern), isEmpty);
    });

    test('reports a value field toJson leaves out', () {
      final PlantValues unmeasured = PlantValues(
        name: 'fern',
        height: null,
        care: const <String, dynamic>{},
        plantedAt: spring,
      );

      expect(plantFieldwise.keyMismatches(unmeasured), <String>[
        'value field "height" has no key in toJson',
      ]);
    });

    test('reports a key that is not a value field', () {
      expect(
        rawPlantFieldwise.keyMismatches(<String, dynamic>{
          'name': 'fern',
          'height': 1,
          'care': <String, dynamic>{},
          'plantedAt': '2026-03-20T09:00:00.000Z',
          'beds': <String>['north'],
          'colour': 'green',
        }),
        unorderedEquals(<String>[
          'toJson writes "beds", which is not a value field',
          'toJson writes "colour", which is not a value field',
        ]),
      );
    });
  });

  group('roundTripMismatches', () {
    test('is empty for JSON that survives fromJson then toJson', () {
      expect(plantFieldwise.roundTripMismatches(fern.toJson()), isEmpty);
    });

    test('reports a key that does not survive', () {
      final Map<String, dynamic> json = fern.toJson()
        ..['plantedAt'] = '2026-03-20T09:00:00+00:00';

      expect(plantFieldwise.roundTripMismatches(json), <String>[
        'key "plantedAt" does not survive fromJson then toJson',
      ]);
    });
  });

  group('equivalenceMismatches', () {
    final PlantValues local = PlantValues(
      name: fern.name,
      height: fern.height,
      care: fern.care,
      plantedAt: spring.toLocal(),
    );

    test('is empty when equivalent values serialise identically', () {
      expect(plantFieldwise.equivalenceMismatches(fern, local), isEmpty);
    });

    test('reports a key a non-canonical toJson writes two ways', () {
      const FieldwiseJson<PlantValues, PlantField> nonCanonical =
          FieldwiseJson<PlantValues, PlantField>(
            fields: PlantField.values,
            nonValueFields: <PlantField>{PlantField.beds},
            toJson: _zoneKeepingToJson,
            fromJson: PlantValues.fromJson,
          );

      expect(nonCanonical.equivalenceMismatches(fern, local), <String>[
        'key "plantedAt" serialises differently for equivalent values',
      ]);
    });
  });

  group('stepExampleMismatches', () {
    const VersionedJsonMigrator migrator = ThreeVersionMigrator();
    final DateTime modifiedAt = DateTime.utc(2026, 1, 2);
    final VersionedJsonStepExample from1 = VersionedJsonStepExample(
      before: <String, dynamic>{'payload': 'p'},
      after: <String, dynamic>{
        'schemaVersion': 2,
        'payload': 'p',
        'step1to2': true,
        'migratedAt': '2026-01-02T00:00:00.000Z',
      },
      modifiedAt: modifiedAt,
    );
    final VersionedJsonStepExample from2 = VersionedJsonStepExample(
      before: <String, dynamic>{'schemaVersion': 2},
      after: <String, dynamic>{'schemaVersion': 3, 'step2to3': true},
      modifiedAt: modifiedAt,
    );

    test('is empty when every step has a passing example', () {
      expect(
        migrator.stepExampleMismatches(<int, VersionedJsonStepExample>{
          1: from1,
          2: from2,
        }),
        isEmpty,
      );
    });

    test('reports a step without an example', () {
      expect(
        migrator.stepExampleMismatches(<int, VersionedJsonStepExample>{
          1: from1,
        }),
        <String>['no example for the step from version 2'],
      );
    });

    test('reports an example outside the steps', () {
      expect(
        migrator.stepExampleMismatches(<int, VersionedJsonStepExample>{
          1: from1,
          2: from2,
          3: from2,
        }),
        <String>['example for version 3, but steps run from 1 to 2'],
      );
    });

    test('reports a step whose output differs from the example', () {
      final VersionedJsonStepExample wrong = VersionedJsonStepExample(
        before: <String, dynamic>{'schemaVersion': 2},
        after: <String, dynamic>{'schemaVersion': 3, 'step2to3': false},
        modifiedAt: modifiedAt,
      );

      expect(
        migrator.stepExampleMismatches(<int, VersionedJsonStepExample>{
          1: from1,
          2: wrong,
        }),
        <String>[
          'step from version 2: key "step2to3" differs from the example',
        ],
      );
    });

    test('reports a step that does not write the next version', () {
      const VersionedJsonMigrator forgetful = _VersionForgettingMigrator();

      expect(
        forgetful.stepExampleMismatches(<int, VersionedJsonStepExample>{
          1: VersionedJsonStepExample(
            before: const <String, dynamic>{'payload': 'p'},
            after: const <String, dynamic>{'schemaVersion': 2, 'payload': 'p'},
            modifiedAt: modifiedAt,
          ),
        }),
        <String>['step from version 1 writes schemaVersion null, not 2'],
      );
    });
  });
}

/// Writes the instant in whatever zone the value holds — not canonical.
Map<String, dynamic> _zoneKeepingToJson(PlantValues value) => <String, dynamic>{
  ...value.toJson(),
  'plantedAt': value.plantedAt.toIso8601String(),
};

class _VersionForgettingMigrator extends VersionedJsonMigrator {
  const _VersionForgettingMigrator();

  @override
  int get currentVersion => 2;

  @override
  Map<String, dynamic> migrateOneStep(
    Map<String, dynamic> source,
    int sourceVersion,
    DateTime modifiedAt,
  ) => Map<String, dynamic>.of(source);
}
