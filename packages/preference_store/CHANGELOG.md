# Changelog

## 0.2.0

**Breaking:** two changes, and the one edit below migrates both.

1. A key is no longer stored under its `toString()`. It is stored under the
   string a new member, `String storageKeyOf(K key)`, returns for it.
   `PreferenceLocalDataSource<K>` declares that member. The class that
   implements the rest is now abstract and leaves it unimplemented, so code
   that constructs it directly no longer compiles. Subclass it and give
   every member of your key enum its string. There is no default and no
   fallback to the old derivation.
2. That class, `PreferenceLocalDataSourceImpl<K>`, is now
   `SharedPreferencesLocalDataSource<K>`. Being abstract, it is no longer an
   implementation by itself, and the name now says which store it sits on.
   There is no alias for the old name. Its file is renamed to match, which
   only matters to code that imported it by path rather than through
   `package:preference_store/preference_store.dart`.

Before:

```dart
final PreferenceLocalDataSource<AppKeys> dataSource =
    PreferenceLocalDataSourceImpl<AppKeys>(prefs);
```

After:

```dart
class AppPreferenceLocalDataSource
    extends SharedPreferencesLocalDataSource<AppKeys> {
  AppPreferenceLocalDataSource(super.prefs);

  @override
  String storageKeyOf(AppKeys key) {
    return switch (key) {
      AppKeys.themeMode => 'AppKeys.themeMode',
      AppKeys.fontSize => 'AppKeys.fontSize',
    };
  }
}

final PreferenceLocalDataSource<AppKeys> dataSource =
    AppPreferenceLocalDataSource(prefs);
```

**To keep values already stored on a device, each string must be exactly
what 0.1.x wrote: `EnumName.memberName`**, as in the snippet. Any other
string is a different key — the value under the old one is neither read nor
moved, and the preference comes back as never written. If a key enum
overrode `toString()`, the string to return is whatever that override
produced.

Write the `switch` with no wildcard arm. It is then exhaustive, and a member
added later does not compile until it has a string.

What the strings buy: the on-device format is now written down where it can
be read, instead of following from identifier names. Renaming a member or
the enum, or overriding `toString()`, no longer changes what is stored.

What the package stops guaranteeing: two key enums could not collide,
because the type name was part of every key. Keys now collide exactly when
two of them are given the same string — in one enum or across two — and the
package does not detect it. Keeping the strings distinct is the consumer's
responsibility.

Anything else that implements `PreferenceLocalDataSource` must provide the
new member too, hand-written fakes and generated mocks alike. A fake does
not compile until it has one. A mock does, because it answers through
`noSuchMethod` — stub `storageKeyOf` on it. Left unstubbed, a call to it
either fails at runtime or returns a placeholder string, depending on the
mocking library.

`PreferenceRepository<T>` is unchanged, and so is every other signature.

Tests went from 34 to 54. Each of the eleven methods that touches the store
is pinned to the returned string: a write by comparing the store's whole key
set afterwards, a read or a `remove` against a store that also holds entries
under the key's `toString()` and `name`. Each of the five reads is also
pinned to return null when a value of its own type sits only under those
two. The cases that pinned the old guarantee now pin the new contract — an
overridden `toString()` has no effect, and two enums given the same string
share one entry.

## 0.1.1

**Fixes a defect that made every stored `List<String>` preference read back
as null after an app restart.**

`tryGetStringList` tested the value with `is List<String>`. `SharedPreferences.get`
returns the plugin's cache verbatim, and that cache is filled from the platform
channel, whose codec decodes a list as `List<Object?>` — so a list written in an
earlier session came back untyped and was dropped. Within one session the cache
still holds the exact list that was written, which is why the round-trip tests
passed and the bug only showed on the next launch: the preference silently
reverted to its default, every time. `SharedPreferences.getStringList` casts for
exactly this reason.

The check is now `is List` plus a per-element check. Element-checked rather than
`cast<String>()`, because a list of the wrong element type has to return null
like every other wrong-type read, and `cast` would satisfy the type system and
then throw on first access. The list handed back is a copy, so a caller cannot
mutate the plugin's cache.

No API change. Consumers storing string-list preferences will see values that
were being lost start being read again — including any written before this fix,
since nothing about the storage format changed.

Tests went from 10 to 34, with the regression group written so it fails on the
old implementation: it seeds the store the way a restart does, rather than
writing and reading in one session, which is the property that hid this.

## 0.1.0

Initial extraction, from NovelGlide's preference feature.

- `PreferenceRepository<T>` — the observable, typed seam a feature-level
  preference repository implements.
- `PreferenceLocalDataSource<K>` / `PreferenceLocalDataSourceImpl<K>` — the
  generic `SharedPreferences` engine underneath, keyed by an app-owned enum.

Differences from the code it was extracted from:

- The key type is generic (`K extends Enum`) instead of hard-coded to one
  app's key enum. Storage is still `key.toString()`, so nothing already
  persisted on a device changes shape.
- Domain entities, per-domain repository implementations, the key enum
  itself, and DI wiring all stayed behind — this package owns only the part
  that was identical across every one of them.
