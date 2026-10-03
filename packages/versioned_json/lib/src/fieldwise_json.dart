import 'json_deep_equality.dart';

/// Field-by-field operations on a flat record, done through its JSON rather
/// than through a hand-written branch per field.
///
/// [V] is the record's value type and [F] the enum naming its fields. Every
/// field outside [nonValueFields] is a *value field*, and its JSON key is the
/// field's `name`.
///
/// **Precondition: [toJson] is canonical** — two values that mean the same
/// thing serialise identically. [changed] compares JSON, so a `toJson` that
/// writes the same instant once as local time and once as UTC reports a change
/// nobody made. `package:versioned_json/testing.dart` checks this, and the key
/// naming, from a consumer's own tests.
class FieldwiseJson<V, F extends Enum> {
  /// [fields] is the enum's whole `values` list, not a hand-picked subset: the
  /// key check in `testing.dart` compares against it, and a subset would let a
  /// newly added field go unchecked.
  const FieldwiseJson({
    required this.fields,
    required this.nonValueFields,
    required this.toJson,
    required this.fromJson,
  });

  /// Every field of the record.
  final List<F> fields;

  /// Fields the values JSON does not carry — a set-valued field kept and merged
  /// somewhere else, say. [take] and [changed] pass over them.
  final Set<F> nonValueFields;

  /// Serialises a value into a map keyed by value-field name.
  final Map<String, dynamic> Function(V value) toJson;

  /// Parses what [toJson] produces.
  final V Function(Map<String, dynamic> json) fromJson;

  static const JsonDeepEquality _equality = JsonDeepEquality();

  /// [fields] minus [nonValueFields], in declaration order.
  List<F> get valueFields => <F>[
    for (final F field in fields)
      if (!nonValueFields.contains(field)) field,
  ];

  /// Returns [into] with the value fields in [names] replaced by [from]'s.
  ///
  /// The result is `fromJson` of `toJson(into)` with each named key copied from
  /// `toJson(from)`; a key [from] omits is removed. Names in [nonValueFields]
  /// are passed over.
  V take(Iterable<F> names, {required V into, required V from}) {
    final Map<String, dynamic> json = Map<String, dynamic>.of(toJson(into));
    final Map<String, dynamic> source = toJson(from);
    for (final F field in names) {
      // A non-value field has no key in either map; it is merged by the caller.
      if (nonValueFields.contains(field)) {
        continue;
      }
      if (source.containsKey(field.name)) {
        json[field.name] = source[field.name];
      } else {
        json.remove(field.name);
      }
    }
    return fromJson(json);
  }

  /// The value fields whose JSON differs between [before] and [after], deeply
  /// for nested maps and lists, in declaration order. Fields in
  /// [nonValueFields] are never reported.
  Set<F> changed(V before, V after) {
    final Set<String> keys = _equality.differingKeys(
      toJson(before),
      toJson(after),
    );
    return <F>{
      for (final F field in valueFields)
        if (keys.contains(field.name)) field,
    };
  }
}
