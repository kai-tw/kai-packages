import 'package:versioned_json/versioned_json.dart';

/// Fields of a plant record. `beds` is set-valued and kept outside the values
/// JSON, so it is a non-value field.
enum PlantField { name, height, care, plantedAt, beds }

/// The value-field part of a plant record.
class PlantValues {
  const PlantValues({
    required this.name,
    required this.height,
    required this.care,
    required this.plantedAt,
  });

  factory PlantValues.fromJson(Map<String, dynamic> json) => PlantValues(
    name: json['name'] as String,
    height: json['height'] as int?,
    care: Map<String, dynamic>.of(json['care'] as Map<String, dynamic>),
    plantedAt: DateTime.parse(json['plantedAt'] as String),
  );

  final String name;
  final int? height;
  final Map<String, dynamic> care;
  final DateTime plantedAt;

  /// Canonical: the instant is always written in UTC, and a null height is
  /// left out.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    if (height != null) 'height': height,
    'care': care,
    'plantedAt': plantedAt.toUtc().toIso8601String(),
  };
}

const FieldwiseJson<PlantValues, PlantField> plantFieldwise =
    FieldwiseJson<PlantValues, PlantField>(
      fields: PlantField.values,
      nonValueFields: <PlantField>{PlantField.beds},
      toJson: _plantToJson,
      fromJson: PlantValues.fromJson,
    );

Map<String, dynamic> _plantToJson(PlantValues value) => value.toJson();

/// Plant fields over values that are their own JSON, so a test can put any
/// key in them — including ones a well-behaved `toJson` never writes.
const FieldwiseJson<Map<String, dynamic>, PlantField> rawPlantFieldwise =
    FieldwiseJson<Map<String, dynamic>, PlantField>(
      fields: PlantField.values,
      nonValueFields: <PlantField>{PlantField.beds},
      toJson: _identity,
      fromJson: _identity,
    );

Map<String, dynamic> _identity(Map<String, dynamic> json) => json;
