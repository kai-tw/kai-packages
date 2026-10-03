/// Structural equality over decoded JSON: maps by key, lists by position,
/// everything else by `==`.
class JsonDeepEquality {
  const JsonDeepEquality();

  /// Whether [a] and [b] hold the same JSON value.
  bool equals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return _mapsEqual(a, b);
    }
    if (a is List && b is List) {
      return _listsEqual(a, b);
    }
    return a == b;
  }

  /// The keys whose presence or value differs between [a] and [b], so a key
  /// holding `null` on one side and absent on the other counts as different.
  Set<String> differingKeys(Map<String, dynamic> a, Map<String, dynamic> b) {
    return <String>{
      for (final String key in <String>{...a.keys, ...b.keys})
        if (a.containsKey(key) != b.containsKey(key) || !equals(a[key], b[key]))
          key,
    };
  }

  bool _mapsEqual(Map<Object?, Object?> a, Map<Object?, Object?> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final Object? key in a.keys) {
      if (!b.containsKey(key) || !equals(a[key], b[key])) {
        return false;
      }
    }
    return true;
  }

  bool _listsEqual(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (!equals(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
}
