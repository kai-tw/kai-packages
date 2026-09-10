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
