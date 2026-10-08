/// A typed, enum-keyed wrapper over `SharedPreferences`.
///
/// [K] is the app's own preference-key enum. This package never sees its
/// members and derives nothing from them: a key is stored under the string
/// [storageKeyOf] returns for it.
///
/// A `tryGetXxx` call returns `null` both when the key was never written
/// and when the stored value is a different runtime type than requested —
/// callers cannot and should not distinguish the two.
///
/// For [tryGetStringList] the type check is per element rather than on the
/// list itself, because a list restored from the platform arrives untyped:
/// a list of strings is returned however it is typed, and a list holding
/// anything else is `null` like any other wrong-type read.
abstract class PreferenceLocalDataSource<K extends Enum> {
  /// The string [key] is stored under.
  ///
  /// These strings are the on-device format. Once an app has shipped,
  /// returning a different string for a member leaves the value stored
  /// under the old one behind, unread. Implement this as one exhaustive
  /// `switch` over [K] with no wildcard arm, so that a member added later
  /// does not compile until it has been given a string.
  ///
  /// Keeping the strings distinct is the implementer's job.
  /// `SharedPreferences` is one flat key space, so two keys given the same
  /// string — in one enum or across two — read and write the same entry,
  /// and nothing here detects it.
  ///
  /// A key's `toString()` and `name` play no part: renaming a member or
  /// the enum, or overriding `toString()`, changes nothing that is stored.
  String storageKeyOf(K key);

  Future<int?> tryGetInt(K key);

  Future<double?> tryGetDouble(K key);

  Future<bool?> tryGetBool(K key);

  Future<String?> tryGetString(K key);

  Future<List<String>?> tryGetStringList(K key);

  Future<void> setInt(K key, int value);

  Future<void> setDouble(K key, double value);

  Future<void> setBool(K key, bool value);

  Future<void> setString(K key, String value);

  Future<void> setStringList(K key, List<String> value);

  Future<void> remove(K key);
}
