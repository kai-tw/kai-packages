import 'package:test/test.dart';
import 'package:versioned_json/testing.dart';
import 'package:versioned_json/versioned_json.dart';

import 'support/plant_values.dart';

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
}

/// Writes the instant in whatever zone the value holds — not canonical.
Map<String, dynamic> _zoneKeepingToJson(PlantValues value) => <String, dynamic>{
  ...value.toJson(),
  'plantedAt': value.plantedAt.toIso8601String(),
};
