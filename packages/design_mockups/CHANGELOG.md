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
