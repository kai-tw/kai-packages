import 'dart:convert';
import 'dart:io';

import '../schema_version_invalid_exception.dart';
import '../schema_version_too_new_exception.dart';
import '../versioned_json_migrator.dart';
import 'json_file_atomic_writer.dart';

/// Migrates JSON files in place.
extension VersionedJsonMigratorIo on VersionedJsonMigrator {
  /// Reads [file], migrates it to
  /// [VersionedJsonMigrator.currentVersion], writes the result back once if any
  /// step ran, and returns it. The write-back replaces the file atomically, so
  /// a crash leaves either the old version or the new, never a truncated file.
  ///
  /// Returns null when the file does not exist, or its content is not a JSON
  /// object (empty, malformed, not UTF-8, or another JSON type); such a file is
  /// left as it is.
  ///
  /// Throws [SchemaVersionTooNewException] or [SchemaVersionInvalidException]
  /// — never a null — when the version cannot be migrated, and leaves the file
  /// untouched: a newer build wrote it and needs it back intact, so a caller
  /// must not replace it with a default either. A [FileSystemException] (no
  /// permission to read, a failed write-back) propagates too, rather than
  /// reading as "no data" that a caller would then overwrite.
  Future<Map<String, dynamic>?> migrateFile(File file) async {
    final _VersionedJsonFileMigration? migration = await _migrateFile(file);
    return migration?.json;
  }

  /// Runs [migrateFile] over every `.json` file directly inside [dir], and
  /// returns how many were rewritten. Running it again rewrites nothing.
  ///
  /// A file whose version cannot be migrated, or that raises a
  /// [FileSystemException], is skipped and left as it is, and the sweep goes
  /// on: one file a newer build wrote, or one the process may not read, must
  /// not keep every other file at its old version. Reading that file through
  /// [migrateFile] later still reports it. A missing [dir] holds nothing to
  /// migrate; a failure to list [dir] itself propagates.
  Future<int> migrateDirectory(Directory dir) async {
    if (!await dir.exists()) {
      return 0;
    }
    int rewritten = 0;
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is File &&
          entity.path.endsWith('.json') &&
          await _migrateSweptFile(entity)) {
        rewritten++;
      }
    }
    return rewritten;
  }

  Future<bool> _migrateSweptFile(File file) async {
    try {
      final _VersionedJsonFileMigration? migration = await _migrateFile(file);
      return migration?.rewritten ?? false;
    } on SchemaVersionTooNewException {
      // Not written: the file keeps the newer build's data.
      return false;
    } on SchemaVersionInvalidException {
      // Not written: the file keeps whatever it holds for a reader to report.
      return false;
    } on FileSystemException {
      // Unreadable, or the write-back failed; either way the atomic write left
      // the file's previous content in place for a reader to report.
      return false;
    }
  }

  Future<_VersionedJsonFileMigration?> _migrateFile(File file) async {
    final Map<String, dynamic>? json = await _readJsonObject(file);
    if (json == null) {
      return null;
    }
    final bool rewritten =
        VersionedJsonMigrator.readVersion(json) != currentVersion;
    final Map<String, dynamic> migrated = migrateJson(
      json,
      await file.lastModified(),
    );
    if (rewritten) {
      await const JsonFileAtomicWriter().write(file, migrated);
    }
    return _VersionedJsonFileMigration(json: migrated, rewritten: rewritten);
  }

  static Future<Map<String, dynamic>?> _readJsonObject(File file) async {
    if (!await file.exists()) {
      return null;
    }
    final List<int> bytes = await file.readAsBytes();
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      // Unreadable content is reported as no content; the caller writes
      // nothing, so the bytes stay on disk as they were.
      return null;
    }
    return decoded is Map<String, dynamic> ? decoded : null;
  }
}

class _VersionedJsonFileMigration {
  const _VersionedJsonFileMigration({
    required this.json,
    required this.rewritten,
  });

  final Map<String, dynamic> json;
  final bool rewritten;
}
