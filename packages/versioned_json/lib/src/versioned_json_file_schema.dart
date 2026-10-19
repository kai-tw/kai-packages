part of 'versioned_json_schema.dart';

/// The schema of a JSON file kept on disk, where a document this build may
/// not act on reads as nothing.
///
/// Its reads are lenient: a document that is missing, does not decode, or
/// was written by a newer build answers `null`, and the newer build's file
/// stays on disk untouched, so the caller falls back to an empty
/// placeholder rather than overwriting it. A read migrates in place: an
/// older file is rewritten once, at the current version.
///
/// Throws any exception [fromJson] raises: that is a contract violation
/// between the last step's output and the DTO, and must surface rather than
/// be dropped as missing data.
///
/// ```dart
/// class NoteStore {
///   static const VersionedJsonFileSchema<NoteDto> _schema = NoteSchema();
///
///   Future<Note> load(File file) async {
///     final NoteDto? dto = await _schema.readFile(file);
///     return dto == null ? Note.empty() : dto.toNote();
///   }
/// }
/// ```
abstract class VersionedJsonFileSchema<TDto extends VersionedJsonDto>
    extends VersionedJsonSchema<TDto> {
  const VersionedJsonFileSchema();

  /// Read + migrate + parse, in one call. Returns null when the file is
  /// missing, unreadable, empty, not UTF-8, malformed, at a version below 1,
  /// above [currentVersion] (a newer build wrote it), or holding a code this
  /// build does not know.
  Future<TDto?> readFile(File file) async {
    final Map<String, dynamic>? json = await _migrateFile(file);
    if (json == null) {
      return null;
    }
    return _parseUnlessUnknownCode(json);
  }

  /// [text], a document of this file held somewhere other than its file (a
  /// download, say), migrated and parsed. Returns null on the same
  /// conditions as [readFile], less the absence ones. [modifiedAt] seeds
  /// migration timestamp synthesis — the download time for a downloaded
  /// copy.
  TDto? readString(String text, DateTime modifiedAt) =>
      _readOrNull(_migrateText(text, modifiedAt));

  /// Serialises [dto] and writes it to [file], replacing any existing
  /// content. The counterpart of [readFile], so both sides of the round trip
  /// go through the schema.
  ///
  /// Written atomically, so a [readFile] at any moment finds the old
  /// document or the new one, never part of one. The write stages its bytes
  /// in `<file>.tmp` next to [file], so the caller must not run two writes
  /// to one file at the same time.
  Future<void> writeFile(File file, TDto dto) =>
      const JsonFileAtomicWriter().write(file, utf8.encode(encode(dto)));

  /// Brings [file] to [currentVersion] in place: written once, after every
  /// step, and only when a step ran. A file that is missing, does not
  /// decode, or declares a version this build may not act on is left as it
  /// is — a newer build's file in particular, which is its data to keep.
  ///
  /// For a sweep at startup; a reader calls [readFile] instead, which
  /// migrates the same way on its way to the DTO.
  Future<void> migrateFile(File file) async {
    await _migrateFile(file);
  }

  /// Every `.json` file in [dir] migrated as [migrateFile] migrates one.
  /// Idempotent, so a sweep over files already current rewrites nothing.
  Future<void> migrateDirectory(Directory dir) async {
    if (!dir.existsSync()) {
      return;
    }
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is File && entity.path.endsWith('.json')) {
        await _migrateFile(entity);
      }
    }
  }

  /// The document in [file], migrated in place as [migrateFile] describes;
  /// `null` when it is missing, does not decode, or is one this build may not
  /// act on.
  Future<Map<String, dynamic>?> _migrateFile(File file) async {
    if (!file.existsSync()) {
      return null;
    }
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      // Unreadable, or not UTF-8: either way no document to migrate.
      return null;
    }
    switch (_migrateText(text, file.lastModifiedSync())) {
      case _VersionedJsonMigrationCurrentOutcome(
        :final Map<String, dynamic> json,
        :final int storedVersion,
      ):
        if (storedVersion != currentVersion) {
          await const JsonFileAtomicWriter().write(
            file,
            utf8.encode(
              jsonEncode(<String, dynamic>{
                ...json,
                VersionedJsonSchema._versionKey: currentVersion,
              }),
            ),
          );
        }
        return json;
      case _VersionedJsonMigrationNewerOutcome():
      case _VersionedJsonMigrationInvalidOutcome():
      case _VersionedJsonMigrationMalformedOutcome():
        return null;
    }
  }
}
