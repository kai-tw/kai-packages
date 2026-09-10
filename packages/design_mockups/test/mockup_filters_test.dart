import 'package:design_mockups/design_mockups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MockupFilters', () {
    const List<Locale> supported = <Locale>[Locale('zh', 'TW'), Locale('en')];

    MockupFilters filters({
      Set<String> locales = const <String>{},
      Set<String> themes = const <String>{},
      Set<String> sizes = const <String>{},
      Set<String> states = const <String>{},
      Set<String> screens = const <String>{},
    }) => MockupFilters(
      spec: 'smoke',
      locales: locales,
      themes: themes,
      sizes: sizes,
      states: states,
      screens: screens,
    );

    test('an absent filter selects everything, which is not the same as an '
        'empty one', () {
      final MockupFilters all = filters();
      expect(all.wantsSize('compact'), isTrue);
      expect(all.wantsState('anything'), isTrue);
      expect(all.wantsScreen('whatever'), isTrue);
    });

    test('a present filter selects only what it names', () {
      final MockupFilters narrowed = filters(sizes: <String>{'compact'});
      expect(narrowed.wantsSize('compact'), isTrue);
      expect(narrowed.wantsSize('expanded'), isFalse);
    });

    test('locales fall back to the config default when none are asked for', () {
      expect(filters().resolveLocales(supported, <String>['zh-TW']), <Locale>[
        const Locale('zh', 'TW'),
      ]);
    });

    test('a language tag matches case-insensitively', () {
      expect(
        filters(locales: <String>{'ZH-tw'}).resolveLocales(supported, const []),
        <Locale>[const Locale('zh', 'TW')],
      );
    });

    test('an unsupported locale throws rather than falling back', () {
      // A silent fallback renders a different locale than the one asked for,
      // and nothing in the output filename says so.
      expect(
        () => filters(
          locales: <String>{'ja'},
        ).resolveLocales(supported, const []),
        throwsArgumentError,
      );
    });

    test('brightnesses fall back to the config default', () {
      expect(
        filters().resolveBrightnesses(<Brightness>[Brightness.dark]),
        <Brightness>[Brightness.dark],
      );
    });

    test('an unknown theme name throws', () {
      expect(
        () => filters(themes: <String>{'sepia'}).resolveBrightnesses(const []),
        throwsArgumentError,
      );
    });
  });
}
