# kai-packages

Dart packages shared across my apps. One repo, one lockfile, one CI run — a
[pub workspace](https://dart.dev/tools/pub/workspaces), so two packages here can
never disagree about a dependency version.

| Package | |
|---|---|
| [`hybrid_logical_clock`](packages/hybrid_logical_clock) | Timestamps two devices order the same way without agreeing on a wall clock. |
| [`design_mockups`](packages/design_mockups) | Photographs an app's real widgets across breakpoint × state × theme × locale, headless. |
| [`design_mockups_annotations`](packages/design_mockups_annotations) | The `@MockupPreview` annotation, so a widget in `lib/` can declare its own renders. |
| [`ui_kit`](packages/ui_kit) | A UI kit that shares Flutter components through my projects. |

## Working on it

```bash
flutter pub get   # resolves every member together, from the root
                   # (the Flutter SDK is required now that ui_kit is a member)
dart analyze
dart test
```

## What belongs here

Something lands here when a **second** app needs it and the boundary is clean
enough that neither app's framework leaks across. Two rules follow from that:

- **No Flutter dependency unless the package genuinely needs one.** A pure Dart
  package runs on servers, in CLIs and in tests without a device. Adding
  `flutter` is not reversible without a breaking change, so it is not added to
  make a name look consistent.
- **The binding stays in the app.** `hybrid_logical_clock` hands back a stamp
  map encoded as one JSON string; which column holds it, and which record types
  have one, is the app's. What is shared is the algorithm, not the storage.
