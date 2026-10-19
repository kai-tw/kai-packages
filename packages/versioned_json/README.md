# versioned_json

Persisted JSON that carries its own schema version, is brought up to date one
step at a time, and is never read or overwritten by a build older than the one
that wrote it — plus field-by-field operations on a flat record's JSON.

The library imports `dart:io`, so it runs on the Dart VM and Flutter's native
platforms, not on the web.

## Schemas

One schema per persisted format. It owns the format's whole history: the
current version, the steps from every older one, and the DTO today's shape
parses into. Callers never see the version or the map in between: they read a
DTO or a refusal.

```dart
class NoteDto implements VersionedJsonDto {
  const NoteDto({required this.text, required this.createdAt});

  factory NoteDto.fromJson(Map<String, dynamic> json) => /* generated */;

  final String text;
  final DateTime createdAt;

  @override
  Map<String, dynamic> toJson() => /* generated */;
}

class NoteSchema extends VersionedJsonFileSchema<NoteDto> {
  const NoteSchema();

  @override
  int get currentVersion => 2;

  @override
  Map<String, dynamic> migrateOneStep(
    Map<String, dynamic> source,
    int sourceVersion,
    DateTime modifiedAt,
  ) => switch (sourceVersion) {
    1 => <String, dynamic>{
      ...source,
      'schemaVersion': 2,
      'createdAt': modifiedAt.toUtc().toIso8601String(),
    },
    _ => throwNoStepFrom(sourceVersion),
  };

  @override
  NoteDto fromJson(Map<String, dynamic> json) => NoteDto.fromJson(json);
}
```

The DTO carries no version. The schema stamps `schemaVersion` when it encodes
one, and reads the stored version before the DTO is ever parsed. A document
without `schemaVersion`, or with `null` there, is version 1, so files written
before the format was versioned stay readable. A format that existed on disk
unversioned therefore starts at 2; one that carried a version from its first
write may stay at 1 and needs no steps.

Three rules make this safe to run over data you can't regenerate:

- **A shipped step is frozen.** It reads and writes the map alone, never
  today's DTO or domain types: its job is to produce the shape the next
  version had *when it shipped*, and today's types have moved on since. Keep
  the steps in a private class of their own, away from the DTO-facing code.
- **A newer version is never read and never overwritten.** The build that
  wrote it needs it back intact.
- **An enum code this build doesn't know is refused too.** Override
  `holdsUnknownCode` for a format with coded fields. Read with a default member
  in the code's place, the document would be written back with that member
  over the newer value.

Every hook a subclass implements is `@protected`.

## Lenient reads: files kept on disk

`VersionedJsonFileSchema` is for a file this build owns. A document it may not
act on reads as `null`, so the caller falls back to an empty value rather than
overwriting it. A newer build's document stays on disk untouched. An older
document that holds an unknown enum code is different: it's migrated and
written back at the current version first, with the code kept as stored (a
step passes it through like any other field), and only then reads as `null`:

```dart
const NoteSchema schema = NoteSchema();

final NoteDto? note = await schema.readFile(file);
await schema.writeFile(file, updated);
final NoteDto? downloaded = schema.readString(text, downloadedAt);

// A sweep at startup, so every file is at the current version.
await schema.migrateDirectory(notesDir);
```

`readFile` and `readString` answer `null` for a missing or unreadable file, an
empty one, bytes that aren't UTF-8 or JSON, JSON that is no object, a version
that is no integer or is below 1, a version above `currentVersion`, and an
unknown enum code. Anything `fromJson` throws propagates: that's a mismatch
between the last step and the DTO, a bug rather than missing data.

A read migrates in place. An older file is rewritten once, after every step,
at the current version — even when the last step forgot to stamp it.
`migrateFile` does the same without parsing, and `migrateDirectory` runs it
over every `.json` file in a directory. Both are idempotent.

`modifiedAt`, passed to each step, is the file's modification time, or for
`readString`, whatever time the caller passes in (the download time, say). A
step uses it to fill in a timestamp the old shape didn't record.

## Atomic writes

`writeFile` and every write-back stage the bytes in `<file>.tmp` next to the
target, flush them, and rename the staging file over the target. A rename is
atomic within one file system, so a reader sees the old document or the new,
never part of one. A failed write leaves the target as it was and removes the
staging file.

