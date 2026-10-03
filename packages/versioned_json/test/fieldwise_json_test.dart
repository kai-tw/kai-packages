import 'package:test/test.dart';

import 'support/plant_values.dart';

void main() {
  final DateTime spring = DateTime.utc(2026, 3, 20, 9);
  final PlantValues fern = PlantValues(
    name: 'fern',
    height: 30,
    care: <String, dynamic>{
      'water': 'weekly',
      'light': <String>['shade', 'indirect'],
    },
    plantedAt: spring,
  );
  final PlantValues cactus = PlantValues(
    name: 'cactus',
    height: 12,
    care: <String, dynamic>{
      'water': 'monthly',
      'light': <String>['direct'],
    },
    plantedAt: DateTime.utc(2025, 6, 1),
  );

  test('valueFields drops the non-value fields, in declaration order', () {
    expect(plantFieldwise.valueFields, <PlantField>[
      PlantField.name,
      PlantField.height,
      PlantField.care,
      PlantField.plantedAt,
    ]);
  });

  group('take', () {
    test('copies only the named fields from the source', () {
      final PlantValues taken = plantFieldwise.take(
        <PlantField>[PlantField.name],
        into: fern,
        from: cactus,
      );

      expect(taken.name, 'cactus');
      expect(taken.height, 30);
      expect(taken.care, fern.care);
      expect(taken.plantedAt, spring);
    });

    test('copies a nested value whole', () {
      final PlantValues taken = plantFieldwise.take(
        <PlantField>[PlantField.care],
        into: fern,
        from: cactus,
      );

      expect(taken.care, <String, dynamic>{
        'water': 'monthly',
        'light': <String>['direct'],
      });
      expect(taken.name, 'fern');
    });

    test('removes a key the source leaves out', () {
      final PlantValues unmeasured = PlantValues(
        name: 'seedling',
        height: null,
        care: const <String, dynamic>{},
        plantedAt: spring,
      );

      final PlantValues taken = plantFieldwise.take(
        <PlantField>[PlantField.height],
        into: fern,
        from: unmeasured,
      );

      expect(taken.height, isNull);
      expect(taken.name, 'fern');
    });

    test('passes over a non-value field', () {
      final PlantValues taken = plantFieldwise.take(
        <PlantField>[PlantField.beds],
        into: fern,
        from: cactus,
      );

      expect(taken.toJson(), fern.toJson());
    });

    test('with no names returns the target unchanged', () {
      expect(
        plantFieldwise
            .take(const <PlantField>[], into: fern, from: cactus)
            .toJson(),
        fern.toJson(),
      );
    });
  });

  group('changed', () {
    test('reports nothing for equal values', () {
      expect(plantFieldwise.changed(fern, fern), isEmpty);
    });

    test('reports every differing value field in declaration order', () {
      expect(plantFieldwise.changed(fern, cactus).toList(), <PlantField>[
        PlantField.name,
        PlantField.height,
        PlantField.care,
        PlantField.plantedAt,
      ]);
    });

    test('compares nested values deeply', () {
      final PlantValues lighter = PlantValues(
        name: fern.name,
        height: fern.height,
        care: <String, dynamic>{
          'water': 'weekly',
          'light': <String>['shade'],
        },
        plantedAt: spring,
      );
      final PlantValues sameCare = PlantValues(
        name: fern.name,
        height: fern.height,
        care: <String, dynamic>{
          'water': 'weekly',
          'light': <String>['shade', 'indirect'],
        },
        plantedAt: spring,
      );

      expect(plantFieldwise.changed(fern, lighter), <PlantField>{
        PlantField.care,
      });
      expect(plantFieldwise.changed(fern, sameCare), isEmpty);
    });

    group('a nested map with one extra key is a change', () {
      final PlantValues withSoil = PlantValues(
        name: fern.name,
        height: fern.height,
        care: <String, dynamic>{...fern.care, 'soil': 'peat'},
        plantedAt: spring,
      );

      test('when the key is added', () {
        expect(plantFieldwise.changed(fern, withSoil), <PlantField>{
          PlantField.care,
        });
      });

      test('when the key is removed', () {
        expect(plantFieldwise.changed(withSoil, fern), <PlantField>{
          PlantField.care,
        });
      });
    });

    test('a list of the same length with one element changed is a change', () {
      final PlantValues brighter = PlantValues(
        name: fern.name,
        height: fern.height,
        care: <String, dynamic>{
          'water': 'weekly',
          'light': <String>['shade', 'direct'],
        },
        plantedAt: spring,
      );

      expect(plantFieldwise.changed(fern, brighter), <PlantField>{
        PlantField.care,
      });
    });

    test('reports a key present on one side only', () {
      final PlantValues unmeasured = PlantValues(
        name: fern.name,
        height: null,
        care: fern.care,
        plantedAt: spring,
      );

      expect(plantFieldwise.changed(fern, unmeasured), <PlantField>{
        PlantField.height,
      });
    });

    test('compares JSON, so the same instant in another zone is no change', () {
      final PlantValues local = PlantValues(
        name: fern.name,
        height: fern.height,
        care: fern.care,
        plantedAt: spring.toLocal(),
      );

      expect(local.plantedAt == fern.plantedAt, isFalse);
      expect(plantFieldwise.changed(fern, local), isEmpty);
    });

    test('never reports a non-value field, even one toJson writes', () {
      final Map<String, dynamic> before = <String, dynamic>{
        'name': 'fern',
        'beds': <String>['north'],
      };
      final Map<String, dynamic> after = <String, dynamic>{
        'name': 'fern',
        'beds': <String>['south'],
      };

      expect(rawPlantFieldwise.changed(before, after), isEmpty);
      expect(
        rawPlantFieldwise.take(
          <PlantField>[PlantField.beds],
          into: before,
          from: after,
        ),
        before,
      );
    });
  });
}
