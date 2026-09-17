# image_codec

Reads facts out of image bytes, and turns image bytes into other image bytes —
behind one exception type.

Bytes in, bytes out. A consumer never picks a decoding library, never imports
one, and never learns that three of them fail in three different shapes.

```dart
final ImageSize? size = await ImageCodec.readImageSize(bytes);
final bool whole = await ImageCodec.isPixelDataComplete(bytes);
final Uint8List webp = await WebpEncoder.encodeWebp(bytes);   // Android/iOS
```

Two types, deliberately. `ImageCodec` reads facts out of bytes;
`WebpEncoder` turns bytes into other bytes. They have different dependencies
(`dart:ui` versus `package:image` plus a native plugin), different failure
modes, and different testability — every read is exercised by the unit suite,
while nothing in the encoder runs under `flutter test` at all.

## Two questions that look like one

Reading a header and decoding pixels are different operations, and the gap
between them is the reason this package exists:

- **`readImageSize`** asks the engine what the header *declares*. It never
  materialises the bitmap, so it is fast — and it reports a truncated file's
  dimensions perfectly happily, because nothing ever walks past the header.
- **`isPixelDataComplete`** decodes to a 1x1 target. That walks far enough into
  the stream to fail on a truncated or corrupt body, at the cost of one pixel
  rather than the whole image.

A truncated file returns dimensions from the first and `false` from the second.
Code that needs "is this a real, whole image" and asks only the first has a
hole.

## The unified exception

Three libraries sit underneath, failing in three shapes across **two** type
hierarchies:

| Source | What it throws |
|---|---|
| the Flutter engine (`dart:ui`) | a bare `Exception`, no subtype — every native call routes failure through one `_futurize` bridge that hardcodes it |
| `package:image` | `ImageException implements Exception` |
| `flutter_image_compress` | `CompressError extends **Error**` |

A caller catches `ImageCodecException` and nothing else.

**Reads do not throw at all.** "These bytes are not an image" is an ordinary
answer for a cover a user picked or an image pulled out of an EPUB, so
`readImageSize` returns `null`, `isPixelDataComplete` returns `false`, and
`decodeImageSizes` omits the entry. Only the encode path throws.

## Root isolate only

Every read goes through the engine, and the engine's decoder registry is
reachable only from the root isolate. From a spawned isolate these calls do not
raise a clear error — the decode fails, and this package reports that as "not a
readable image". **A perfectly good image comes back `null`.**

That is the one silent failure mode here. If you are replacing a pure-Dart
header parser with this package, check every call site for `Isolate.spawn` /
`compute()` first: the code being replaced was isolate-safe and this is not, so
a call that reads as unchanged has changed meaning. A comment claiming
"isolate-safe" beside such a call is describing the old implementation.

## `decodeImageSizes` omits; it does not degrade

An entry whose dimensions cannot be read is **left out of the result map**. A
missing key means the consumer drops that image entirely, not that it renders
without dimensions.

If you build output by iterating the result map, an unreadable input **silently
vanishes**. To degrade instead of dropping, iterate your own input keys and look
each one up.

## `WebpEncoder.encodeWebp` is Android and iOS only, and it resizes

`flutter_image_compress` hard-gates WebP to those two platforms and throws
`UnsupportedError` elsewhere; with no platform implementation registered — the
state of every plain `flutter test` — its stub throws `UnimplementedError`. Both
are `Error` subtypes, which this repo's `avoid_catching_error` forbids catching,
so this package **checks the platform before calling** rather than catching
after. On any other platform you get an `ImageCodecEncodeException`, not a
raw `Error`.

It also **resizes large sources**, and the parameter names mean the opposite of
what most people read them as. `minWidth`/`minHeight` (default 1920x1080) are a
**floor on the result, not a ceiling**:

```
scale  = max(1.0, min(srcW / minWidth, srcH / minHeight))
result = src / scale
```

The image shrinks by the smallest factor that brings **one** axis to its limit;
the other lands above its own. A 4032x3024 photo comes back **1920x1440** —
width exactly 1920, height 360px over the 1080 "limit". Both axes end up at or
above their minimum, which is what `min` means here.

`minHeight: 2000` does **not** cap the height at 2000. It guarantees the result
is at least 2000 tall. Nothing is ever scaled up — the `max(1.0, …)` clamp
means a source already under both limits passes through untouched.

The names are upstream's on purpose: they are correct, and a second vocabulary
here would only put distance between you and the plugin's own FAQ.

## What this is not

- Not image **rendering or display** — this produces bytes and facts; painting
  them is the consumer's.
- Not **where converted bytes land** — storage and cache placement are policy,
  and policy lives one layer up.
- Not a **decode ceiling** — deciding how many pixels an image needs on screen
  requires a widget's constraints, which a package cannot see.

## Known limitations

- **`webp_encoder.dart` is structurally unmeasurable by the unit suite.** The
  compressor cannot run under `flutter test` at all (no registered platform
  implementation), so every line after the platform guard is unreachable
  there. Mutation testing scores it 32%, and that number will not improve by
  writing more unit tests — only `integration_test/` on a real device moves
  it. What the suite does pin is that failure arrives as `ImageCodecException`
  rather than as one of the three underlying shapes.

  This is why the encoder is its own file. Combined with the read half the
  score was 41%, which reads as "under-tested" and actually meant "one
  well-tested half averaged with one unreachable half". Split, the two numbers
  are 100% and 32% — both true, and the per-file gate now means something on
  the half where it can.
- **The passthrough cannot detect a wrong-but-plausible native decode.** Its
  output is verified by reading the dimensions back, which catches "not an image
  at all" but not correct-sized-wrong-pixels. Establishing that needs a real
  device.
- **`ImageCodecDecodeException` currently has no thrower.** It is exported for
  the decode failures the encode path reports, which today all surface as
  `ImageCodecEncodeException`.
- **One engine handle's release is unpinnable.** Three of the four `dispose()`
  calls in the boundary have tests that go red when the call is deleted;
  `ui.ImmutableBuffer.dispose()` does not, because `ImmutableBuffer` is a
  `base class` and the language forbids implementing it outside its own
  library. Mutation testing reports that deletion as a surviving mutant
  permanently — it is a known gap with a named cause, not an oversight, and
  not an equivalent mutant either: deleting it really does leak.