**The caller must serialize writes to one file.** The staging name is fixed,
so two writes to the same target at once share `<file>.tmp`. Run them one
after another; writes to different files don't interfere.

A crash between the two steps can leave a stray `<file>.tmp`. Its name doesn't
end in `.json`, so no read or sweep touches it, and the next write to that
target replaces it.

## Strict reads

A store that has to tell a newer build's document from a corrupt one reads
through the protected `decodeBytes`, which returns the DTO or throws the
`VersionedJsonReadException` that says why not:

| Refusal | When |
|---|---|
| `VersionedJsonReadNewerException` | The version is above `currentVersion`. |
| `VersionedJsonReadUnknownCodeException` | `holdsUnknownCode` is true for the migrated document. |
| `VersionedJsonReadCorruptException` | Not UTF-8 or JSON, no object, a version that is no integer or is below 1, or a `CheckedFromJsonException` from `fromJson`. |

```dart
enum NoteRefusal { needsUpdate, corrupt }

class StrictNoteSchema extends NoteSchema {
  const StrictNoteSchema();

  /// Why [bytes] can't be read, or null when they can.
  NoteRefusal? refusalOf(Uint8List bytes, DateTime modifiedAt) {
    try {
      decodeBytes(bytes, modifiedAt);
      return null;
    } on VersionedJsonReadException catch (e) {
      return switch (e) {
        VersionedJsonReadNewerException() ||
        VersionedJsonReadUnknownCodeException() => NoteRefusal.needsUpdate,
        VersionedJsonReadCorruptException() => NoteRefusal.corrupt,
      };
    }
  }
}
```

Each carries `storedVersion`, the version on disk, and never the document, so
they're safe to log. They're all `FormatException`s, so a caller that already
skips malformed input skips them too.

`decodeBytesWithin` reads a document whose content moved into this format out
of another schema's document, and every refusal reports the outer document's
version. `readMigrated` hands a reader the migrated map, for salvaging one
value out of a document that may not decode as a whole.

A schema asked for a step it doesn't hold throws `VersionedJsonMigrationError`.
That's a programming error — `currentVersion` raised without the step that
reaches it — not something a stored file can cause, so it's a `StateError`,
which an `on FormatException` doesn't catch.

## Field-by-field

For a flat record whose JSON keys are its field enum's names, `FieldwiseJson`
copies chosen fields from one value into another and lists which fields
changed, without a hand-written branch per field:

```dart
enum PlantField { name, height, care, beds }

const FieldwiseJson<PlantValues, PlantField> plantFieldwise =
    FieldwiseJson<PlantValues, PlantField>(
      fields: PlantField.values,
      nonValueFields: <PlantField>{PlantField.beds},
      toJson: plantToJson,
      fromJson: PlantValues.fromJson,
    );

final PlantValues merged = plantFieldwise.take(
  <PlantField>[PlantField.height],
  into: mine,
  from: theirs,
);
final Set<PlantField> edited = plantFieldwise.changed(before, after);
```

`nonValueFields` names fields the values JSON doesn't carry — a set merged
somewhere else, say; `take` and `changed` pass over them.

`changed` compares JSON, deeply, not Dart objects. That's the point — the same
instant as local time and as UTC is `!=` in Dart but one value in JSON — and
it's also the precondition: **`toJson` must be canonical**, writing equivalent
values identically.

## Checking a consumer's own types

A per-field `switch` gets exhaustiveness from the compiler; going through JSON
gives that up, so `package:versioned_json/testing.dart` hands it back as test
checks. Each returns a list of mismatches, so it works with any test framework:

```dart
import 'package:versioned_json/testing.dart';

expect(plantFieldwise.keyMismatches(fullySetPlant), isEmpty);
expect(plantFieldwise.roundTripMismatches(sampleJson), isEmpty);
expect(plantFieldwise.equivalenceMismatches(atUtc, sameInstantLocal), isEmpty);
```

`keyMismatches` fails when a new enum member has no key in `toJson`.

## Status

`0.2.0`, distributed as a git dependency rather than on pub.dev:

```yaml
versioned_json:
  git:
    url: https://github.com/kai-tw/kai-packages.git
    path: packages/versioned_json
    ref: versioned_json-v0.2.0
```

0.2.0 replaces the 0.1.0 API; see the [changelog](CHANGELOG.md). The version
key, `schemaVersion`, is persisted by every consumer and doesn't change without
a major version.
