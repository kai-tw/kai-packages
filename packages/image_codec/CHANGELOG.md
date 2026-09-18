## 0.2.0

**Breaking:** `ImageDecodeException` is now `ImageCodecDecodeException`, and
`ImageEncodeException` is now `ImageCodecEncodeException`. Rename every
reference; nothing else changed. There are no aliases for the old names.

The two are the members of the sealed `ImageCodecException`, and a member of
a sealed family now carries the family's whole name — its category words in
front, its kind word at the end — so that one met in a `switch` arm, a log
line or a stack frame can be traced to its family. `dart_lints`'s new
`sealed_family_naming` rule enforces that, and these two were the only
members in this repository that did not.

## 0.1.2

Relaxes `image` from `^4.5.0` to `>=4.3.0 <5.0.0`, which unblocks any consumer
held at `archive` 3.

`image >=4.4.0` depends on `archive ^4`, so the old constraint silently
imposed archive 4 on every app that took this package — and an EPUB reader
pinned to archive 3 by a vendored parser fork is not an exotic situation. The
first consumer hit exactly that and could not resolve at all. `^4.5.0` was
never a requirement; it was the version this package happened to be developed
against.

`package:image` is used here for three calls in one private function —
`decodeImage`, `encodePng`, and an `on ImageException` — all of which predate
4.3.0 by years.

Verified by forcing the joint solve a consumer will do rather than by reading
version tables: adding `archive: ^3.6.1` as a real constraint (a
`dependency_overrides` bypasses solving rather than simulating it, and
produces a combination pub would never reach on its own) resolves to
image 4.3.0 + archive 3.6.1, with `dart analyze` clean and all 35 tests
passing against it.

A consumer needs no upper bound of its own: `>=4.3.0 <5.0.0` admits 4.3.0
through 4.x, and their own `archive` constraint is what pins it down.

Still open, deliberately not folded in: `package:image` may not need to be
here at all. The fallback decodes bytes and re-encodes them as PNG, and the
engine does both. Dropping it would take `image` and `archive` out of every
consumer's graph — at the cost of losing the `compute()` hop, since the engine
is root-isolate-only. That trades against the same UI thread, so it wants a
measurement and its own decision rather than a quiet change.

## 0.1.1

**Use this instead of 0.1.0.** That tag ships `encodeWebp` with its resize
parameters named `maxWidth`/`maxHeight`, which is backwards: they are a floor
on the result, not a ceiling. `maxHeight: 2000` returns something 2400 tall.
The names are `minWidth`/`minHeight` again — the plugin's own, and correct.

Nothing else changed. 0.1.0 was tagged and had no consumers when the defect
was found, so it is left in place rather than moved.

Also corrects `decodeImageSizes`' doc, which asserted that a header read is
too cheap for a `compute()` hop to be worth it. That claim was inherited from
the source contract and never tested. The engine is root-isolate-only, so this
package cannot offer that hop at all — a consumer migrating off a pure-Dart
reader that DID use `compute()` is moving real CPU onto the UI thread, and the
doc now says so and tells them to measure their own largest batch.

## 0.1.0

Initial release. Extracts NovelGlide's `ImageProcessor` into a shared package,
as **two** types rather than one: `ImageCodec` reads facts out of bytes
(`readImageSize`, `isPixelDataComplete`, `decodeImageSizes`) and `WebpEncoder`
turns bytes into other bytes (`encodeWebp`). Plus the `ImageSize` value object.

The split is not cosmetic. The two halves have different dependencies
(`dart:ui` versus `package:image` + a native plugin), different failure modes,
and different testability: every read is exercised by the unit suite, while
nothing in the encoder runs under `flutter test` at all — no platform
compressor is registered there. As one file, mutation testing scored 41%,
which reads as "under-tested" and actually meant "one well-tested half
averaged with one unreachable half". As two: 100% and 32%, both true.

The product is the **unified exception interface**, not the individual
operations. Three libraries underneath fail in three shapes across two type
hierarchies — the engine throws a bare `Exception` with no subtype (every
`dart:ui` native call routes failure through one `_futurize` bridge that
hardcodes it), `package:image` throws `ImageException implements Exception`,
and `flutter_image_compress` throws `CompressError extends Error`. A consumer
now catches `ImageCodecException` and nothing else.

Two of those three could not be handled by catching, and the reason is worth
recording because it shaped the design:

- `dart:ui` offers no narrower type to catch and no predicate to ask first, so
  a single file — `engine_image_boundary.dart` — holds the entire engine
  surface and is the one file exempted from `avoid_catching_base_exception`.
  The exemption is a path glob naming exactly that file, declared before
  `production` in `dart_lints.yaml` so it wins the overlap. Moving an engine
  call into a second file would widen a lint exemption rather than reorganise
  code.
- `flutter_image_compress` throws `UnsupportedError` on any non-mobile platform
  and `UnimplementedError` when no platform implementation is registered. Both
  are on `avoid_catching_error`'s fixed list, so **no catch clause could have
  fixed this**. `encodeWebp` checks the platform *before* calling instead —
  prevention converts a class of uncatchable `Error` into this package's own
  exception without a catch anywhere. `package:image`'s `TypeError`/`RangeError`
  on truncated input is prevented the same way: `isPixelDataComplete` gates the
  fallback, so the decoder is never handed bytes that trigger them.

**`encodeWebp` resizes**, and the parameters are a FLOOR on the result rather
than a ceiling: the image shrinks by the smallest factor that brings one axis
to its limit, so 4032x3024 at the defaults comes back 1920x1440 — height 360px
*above* the 1080 limit. `flutter_image_compress`'s `minWidth`/`minHeight` names
are therefore correct, and are passed through unchanged rather than renamed;
the defaults are stated explicitly at the call site so the transform is visible.

**Reads are root-isolate only**, and this is the one silent failure mode: from
a spawned isolate the engine's decoder registry is unreachable, the decode
fails, and that is reported as "not a readable image" — a good image returns
`null`. Consumers replacing a pure-Dart header parser must check every call
site for `Isolate.spawn`/`compute()` first; the code being replaced was
isolate-safe and this is not.

Tests are in two halves, both green (27 tests): contract-derived under `test/`,
spec-derived under `test/spec/`. Fixtures are encoded through `dart:ui` at test
time rather than hand-assembled, because a hand-built byte stub is a valid input
for a header parser and not for a real decoder. All use plain `test()` — a
`testWidgets` body rewrites throws into generic framework failures and deadlocks
against real engine work, surfacing as a ten-minute timeout instead of a failed
assertion.

Known limitations are in the README: `webp_encoder.dart` being structurally
unmeasurable by the unit suite, the passthrough's inability to detect a
wrong-but-plausible native decode, `ImageDecodeException` currently having no
thrower, and one engine handle — `ui.ImmutableBuffer` — whose release cannot
be asserted at all, because `base class` forbids a test implementing it.

The standing rules a future editor must not break — the one-file `dart:ui`
surface, prevent-don't-catch, keeping the two types separate, and why the
factory seam is not test cruft — are in this package's `CLAUDE.md`.
