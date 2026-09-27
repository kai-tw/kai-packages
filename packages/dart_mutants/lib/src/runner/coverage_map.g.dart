// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'coverage_map.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_CoverageMapJson _$CoverageMapJsonFromJson(Map<String, dynamic> json) =>
    $checkedCreate('_CoverageMapJson', json, ($checkedConvert) {
      final val = _CoverageMapJson(
        tests: $checkedConvert(
          'tests',
          (v) => (v as List<dynamic>).map((e) => e as String).toList(),
        ),
        files: $checkedConvert(
          'files',
          (v) => (v as Map<String, dynamic>).map(
            (k, e) => MapEntry(
              k,
              (e as Map<String, dynamic>).map(
                (k, e) => MapEntry(
                  int.parse(k),
                  (e as List<dynamic>).map((e) => (e as num).toInt()).toList(),
                ),
              ),
            ),
          ),
        ),
      );
      return val;
    });

Map<String, dynamic> _$CoverageMapJsonToJson(_CoverageMapJson instance) =>
    <String, dynamic>{
      'tests': instance.tests,
      'files': instance.files.map(
        (k, e) => MapEntry(k, e.map((k, e) => MapEntry(k.toString(), e))),
      ),
    };
