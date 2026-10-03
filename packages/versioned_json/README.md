# versioned_json

Persisted JSON that carries its own schema version and is brought up to date
one step at a time — plus field-by-field operations on a flat record's JSON.

Pure Dart. The core library imports no `dart:io`; file helpers live in a
separate library.

## Migrations

Every format declares one migrator. The version lives under `schemaVersion`;
JSON without that key reads as version 1, so files written before the format
was versioned stay readable.

```dart
class NoteMigrator extends VersionedJsonMigrator {
  const NoteMigrator();

  @override
  int get currentVersion => 2;

  @override
  Map<String, dynamic> migrateOneStep(
    Map<String, dynamic> source,
    int sourceVersion,
    DateTime modifiedAt,
  ) {
    return switch (sourceVersion) {
      1 => <String, dynamic>{
        ...source,
        'createdAt': modifiedAt.toUtc().toIso8601String(),
        VersionedJsonMigrator.versionKey: 2,
      },
      _ => throw StateError('no step from version $sourceVersion'),
    };
  }
}

final Map<String, dynamic> current =
    const NoteMigrator().migrateJson(decoded, downloadedAt);
```

Three rules make this safe to run over data you cannot regenerate:

- **A step writes the new version itself.** Nothing else stamps it, and a step
  that forgets produces JSON that is migrated again on the next read.
- **A shipped step is frozen.** It works on maps alone, never on today's DTO or
  domain types: its job is to produce the shape the next version had *when it
  shipped*, and today's types have moved on since.
- **A newer version is never read and never overwritten.** `migrateJson` throws
  `SchemaVersionTooNewException`; the build that wrote it needs it back intact.
  A version field that is present but not an integer of at least 1 throws
  `SchemaVersionInvalidException` instead of being guessed at. Both are
  `FormatException`s and carry only version numbers, never the JSON, so they
  are safe to log.

`currentVersion` may stay at 1 for a format that carried a version from its
first write. A format that existed on disk unversioned starts at 2, because its
old files read as version 1.

## Schemas

A `VersionedJsonSchema<T>` pairs a DTO type with its format's migrator, so a
read is "migrate, then parse" and the two cannot be mismatched:

```dart
class NoteSchema extends VersionedJsonSchema<NoteDto> {
  const NoteSchema();

  @override
  VersionedJsonMigrator get migrator => const NoteMigrator();

  @override
  NoteDto fromJson(Map<String, dynamic> json) => NoteDto.fromJson(json);
}

final NoteDto note = const NoteSchema().readJson(decoded, downloadedAt);
```

The DTO implements `VersionedJsonDto`. `writeFile` stamps its `schemaVersion`
into the file; JSON stored any other way must carry that key in `toJson`.

## Files

```dart
import 'package:versioned_json/versioned_json_io.dart';

final NoteDto? note = await const NoteSchema().readFile(file);
await const NoteSchema().writeFile(file, note!);
final int rewritten = await const NoteMigrator().migrateDirectory(notesDir);
```

`migrateFile` and `readFile` write a migrated file back once, and return null
when there is no file or no JSON object in it. A version they cannot migrate
throws and the file is left untouched; so does a `FileSystemException` (no
permission to read, a failed write-back), rather than reading as "no data" that
a caller would then overwrite. `migrateDirectory` skips either kind of file and
carries on, so one file a newer build wrote, or one the process cannot read,
does not hold every other file at its old version.

Every write goes to a sibling file in the same directory and is renamed over
the target, so a crash leaves the old content or the new, never a truncated
file. `writeFile` stamps the DTO's `schemaVersion` into the JSON itself, and
throws an `ArgumentError` without writing when that version is not the
schema's current one.

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

`nonValueFields` names fields the values JSON does not carry — a set merged
somewhere else, say; `take` and `changed` pass over them.

`changed` compares JSON, deeply, not Dart objects. That is the point — the same
instant as local time and as UTC is `!=` in Dart but one value in JSON — and it
is also the precondition: **`toJson` must be canonical**, writing equivalent
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
expect(
  const NoteMigrator().stepExampleMismatches(<int, VersionedJsonStepExample>{
    1: VersionedJsonStepExample(before: v1, after: v2, modifiedAt: at),
  }),
  isEmpty,
);
```

`keyMismatches` fails when a new enum member has no key in `toJson`, and
`stepExampleMismatches` fails when `currentVersion` rises without an example for
the new step.

## Status

`0.1.0`, distributed as a git dependency rather than on pub.dev:

```yaml
versioned_json:
  git:
    url: https://github.com/kai-tw/kai-packages.git
    path: packages/versioned_json
    ref: versioned_json-v0.1.0
```

The version key, `schemaVersion`, is persisted by every consumer and does not
change without a major version.
