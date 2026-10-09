import 'package:flutter_test/flutter_test.dart';
import 'package:preference_store/preference_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum _AppKeys { fontSize, isEnabled, volume, userName, tagQueue }

/// Every string here differs from both the member's `toString()`
/// (`_AppKeys.fontSize`) and its `name` (`fontSize`), so a data source that
/// derived a key from the enum instead of asking would read and write
/// somewhere these tests do not look.
class _AppDataSource extends SharedPreferencesLocalDataSource<_AppKeys> {
  _AppDataSource(super.prefs);

  @override
  String storageKeyOf(_AppKeys key) {
    return switch (key) {
      _AppKeys.fontSize => 'app.font_size',
      _AppKeys.isEnabled => 'app.is_enabled',
      _AppKeys.volume => 'app.volume_level',
      _AppKeys.userName => 'app.user_name',
      _AppKeys.tagQueue => 'app.tag_queue',
    };
  }
}

enum _OtherAppKeys { fontSize }

class _OtherAppDataSource
    extends SharedPreferencesLocalDataSource<_OtherAppKeys> {
  _OtherAppDataSource(super.prefs);

  @override
  String storageKeyOf(_OtherAppKeys key) {
    return switch (key) {
      _OtherAppKeys.fontSize => 'other.font_size',
    };
  }
}

/// Gives its one key the string [_AppDataSource] gives `_AppKeys.fontSize`.
class _CollidingDataSource
    extends SharedPreferencesLocalDataSource<_OtherAppKeys> {
  _CollidingDataSource(super.prefs);

  @override
  String storageKeyOf(_OtherAppKeys key) {
    return switch (key) {
      _OtherAppKeys.fontSize => 'app.font_size',
    };
  }
}

enum _OverridingKeys {
  fontSize;

  @override
  String toString() => 'custom.$name';
}

class _OverridingDataSource
    extends SharedPreferencesLocalDataSource<_OverridingKeys> {
  _OverridingDataSource(super.prefs);

  @override
  String storageKeyOf(_OverridingKeys key) {
    return switch (key) {
      _OverridingKeys.fontSize => 'overriding.font_size',
    };
  }
}

/// A store as it looks after a restart: [stored] is already on the device
/// and nothing has been written through a data source yet.
Future<SharedPreferences> _storeHolding(Map<String, Object> stored) {
  SharedPreferences.setMockInitialValues(stored);
  return SharedPreferences.getInstance();
}

