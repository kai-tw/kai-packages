# preference_store

Typed, enum-keyed access over `SharedPreferences`.

Extracted from NovelGlide, where fourteen preference domains (reader
settings, TTS, cloud sync, …) all wrapped the same generic engine: a typed
repository seam over a key-value store, keyed by an enum instead of a raw
string. This package is that engine, and nothing else.

```dart
enum AppKeys { themeMode, fontSize }

class AppPreferenceLocalDataSource
    extends SharedPreferencesLocalDataSource<AppKeys> {
  AppPreferenceLocalDataSource(super.prefs);

  @override
  String storageKeyOf(AppKeys key) {
    return switch (key) {
      AppKeys.themeMode => 'app.theme_mode',
      AppKeys.fontSize => 'app.font_size',
    };
  }
}

final SharedPreferences prefs = await SharedPreferences.getInstance();
final PreferenceLocalDataSource<AppKeys> dataSource =
    AppPreferenceLocalDataSource(prefs);

await dataSource.setInt(AppKeys.fontSize, 16);
final int? fontSize = await dataSource.tryGetInt(AppKeys.fontSize);
```

## What this package does not do

- **No entities.** `AppearancePreferenceData`, `ReaderPreferenceData` and
  the rest of NovelGlide's fourteen domain shapes stayed behind — this
  package has no opinion on what your preferences look like.
- **No key enum, and no key strings.** You own `AppKeys` (or however many
  enums you need) and the string each member is stored under; the data
  source derives nothing from a key, it asks your `storageKeyOf`.
- **No DI wiring.** Register your subclass of
  `SharedPreferencesLocalDataSource` with whatever service locator (or none)
  your app already uses.

## The two symbols

### `PreferenceRepository<T>`

```dart
abstract class PreferenceRepository<T> {
  Stream<T> get onChangeStream;
  Future<T> getPreference();
  Future<void> savePreference(T data);
  Future<void> resetPreference();
}
```

The contract every feature-level preference repository implements. This
package ships the interface only — each domain's `getPreference` /
`savePreference` (how `T` maps to primitives), and how instances get
composed and handed to consumers, is app-specific and lives in the app.
Nothing here assumes `get_it` or any other DI framework — a constructor
call, a Riverpod provider, and a `get_it` registration all work the same
way against this interface.

One convention worth naming, since it isn't obvious from the type alone:
a `typedef` per domain turns the shared generic type into a distinct
name:

```dart
typedef ReaderPreferenceRepository = PreferenceRepository<ReaderPreferenceData>;
```

That is what lets a service locator keyed on static type — `get_it` is
one, not the only one — tell `ReaderPreferenceRepository` and
`TtsPreferenceRepository` apart even though both extend the same generic
base. An app wiring this by hand (or through a different DI approach
entirely) has no need for the typedef; it exists for the "distinct
named type" use case, not as part of this package's contract.

### `PreferenceLocalDataSource<K>` / `SharedPreferencesLocalDataSource<K>`

The engine underneath: `tryGetInt` / `setInt` / … against
`SharedPreferences`, where `key` is a value of your own enum `K` and is
stored under the string your `storageKeyOf(key)` returns.

**The package derives no key — you write each one down.**
`SharedPreferencesLocalDataSource<K>` is abstract and leaves `storageKeyOf`
unimplemented, so a data source cannot exist until every member of `K` has
been given a string. Write it as one exhaustive `switch` with no wildcard
arm, as in the example above: a member added later then does not compile
until it has a string of its own.

Three things follow from that:

- **The strings are the on-device schema.** Once an app has real users,
  returning a different string for a member strands their existing value
  behind a key nothing reads anymore. Nothing moves it and nothing warns.
- **The identifiers are not.** A key's `toString()` and `name` are never
  consulted, so renaming a member or the enum, or overriding `toString()`,
  changes nothing that is stored.
- **Keeping the strings distinct is your job.** `SharedPreferences` is one
  flat key space and the data source adds nothing to a string. Two keys
  given the same string — in one enum or across two — are one entry, each
  overwriting the other, and the package does not detect it.

Upgrading from 0.1.x with values already on devices: the strings that keep
them readable are in the 0.2.0 entry of [CHANGELOG.md](CHANGELOG.md).

`tryGetXxx` returns `null` for a missing key and for a stored value of the
wrong runtime type alike — a caller cannot and should not tell the two
apart; both mean "there is nothing usable here yet," which is the signal
that lets a repository fall back to its default.
