import 'package:shared_preferences/shared_preferences.dart';

import 'preference_local_data_source.dart';

/// Every [PreferenceLocalDataSource] member except [storageKeyOf], which a
/// subclass supplies for its own key enum.
abstract class SharedPreferencesLocalDataSource<K extends Enum>
    implements PreferenceLocalDataSource<K> {
  SharedPreferencesLocalDataSource(this._prefs);

  final SharedPreferences _prefs;

  @override
  Future<void> setBool(K key, bool value) {
    return _prefs.setBool(storageKeyOf(key), value);
  }

  @override
  Future<void> setDouble(K key, double value) {
    return _prefs.setDouble(storageKeyOf(key), value);
  }

  @override
  Future<void> setInt(K key, int value) {
    return _prefs.setInt(storageKeyOf(key), value);
  }

  @override
  Future<void> setString(K key, String value) {
    return _prefs.setString(storageKeyOf(key), value);
  }

  @override
  Future<void> setStringList(K key, List<String> value) {
    return _prefs.setStringList(storageKeyOf(key), value);
  }

  @override
  Future<bool?> tryGetBool(K key) async {
    final Object? value = _prefs.get(storageKeyOf(key));
    return value is bool ? value : null;
  }

  @override
  Future<double?> tryGetDouble(K key) async {
    final Object? value = _prefs.get(storageKeyOf(key));
    return value is double ? value : null;
  }

  @override
  Future<int?> tryGetInt(K key) async {
    final Object? value = _prefs.get(storageKeyOf(key));
    return value is int ? value : null;
  }

  @override
  Future<String?> tryGetString(K key) async {
    final Object? value = _prefs.get(storageKeyOf(key));
    return value is String ? value : null;
  }

  @override
  Future<List<String>?> tryGetStringList(K key) async {
    final Object? value = _prefs.get(storageKeyOf(key));
    // `is List<String>` looks like the obvious check and is wrong. `get`
    // hands back the plugin's cache verbatim, and that cache is filled from
    // the platform channel, whose codec decodes a list as `List<Object?>` —
    // so a list written in an earlier session comes back untyped and a
    // strict check drops it. The value survives the round trip only within
    // one session, where the cache still holds the exact list that was
    // written, which is why this reads as working until the app restarts.
    // `SharedPreferences.getStringList` casts for the same reason.
    if (value is! List) {
      return null;
    }
    // Element-checked rather than `cast<String>()`: a list of the wrong
    // element type must return null like every other wrong-type read, and
    // `cast` would throw on first access instead. The copy is deliberate —
    // handing back the plugin's own list would let a caller mutate the
    // cache.
    final List<String> strings = <String>[];
    for (final Object? element in value) {
      if (element is! String) {
        return null;
      }
      strings.add(element);
    }
    return strings;
  }

  @override
  Future<void> remove(K key) {
    return _prefs.remove(storageKeyOf(key));
  }
}
