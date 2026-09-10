# design_mockups

Mounts an app's **real** widgets and photographs them — every breakpoint ×
state × theme × locale a spec declares — to PNGs, headless. No simulator, no
device, no golden files.

```bash
dart run design_mockups:scan          # collect @MockupPreview annotations
flutter test tool/design_mockups/ --dart-define=MOCKUP_SPEC=settings
```

Output: `build/design-mockups/<slug>/<screen>[__text150]__<size>__<state>__<brightness>__<langTag>.png`

The `__text150` part appears only on a large-text pass. It has to be in the
name: that render is the same screen in the same state, so without it the two
write one path and the survivor is whichever ran last. A run that would collide
fails instead of overwriting.

## What a render is for

Not to check that a picture matches a spec. The widgets under it *are* the
shipped ones, so there is nothing to match. What a render catches is what no
table can: whether the tokens read well **together**, where a layout breaks at
a band boundary, what a long CJK line does at text scale 1.5, and whether dark
mode survived.

Two things it is honest about:

- **It renders one frame.** An animation is photographed wherever it has got
  to; anything whose problem is motion needs a device.
- **Glyph shapes are approximate** unless the app bundles the faces it ships
  with. Line counts, overflow and wrapping are real, which is what this is for.

## Two ways to declare a render

**Annotate the widget's own file.** No fixture file, no registry entry. The
sample data lives beside the widget it belongs to, where a reader looking at
the widget can see what its states actually look like.

```dart
import 'package:design_mockups_annotations/design_mockups_annotations.dart';

@MockupPreview(spec: 'account', screen: 'account_card', state: 'ready')
Widget accountCardReady() => const AccountCard(state: AccountReady(plan: 'Pro'));

@MockupPreview(
  spec: 'account',
  screen: 'account_card',
  state: 'failed',
  sizes: <String>['compact', 'expanded'],
)
Widget accountCardFailed() => const AccountCard(state: AccountLoadFailed());
```

`design_mockups_annotations` is a zero-dependency package and a normal
dependency, so a file in `lib/` can import it. `design_mockups` itself depends
on `flutter_test` and must stay a dev dependency, imported only from `tool/`
and `test/`.

**Declare both, independently.** The two packages do not depend on each other,
so an app lists `design_mockups_annotations` under `dependencies` and
`design_mockups` under `dev_dependencies`, each pinned on its own. That is
forced rather than chosen: pub identifies a dependency by its source
description, so if this package reached its sibling by path, that path — seen
through a git checkout — would never unify with the app's own tag pin, and
version solving would fail with `design_mockups from git is forbidden`. Both
packages therefore spell the `MockupSizes` band ids for their own users; the
API is `Set<String>`, so the two spellings are the same values and mix freely.

**Or write a spec.** For a screen the annotation cannot express — a real page
wired through a service locator, whose mock registration cannot live in `lib/`,
or one frame composed from several widgets at once.

```dart
final MockupSpec settingsSpec = MockupSpec(
  slug: 'settings',
  setUp: registerSettingsMocks,
  tearDown: unregisterSettingsMocks,
  screens: <MockupScreen>[
    MockupScreen(
      name: 'settings_page',
      sizes: <String>{MockupSizes.compact, MockupSizes.expanded},
      states: <MockupState>[
        MockupState(name: 'default', build: (_) => const SettingsPage()),
      ],
    ),
  ],
);
```

Both reach the same runner:

```dart
// tool/design_mockups/run_mockups_test.dart
void main() => runMockups(
  specs: <MockupSpec>[...discoveredMockupSpecs(), settingsSpec],
  config: myAppMockupConfig,
);
```

## The app's half

One `MockupHarnessConfig`. It is data, not an interface, so a project's harness
is a value and a list rather than logic that can be got wrong.

```dart
const MockupHarnessConfig myAppMockupConfig = MockupHarnessConfig(
  theme: buildAppTheme,          // (Locale, Brightness) -> ThemeData
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  defaultLocales: <String>['zh-Hant'],
);
```

## Fonts, and why text comes out as boxes

`flutter test` disables asset fonts and substitutes Ahem, which draws every
glyph as a filled rectangle. A headless render with nothing loaded is therefore
worthless for a CJK app — and it fails *silently*: the PNG exists, its
dimensions are right, and only a person opening it notices.

Loading one broad face is the obvious half-fix, and it leaves the residual
defect: any character that face happens to lack still renders as a box, and it
looks like a bug in the app. What removes the class is a **chain** — several
faces registered under one fallback family, walked per character — plus a theme
that puts that family on every text style, including the component themes that
carry their own (`appBarTheme.titleTextStyle` is the one that bites, because it
renders at the top of every screen).

That is what `MockupFonts` does by default. It also says so on `stderr` when a
family resolved to nothing, rather than letting the boxes speak for themselves.

For a render that is identical on every machine and in CI:

```bash
dart run design_mockups:fetch_fonts   # pinned Noto CJK into .dart_tool/
```

An app that bundles its own brand faces should declare them instead, so the
photograph is of the real typography:

```dart
fonts: MockupFonts(
  primary: MockupFontFamily.bundled(
    family: 'ChironGoRound',
    faces: <MockupFontFace>[
      MockupFontFace('assets/fonts/ChironGoRound-Regular.ttf', weight: 400),
      MockupFontFace('assets/fonts/ChironGoRound-Bold.ttf', weight: 700),
    ],
  ),
),
```

## Selection knobs

Compile-time `--dart-define`, scoped to the one run. An empty filter means
"everything the spec declares"; an absent filter is not an empty one.

| Define | Default | Effect |
|---|---|---|
| `MOCKUP_SPEC` | `smoke` | which spec to render |
| `MOCKUP_LOCALES` | config's `defaultLocales` | CSV of language tags |
| `MOCKUP_THEMES` | `light,dark` | CSV of `light` / `dark` |
| `MOCKUP_SIZES` | (all) | CSV of band ids |
| `MOCKUP_STATES` | (all) | CSV of state names |
| `MOCKUP_SCREENS` | (all) | CSV of screen names |

A run that matches nothing fails rather than reporting success over an empty
directory.
