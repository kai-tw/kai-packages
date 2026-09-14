## 0.1.2

Precaches every image the mounted tree will paint, not only `Image` widgets.

The scan was `find.byType(Image)`, which finds nothing in an app that paints
its photos through `BoxDecoration(image:)` — a scrim or a gradient over a
photo, which is the ordinary way to do it. Nothing was precached, and an asset
decodes on the real event loop that a widget test only reaches inside
`runAsync`, so the image first resolved during the CAPTURE's `runAsync` —
after the frame had been rasterised.

What that produced was a first-use miss, and its shape is what made it
expensive: the first render to use an asset photographed the scrim over bare
background, and every later render of it was fine, because by then the decode
sat in the process-wide image cache. So a light/dark pair came out as one
blank card and one correct one, which reads as "the photo is too pale" or "the
widget's layers are wrong" and sends you editing widgets that were never
broken.

The scan now walks the element tree, naming the widgets whose image reaches
the screen through a render object of their own — `Image`, and the
`BoxDecoration` / `ShapeDecoration` of a `DecoratedBox`, a `DecoratedSliver`,
a `Table` row and an `Ink`. Anything that composes from those needs no entry
and has none: `Container`, `CircleAvatar`, `FadeInImage` and friends are
covered because the walk reaches what they build, which the new tests pin
directly.

Still not covered, and not coverable by any widget scan: an image painted by a
`CustomPainter` (`TabBar.indicator`), and an app's own `Decoration` subclass
holding a provider this package cannot know about.

## 0.1.1

Drops this package's dependency on `design_mockups_annotations`, which made the
pair impossible to consume: an app pins both by git tag, and pub identifies a
dependency by its source description rather than by the commit it resolves to.
The sibling `path:` dep, seen through a git checkout, described itself as "git
at `<sha>` in packages/design_mockups_annotations" while the app's own dep said
"git at design_mockups_annotations-v0.1.0 in …" — the same commit, two
descriptions, and `design_mockups from git is forbidden`. A workspace-root
`dependency_overrides` cannot paper over it either; pub refuses to override a
workspace member.

So the two packages are now strangers, each declaring the `MockupSizes` band
ids for its own users. The API is `Set<String>`, so a band named through either
package is the same value and they mix freely at every call site.

**Migrating from 0.1.0:** declare both packages, each pinned on its own — the
barrel no longer re-exports `@MockupPreview`. A `tool/` fixture that only names
bands and specs needs no change.

## 0.1.0

Initial release. Merges two design-mockup harnesses that had grown up
separately in two consuming apps, keeping what each got right:

- The capture recipe from both, reconciled: image-precache rounds and a bounded
  settle, and — where they disagreed — a settle timeout that photographs the
  frame anyway and warns, rather than either failing the render or never
  waiting. A `loading` state never settles by construction, so failing on it
  was wrong; not waiting at all meant photographing screens mid-build.
- Per-screen `textScale`, so the large-text pass is a screen entry whose name
  says what it is.
- Multi-locale rendering, with an unsupported language tag refused rather than
  silently falling back to another locale.
- A font layer built around a **chain**, plus a theme rewrite that reaches the
  component themes carrying their own `TextStyle`. This is the tofu fix.
- `@MockupPreview` and the `scan` entry point: a preview declared beside the
  widget it previews, with no fixture file and no registry to keep in step.
