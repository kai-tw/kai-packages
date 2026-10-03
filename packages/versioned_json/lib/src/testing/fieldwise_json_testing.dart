import '../fieldwise_json.dart';
import '../json_deep_equality.dart';

/// Checks of a [FieldwiseJson]'s preconditions, for a consumer's own tests.
///
/// Each returns human-readable mismatches, empty when the check passes:
/// `expect(fieldwise.keyMismatches(sample), isEmpty)`.
extension FieldwiseJsonTesting<V, F extends Enum> on FieldwiseJson<V, F> {
  static const JsonDeepEquality _equality = JsonDeepEquality();

  /// Compares the keys of `toJson(sample)` with the value fields' names.
  ///
  /// Pass a [sample] with every value field set: a `toJson` that omits null
  /// fields otherwise reports them as missing.
  List<String> keyMismatches(V sample) {
    final Set<String> keys = toJson(sample).keys.toSet();
    final Set<String> expected = <String>{
      for (final F field in valueFields) field.name,
    };
    return <String>[
      for (final String name in expected.difference(keys))
        'value field "$name" has no key in toJson',
      for (final String key in keys.difference(expected))
        'toJson writes "$key", which is not a value field',
    ];
  }

  /// Checks that [json] survives `fromJson` then `toJson` unchanged.
  List<String> roundTripMismatches(Map<String, dynamic> json) {
    final Map<String, dynamic> back = toJson(fromJson(json));
    return <String>[
      for (final String key in _equality.differingKeys(json, back))
        'key "$key" does not survive fromJson then toJson',
    ];
  }

  /// Checks that two values meaning the same thing — the same instant in two
  /// time zones, say — serialise identically, which [FieldwiseJson.changed]
  /// relies on.
  List<String> equivalenceMismatches(V a, V b) {
    return <String>[
      for (final String key in _equality.differingKeys(toJson(a), toJson(b)))
        'key "$key" serialises differently for equivalent values',
    ];
  }
}
