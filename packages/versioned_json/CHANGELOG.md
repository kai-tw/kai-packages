# Changelog

## 0.2.0

A new API, designed around a schema that owns its format's whole history.
Nothing from 0.1.0 is kept except `FieldwiseJson` and its checks in
`testing.dart`.

### Breaking changes

- **No web support.** `package:versioned_json/versioned_json.dart` now imports
  `dart:io`.
- **`VersionedJsonMigrator` is gone**, and with it `migrateJson`,
  `readVersion` and `VersionedJsonMigrator.versionKey`. A
  `VersionedJsonSchema` now declares `currentVersion` and `migrateOneStep`
  itself, both `@protected`, and answers a version it holds no step from with
  `throwNoStepFrom`.
- **`VersionedJsonSchema.readJson` is gone.** Callers no longer handle the
  migrated map. Read a file through `VersionedJsonFileSchema` (`readFile`,
  `readString`), or bytes through the protected strict reads (`decodeBytes`,
  `decodeBytesWithin`, `readMigrated`).
- **`VersionedJsonDto` no longer has `schemaVersion`.** The DTO is today's
  shape only; the schema stamps the version in `encode` and `writeFile`.
  `writeFile` therefore no longer throws an `ArgumentError` for a DTO at
  another version.
- **`package:versioned_json/versioned_json_io.dart` is gone.**
  `VersionedJsonFileSchema` replaces its `migrateFile`, `migrateDirectory`,
  `readFile` and `writeFile`, with different failure handling:
  - `readFile` reads an unreadable file as `null` rather than throwing a
    `FileSystemException`, and a newer or invalid version as `null` rather
    than throwing.
  - `migrateFile` and `migrateDirectory` return nothing. `migrateDirectory`
    used to return the number of files rewritten.
  - A failed write-back still propagates its `FileSystemException`.
- **New read exceptions.** `SchemaVersionTooNewException` and
  `SchemaVersionInvalidException` are replaced by the sealed
  `VersionedJsonReadException`: `VersionedJsonReadNewerException`,
  `VersionedJsonReadUnknownCodeException` and
  `VersionedJsonReadCorruptException`, each carrying `storedVersion`. All are
  still `FormatException`s.
- **`schemaVersion: null` reads as version 1**, the same as a missing key. It
  used to throw `SchemaVersionInvalidException`.
- **`VersionedJsonStepExample` and `stepExampleMismatches` are gone** from
  `testing.dart`, along with the migrator they checked.
- **Writes stage in a fixed `<target>.tmp`**, not a uniquely named sibling.
  Concurrent writes to one file are no longer safe: the caller must serialize
  them.

### Added

- **`VersionedJsonFileSchema.readString`** — the lenient read for a document
  held somewhere other than its file, such as a download.
- **`holdsUnknownCode`** — a document holding an enum code this build doesn't
  know is refused rather than read with a default member in its place.
- **`wrapUnversioned`** — a format whose first shape was no JSON object (a
  bare list, say) enters the steps at version 1.
- **`VersionedJsonMigrationException`** for a schema asked for a step it
  doesn't hold. It implements `Exception` but isn't a `FormatException`, so an
  `on FormatException` doesn't catch it.
- A migrating read's write-back stamps the current version even when the last
  step doesn't.
- Dependencies on `json_annotation` (a strict read reports a
  `CheckedFromJsonException` from `fromJson` as a corrupt document) and `meta`.

## 0.1.0

First release.

- **`VersionedJsonMigrator`** — reads the version under `schemaVersion` (a
  missing key is version 1) and runs one `migrateOneStep` per transition up to
  `currentVersion`. A version above `currentVersion` throws
  `SchemaVersionTooNewException`; a version that is not an integer of at least
  1 (`0`, `2.0`, `"2"`, `null`) throws `SchemaVersionInvalidException` rather
  than being read as 1. Both extend `FormatException` and carry version numbers
  only, never the JSON.
- **`VersionedJsonDto` and `VersionedJsonSchema<T>`** — pair today's DTO with
  its format's migrator; `readJson` migrates, then parses.
- **`FieldwiseJson<V, F>`** — `take` copies chosen fields from one record into
  another and `changed` lists the fields whose JSON differs, both through the
  record's JSON, keyed by the field enum's names. Fields kept outside the
  values JSON are declared once and passed over by both.
- **`package:versioned_json/versioned_json_io.dart`** — `migrateFile`,
  `migrateDirectory`, `readFile` and `writeFile`. The only library that imports
  `dart:io`. A file whose version cannot be migrated is never written.
  `migrateFile` and `readFile` let that exception and any
  `FileSystemException` propagate; `migrateDirectory` skips such a file and
  carries on. Every write goes to its own staging sibling and is renamed over
  the target, so concurrent writes to one file cannot collide and the last
  rename wins. `writeFile` stamps the DTO's `schemaVersion` itself and throws an
  `ArgumentError` when it is not the current version.
- **`package:versioned_json/testing.dart`** — checks for a consumer's own tests
  that return mismatches instead of asserting: `FieldwiseJson` key naming,
  round-trips and canonical serialisation, and a worked example for every
  migration step.
