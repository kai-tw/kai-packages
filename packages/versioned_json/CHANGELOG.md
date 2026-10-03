# Changelog

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