void main() {
  late SharedPreferences prefs;
  late PreferenceLocalDataSource<_AppKeys> dataSource;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    prefs = await _storeHolding(<String, Object>{});
    dataSource = _AppDataSource(prefs);
  });

  group('round trip per primitive type', () {
    test('int', () async {
      await dataSource.setInt(_AppKeys.fontSize, 16);
      expect(await dataSource.tryGetInt(_AppKeys.fontSize), 16);
    });

    test('double', () async {
      await dataSource.setDouble(_AppKeys.volume, 0.5);
      expect(await dataSource.tryGetDouble(_AppKeys.volume), 0.5);
    });

    test('bool', () async {
      await dataSource.setBool(_AppKeys.isEnabled, true);
      expect(await dataSource.tryGetBool(_AppKeys.isEnabled), true);
    });

    test('String', () async {
      await dataSource.setString(_AppKeys.userName, 'kai');
      expect(await dataSource.tryGetString(_AppKeys.userName), 'kai');
    });

    test('List<String>', () async {
      await dataSource.setStringList(_AppKeys.tagQueue, <String>['a', 'b']);
      expect(await dataSource.tryGetStringList(_AppKeys.tagQueue), <String>[
        'a',
        'b',
      ]);
    });
  });

  group('missing and mismatched reads both return null', () {
    test('never-written key reads as null for every type', () async {
      expect(await dataSource.tryGetInt(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetDouble(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetBool(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetString(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetStringList(_AppKeys.fontSize), isNull);
    });

    test(
      'stored as one type, read as another → null, not a cast error',
      () async {
        await dataSource.setInt(_AppKeys.fontSize, 16);
        expect(await dataSource.tryGetString(_AppKeys.fontSize), isNull);
        expect(await dataSource.tryGetBool(_AppKeys.fontSize), isNull);
      },
    );
  });

  test('remove clears the value back to null', () async {
    await dataSource.setInt(_AppKeys.fontSize, 16);
    await dataSource.remove(_AppKeys.fontSize);
    expect(await dataSource.tryGetInt(_AppKeys.fontSize), isNull);
  });

  group('every write lands under the string storageKeyOf returns', () {
    // `getKeys()` is compared whole, so a write that also (or instead) went
    // under the member's `toString()` or `name` fails here rather than
    // leaving a stray entry nothing asserts on.

    test('setInt', () async {
      await dataSource.setInt(_AppKeys.fontSize, 16);

      expect(prefs.getKeys(), <String>{'app.font_size'});
      expect(prefs.get('app.font_size'), 16);
    });

    test('setDouble', () async {
      await dataSource.setDouble(_AppKeys.volume, 0.5);

      expect(prefs.getKeys(), <String>{'app.volume_level'});
      expect(prefs.get('app.volume_level'), 0.5);
    });

    test('setBool', () async {
      await dataSource.setBool(_AppKeys.isEnabled, true);

      expect(prefs.getKeys(), <String>{'app.is_enabled'});
      expect(prefs.get('app.is_enabled'), true);
    });

    test('setString', () async {
      await dataSource.setString(_AppKeys.userName, 'kai');

      expect(prefs.getKeys(), <String>{'app.user_name'});
      expect(prefs.get('app.user_name'), 'kai');
    });

    test('setStringList', () async {
      await dataSource.setStringList(_AppKeys.tagQueue, <String>['a', 'b']);

      expect(prefs.getKeys(), <String>{'app.tag_queue'});
      expect(prefs.get('app.tag_queue'), <String>['a', 'b']);
    });
  });

  group('every read and remove goes to the string storageKeyOf returns', () {
    // Each store also holds a different value under the member's
    // `toString()` and under its `name`, so a method that derived its key
    // from the enum would find something — the wrong thing — rather than
    // null.

    test('tryGetInt', () async {
      final PreferenceLocalDataSource<_AppKeys> restored = _AppDataSource(
        await _storeHolding(<String, Object>{
          'app.font_size': 20,
          '_AppKeys.fontSize': 98,
          'fontSize': 99,
        }),
      );

      expect(await restored.tryGetInt(_AppKeys.fontSize), 20);
    });

    test('tryGetDouble', () async {
      final PreferenceLocalDataSource<_AppKeys> restored = _AppDataSource(
        await _storeHolding(<String, Object>{
          'app.volume_level': 0.5,
          '_AppKeys.volume': 0.98,
          'volume': 0.99,
        }),
      );

      expect(await restored.tryGetDouble(_AppKeys.volume), 0.5);
    });

    test('tryGetBool', () async {
      final PreferenceLocalDataSource<_AppKeys> restored = _AppDataSource(
        await _storeHolding(<String, Object>{
          'app.is_enabled': true,
          '_AppKeys.isEnabled': false,
          'isEnabled': false,
        }),
      );

      expect(await restored.tryGetBool(_AppKeys.isEnabled), true);
    });

    test('tryGetString', () async {
      final PreferenceLocalDataSource<_AppKeys> restored = _AppDataSource(
        await _storeHolding(<String, Object>{
          'app.user_name': 'kai',
          '_AppKeys.userName': 'from toString',
          'userName': 'from name',
        }),
      );

      expect(await restored.tryGetString(_AppKeys.userName), 'kai');
    });

    test('tryGetStringList', () async {
      final PreferenceLocalDataSource<_AppKeys> restored = _AppDataSource(
        await _storeHolding(<String, Object>{
          'app.tag_queue': <String>['a', 'b'],
          '_AppKeys.tagQueue': <String>['from toString'],
          'tagQueue': <String>['from name'],
        }),
      );

      expect(await restored.tryGetStringList(_AppKeys.tagQueue), <String>[
        'a',
        'b',
      ]);
    });

    test('remove', () async {
      final SharedPreferences restoredPrefs = await _storeHolding(
        <String, Object>{
          'app.font_size': 20,
          '_AppKeys.fontSize': 98,
          'fontSize': 99,
        },
      );

      await _AppDataSource(restoredPrefs).remove(_AppKeys.fontSize);

      expect(restoredPrefs.getKeys(), <String>{
        '_AppKeys.fontSize',
        'fontSize',
      });
    });
  });

  group('an entry stored only under toString() or name is not read', () {
    // What a consumer changing a member's string has to know: the value
    // under the old string stays on the device and reads as never written.
    // Each store holds values of the type being asked for, so a read that
    // fell back to either entry would return it instead of null.

    test('tryGetInt', () async {
      final SharedPreferences restoredPrefs = await _storeHolding(
        <String, Object>{'_AppKeys.fontSize': 98, 'fontSize': 99},
      );

      expect(
        await _AppDataSource(restoredPrefs).tryGetInt(_AppKeys.fontSize),
        isNull,
      );
      expect(restoredPrefs.getKeys(), <String>{
        '_AppKeys.fontSize',
        'fontSize',
      });
    });

    test('tryGetDouble', () async {
      final SharedPreferences restoredPrefs = await _storeHolding(
        <String, Object>{'_AppKeys.volume': 0.98, 'volume': 0.99},
      );

      expect(
        await _AppDataSource(restoredPrefs).tryGetDouble(_AppKeys.volume),
        isNull,
      );
      expect(restoredPrefs.getKeys(), <String>{'_AppKeys.volume', 'volume'});
    });

    test('tryGetBool', () async {
      final SharedPreferences restoredPrefs = await _storeHolding(
        <String, Object>{'_AppKeys.isEnabled': true, 'isEnabled': true},
      );

      expect(
        await _AppDataSource(restoredPrefs).tryGetBool(_AppKeys.isEnabled),
        isNull,
      );
      expect(restoredPrefs.getKeys(), <String>{
        '_AppKeys.isEnabled',
        'isEnabled',
      });
    });

    test('tryGetString', () async {
      final SharedPreferences restoredPrefs = await _storeHolding(
        <String, Object>{
          '_AppKeys.userName': 'from toString',
          'userName': 'from name',
        },
      );

      expect(
        await _AppDataSource(restoredPrefs).tryGetString(_AppKeys.userName),
        isNull,
      );
      expect(restoredPrefs.getKeys(), <String>{
        '_AppKeys.userName',
        'userName',
      });
    });

    test('tryGetStringList', () async {
      final SharedPreferences restoredPrefs = await _storeHolding(
        <String, Object>{
          '_AppKeys.tagQueue': <String>['from toString'],
          'tagQueue': <String>['from name'],
        },
      );

      expect(
        await _AppDataSource(
          restoredPrefs,
        ).tryGetStringList(_AppKeys.tagQueue),
        isNull,
      );
      expect(restoredPrefs.getKeys(), <String>{
        '_AppKeys.tagQueue',
        'tagQueue',
      });
    });
  });

  test('a caller holding only the interface can ask for the string', () {
    // `dataSource` is typed as the interface, so this compiles only while
    // `storageKeyOf` is declared there and not on the subclass alone.
    expect(dataSource.storageKeyOf(_AppKeys.fontSize), 'app.font_size');
  });

  group('a key enum that overrides toString()', () {
    test('the fixture really does override it', () {
      expect(_OverridingKeys.fontSize.toString(), 'custom.fontSize');
    });

    test('is written under the returned string, not its toString()', () async {
      final PreferenceLocalDataSource<_OverridingKeys> overriding =
          _OverridingDataSource(prefs);

      await overriding.setInt(_OverridingKeys.fontSize, 24);

      expect(prefs.getKeys(), <String>{'overriding.font_size'});
      expect(prefs.get('overriding.font_size'), 24);
    });

    test('is read from the returned string, not its toString()', () async {
      final PreferenceLocalDataSource<_OverridingKeys> overriding =
          _OverridingDataSource(
            await _storeHolding(<String, Object>{
              'overriding.font_size': 20,
              'custom.fontSize': 99,
            }),
          );

      expect(await overriding.tryGetInt(_OverridingKeys.fontSize), 20);
    });
  });

  group('keeping the strings distinct is left to the implementer', () {
    // The store is one flat key space and the data source adds nothing to
    // a string, so the enum a key belongs to separates nothing by itself.

    test('two enums given the same string share one entry', () async {
      final PreferenceLocalDataSource<_OtherAppKeys> colliding =
          _CollidingDataSource(prefs);

      await dataSource.setInt(_AppKeys.fontSize, 16);
      await colliding.setInt(_OtherAppKeys.fontSize, 24);

      expect(await dataSource.tryGetInt(_AppKeys.fontSize), 24);
      expect(await colliding.tryGetInt(_OtherAppKeys.fontSize), 24);
      expect(prefs.getKeys(), <String>{'app.font_size'});
    });

    test('removing through one enum removes it for the other', () async {
      final PreferenceLocalDataSource<_OtherAppKeys> colliding =
          _CollidingDataSource(prefs);

      await dataSource.setInt(_AppKeys.fontSize, 16);
      await colliding.remove(_OtherAppKeys.fontSize);

      expect(await dataSource.tryGetInt(_AppKeys.fontSize), isNull);
    });

    test(
      'two enums with the same member name and different strings do not',
      () async {
        final PreferenceLocalDataSource<_OtherAppKeys> other =
            _OtherAppDataSource(prefs);

        await dataSource.setInt(_AppKeys.fontSize, 16);
        await other.setInt(_OtherAppKeys.fontSize, 24);

        expect(await dataSource.tryGetInt(_AppKeys.fontSize), 16);
        expect(await other.tryGetInt(_OtherAppKeys.fontSize), 24);
        expect(prefs.getKeys(), <String>{'app.font_size', 'other.font_size'});
      },
    );
  });

  group('the full type matrix — a wrong-type read is null, never a throw', () {
    // The package's single most load-bearing documented rule, and the one a
    // consumer leans on without thinking: "a `tryGetXxx` call returns null
    // both when the key was never written and when the stored value is a
    // different runtime type than requested." Five writers against five
    // readers is twenty-five cells; two of them were pinned before.
    //
    // One test per written type rather than a loop over pairs, so a failure
    // names the type that was stored — which is the half a reader needs to
    // start debugging.

    test('written as int', () async {
      await dataSource.setInt(_AppKeys.fontSize, 16);

      expect(await dataSource.tryGetInt(_AppKeys.fontSize), 16);
      expect(await dataSource.tryGetDouble(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetBool(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetString(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetStringList(_AppKeys.fontSize), isNull);
    });

    test('written as double', () async {
      await dataSource.setDouble(_AppKeys.fontSize, 0.5);

      expect(await dataSource.tryGetDouble(_AppKeys.fontSize), 0.5);
      expect(await dataSource.tryGetInt(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetBool(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetString(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetStringList(_AppKeys.fontSize), isNull);
    });

    test('written as bool', () async {
      await dataSource.setBool(_AppKeys.fontSize, true);

      expect(await dataSource.tryGetBool(_AppKeys.fontSize), true);
      expect(await dataSource.tryGetInt(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetDouble(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetString(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetStringList(_AppKeys.fontSize), isNull);
    });

    test('written as String', () async {
      await dataSource.setString(_AppKeys.fontSize, 'kai');

      expect(await dataSource.tryGetString(_AppKeys.fontSize), 'kai');
      expect(await dataSource.tryGetInt(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetDouble(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetBool(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetStringList(_AppKeys.fontSize), isNull);
    });

    test('written as List<String>', () async {
      await dataSource.setStringList(_AppKeys.fontSize, <String>['a']);

      expect(await dataSource.tryGetStringList(_AppKeys.fontSize), <String>[
        'a',
      ]);
      expect(await dataSource.tryGetInt(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetDouble(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetBool(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetString(_AppKeys.fontSize), isNull);
    });

    test(
      'a bool is not readable as the int some platforms store it as',
      () async {
        // Worth its own case because it is the one mismatch a reader is most
        // likely to assume works: Android's SharedPreferences and iOS's
        // NSUserDefaults both back booleans with integers underneath. The
        // plugin hands Dart a real `bool`, so `tryGetInt` finds no int — and
        // an app that relied on the platform detail would get null forever.
        await dataSource.setBool(_AppKeys.isEnabled, false);

        expect(await dataSource.tryGetBool(_AppKeys.isEnabled), false);
        expect(await dataSource.tryGetInt(_AppKeys.isEnabled), isNull);
      },
    );
  });

  group('written-empty is not never-written', () {
    // The distinction the `tryGetXxx` contract deliberately refuses to make
    // is missing-versus-wrong-type. Missing-versus-empty is a different
    // question, and this one the data source *does* answer: an empty value
    // that was written reads back as itself, not as null.

    test('an empty string round-trips as an empty string', () async {
      await dataSource.setString(_AppKeys.userName, '');

      expect(await dataSource.tryGetString(_AppKeys.userName), '');
      expect(await dataSource.tryGetString(_AppKeys.userName), isNotNull);
    });

    test('an empty list round-trips as an empty list', () async {
      await dataSource.setStringList(_AppKeys.tagQueue, <String>[]);

      expect(await dataSource.tryGetStringList(_AppKeys.tagQueue), <String>[]);
      expect(await dataSource.tryGetStringList(_AppKeys.tagQueue), isNotNull);
    });

    test('zero and false are values, not absences', () async {
      await dataSource.setInt(_AppKeys.fontSize, 0);
      await dataSource.setDouble(_AppKeys.volume, 0);
      await dataSource.setBool(_AppKeys.isEnabled, false);

      expect(await dataSource.tryGetInt(_AppKeys.fontSize), 0);
      expect(await dataSource.tryGetDouble(_AppKeys.volume), 0.0);
      expect(await dataSource.tryGetBool(_AppKeys.isEnabled), false);
    });
  });

  group('values that survive the round trip unchanged', () {
    test('negative and large ints', () async {
      await dataSource.setInt(_AppKeys.fontSize, -1);
      expect(await dataSource.tryGetInt(_AppKeys.fontSize), -1);

      // The largest int the VM holds; platform channels marshal 64-bit
      // integers, so this is the boundary a preference could realistically
      // reach by storing a millisecond timestamp far in the future.
      await dataSource.setInt(_AppKeys.fontSize, 9223372036854775807);
      expect(
        await dataSource.tryGetInt(_AppKeys.fontSize),
        9223372036854775807,
      );
    });

    test('a negative double, and one with a fractional tail', () async {
      await dataSource.setDouble(_AppKeys.volume, -0.125);
      expect(await dataSource.tryGetDouble(_AppKeys.volume), -0.125);
    });

    test('unicode, newlines and a value spelled like a stored key', () async {
      // The last one matters: a *value* spelled exactly like the string
      // another key is stored under is still only a value.
      const String awkward = '繁體\n中文 · app.font_size';
      await dataSource.setString(_AppKeys.userName, awkward);

      expect(await dataSource.tryGetString(_AppKeys.userName), awkward);
    });

    test('a list keeps its order and its duplicates', () async {
      await dataSource.setStringList(_AppKeys.tagQueue, <String>[
        'b',
        'a',
        'b',
        '',
      ]);

      expect(await dataSource.tryGetStringList(_AppKeys.tagQueue), <String>[
        'b',
        'a',
        'b',
        '',
      ]);
    });
  });

  group('overwriting and removing', () {
    test('the last write wins, including when it changes the type', () async {
      await dataSource.setInt(_AppKeys.fontSize, 16);
      await dataSource.setString(_AppKeys.fontSize, 'sixteen');

      expect(await dataSource.tryGetString(_AppKeys.fontSize), 'sixteen');
      expect(
        await dataSource.tryGetInt(_AppKeys.fontSize),
        isNull,
        reason: 'the int is gone, not shadowed',
      );
    });

    test('removing a key that was never written is a no-op', () async {
      await dataSource.remove(_AppKeys.userName);

      expect(await dataSource.tryGetString(_AppKeys.userName), isNull);
    });

    test('removing one key leaves its neighbours alone', () async {
      await dataSource.setInt(_AppKeys.fontSize, 16);
      await dataSource.setString(_AppKeys.userName, 'kai');

      await dataSource.remove(_AppKeys.fontSize);

      expect(await dataSource.tryGetInt(_AppKeys.fontSize), isNull);
      expect(await dataSource.tryGetString(_AppKeys.userName), 'kai');
    });

    test('a removed key can be written again', () async {
      await dataSource.setInt(_AppKeys.fontSize, 16);
      await dataSource.remove(_AppKeys.fontSize);
      await dataSource.setInt(_AppKeys.fontSize, 20);

      expect(await dataSource.tryGetInt(_AppKeys.fontSize), 20);
    });
  });

  group('a list that came back from the platform, not from this session', () {
    // The regression group for the defect these tests found. Every other
    // list case here writes and reads inside one session, where the plugin's
    // cache still holds the exact `List<String>` that was handed to it — so
    // they all passed while the real path was broken. The platform channel's
    // codec decodes a list as `List<Object?>`, which is what a preference
    // written before the app was last killed actually looks like on the way
    // back in.

    Future<PreferenceLocalDataSource<_AppKeys>> restoredWith(
      Object stored,
    ) async {
      return _AppDataSource(
        await _storeHolding(<String, Object>{'app.tag_queue': stored}),
      );
    }

    test('an untyped list of strings reads back as a List<String>', () async {
      final PreferenceLocalDataSource<_AppKeys> restored = await restoredWith(
        <Object?>['a', 'b'],
      );

      expect(await restored.tryGetStringList(_AppKeys.tagQueue), <String>[
        'a',
        'b',
      ]);
    });

    test(
      'an untyped empty list reads back as an empty list, not null',
      () async {
        final PreferenceLocalDataSource<_AppKeys> restored = await restoredWith(
          <Object?>[],
        );

        expect(await restored.tryGetStringList(_AppKeys.tagQueue), <String>[]);
      },
    );

    test('it agrees with the plugin own accessor', () async {
      // The shape of the bug was that these two disagreed: the plugin cast
      // and handed the list over, this package refused it and reported the
      // preference as unset.
      final SharedPreferences restoredPrefs = await _storeHolding(
        <String, Object>{
          'app.tag_queue': <Object?>['a', 'b'],
        },
      );
      final PreferenceLocalDataSource<_AppKeys> restored = _AppDataSource(
        restoredPrefs,
      );

      expect(
        await restored.tryGetStringList(_AppKeys.tagQueue),
        restoredPrefs.getStringList('app.tag_queue'),
      );
    });

    test('a list of the wrong element type is null, not a throw', () async {
      // Still a wrong-type read, so it obeys the same rule as every other
      // cell of the type matrix. `cast<String>()` would satisfy the type
      // system here and then throw on first access.
      final PreferenceLocalDataSource<_AppKeys> restored = await restoredWith(
        <Object?>[1, 2],
      );

      expect(await restored.tryGetStringList(_AppKeys.tagQueue), isNull);
    });

    test(
      'a list that is only partly strings is null, not partial data',
      () async {
        final PreferenceLocalDataSource<_AppKeys> restored = await restoredWith(
          <Object?>['a', 2, 'c'],
        );

        expect(await restored.tryGetStringList(_AppKeys.tagQueue), isNull);
      },
    );

    test(
      'the returned list is a copy, so a caller cannot edit the store',
      () async {
        final PreferenceLocalDataSource<_AppKeys> restored = await restoredWith(
          <Object?>['a'],
        );

        final List<String>? first = await restored.tryGetStringList(
          _AppKeys.tagQueue,
        );
        first?.add('b');

        expect(await restored.tryGetStringList(_AppKeys.tagQueue), <String>[
          'a',
        ]);
      },
    );
  });
}
