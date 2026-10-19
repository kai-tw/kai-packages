/// A persisted JSON document, read into today's DTO whichever version wrote
/// it, and written back at today's version.
///
/// One library on purpose. Reading a document's version, deciding whether
/// this build may act on it, and walking it through the migration steps all
/// happen inside the schema, and the document in between is private to this
/// library. A caller outside it reads a DTO or a refusal: it never holds the
/// map, never reads the version, and never drives a migration step.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import 'io/json_file_atomic_writer.dart';
import 'versioned_json_dto.dart';

part 'versioned_json_file_schema.dart';
part 'versioned_json_migration_exception.dart';
part 'versioned_json_migration_outcome.dart';
part 'versioned_json_read_exceptions.dart';

/// The schema of one persisted JSON file: its current version, the steps
/// that bring an older document up to it, and the DTO today's shape parses
/// into. One schema constant per file, and every read and write of that file
/// goes through it.
///
/// A reader holds bytes and gets a DTO, or a [VersionedJsonReadException]
/// that already says why not. The version check, the migration and the map
/// in between stay inside this library; a subclass sees the map only in the
/// hooks it implements ([migrateOneStep], [wrapUnversioned], [fromJson],
/// [holdsUnknownCode]) and in the readers it hands to [readMigrated].
///
/// The DTO does not carry the version either: [encode] stamps
/// [currentVersion] on the way out, and the version a stored document
/// declares is read and acted on here alone.
///
/// A file kept on disk, which a read may migrate in place, takes
/// [VersionedJsonFileSchema], which adds the lenient file reads and writes.
abstract class VersionedJsonSchema<TDto extends VersionedJsonDto> {
  const VersionedJsonSchema();

  /// The key a document declares its version under. A document without it,
  /// or with `null` under it, is version 1 — the shape the file had before
  /// it was versioned.
  ///
  /// Fixed rather than configurable: renaming it is a data migration, because
  /// every file already written would read as version 1.
  static const String _versionKey = 'schemaVersion';

  /// The version today's DTO is shaped for. A document below it is brought
  /// up through [migrateOneStep], one version at a time; a document above it
  /// was written by a newer build and is neither read nor written over.
  ///
  /// Adding a version raises this by one and adds the step that reaches it.
  @protected
  int get currentVersion;

  /// [source], a document at [sourceVersion], as a document at
  /// `sourceVersion + 1`. Called by the library for each version from the
  /// stored one up to [currentVersion]; the default holds no step, which is
  /// right for a file still at its first version.
  ///
  /// A step is frozen the day it ships: a document from two years ago must
  /// still come out in the shape that version had, whatever today's DTO has
  /// become since. So a step reads and writes the map alone and never
  /// touches the DTO; a schema with steps keeps them in a private class in a
  /// part file of its own, apart from the DTO-facing code. A subclass
  /// dispatches on [sourceVersion] and answers every version it holds no
  /// step for with [throwNoStepFrom].
  ///
  /// [modifiedAt] is when the stored document was last written — for a
  /// step that has to synthesise a timestamp the old shape did not carry.
  @protected
  Map<String, dynamic> migrateOneStep(
    Map<String, dynamic> source,
    int sourceVersion,
    DateTime modifiedAt,
  ) => throwNoStepFrom(sourceVersion);

  /// What [migrateOneStep] answers for a [sourceVersion] it holds no step
  /// from.
  @protected
  Never throwNoStepFrom(int sourceVersion) =>
      throw VersionedJsonMigrationException(
        sourceVersion: sourceVersion,
        currentVersion: currentVersion,
      );

  /// [document], a JSON value of this file that is no object, as the
  /// version-1 object it stands for — or `null`, the default, when this file
  /// never shipped such a shape and the document is malformed.
  ///
  /// For a file whose first shipped shape had no envelope (a bare list,
  /// say): the document then enters the steps at version 1 like any other.
  @protected
  Map<String, dynamic>? wrapUnversioned(Object? document) => null;

  /// Parses a current-shape JSON map into the DTO. Concrete
  /// implementations delegate to the DTO's generated `fromJson` factory.
  @protected
  TDto fromJson(Map<String, dynamic> json);

  /// Whether [json], a document already at today's shape, holds an enum
  /// code no member of this build's enum owns — the half of "may this build
  /// act on it" its version cannot answer. A file with no coded field keeps
  /// the default, `false`.
  ///
  /// Such a document is refused rather than read with a default member in
  /// the code's place: this build would write that member back over the
  /// newer value, with nobody told.
  @protected
  bool holdsUnknownCode(Map<String, dynamic> json) => false;

  /// [dto] as the text of a document at [currentVersion].
  String encode(TDto dto) => jsonEncode(<String, dynamic>{
    ...dto.toJson(),
    _versionKey: currentVersion,
  });

  /// [bytes], a stored document of this file, as today's DTO.
  ///
  /// Throws the [VersionedJsonReadException] whose variant says why this
  /// build may not act on it: a version above [currentVersion], an enum code
  /// this build does not know, or a document that does not decode — not
  /// UTF-8, not JSON, no object, a version that is no integer or is below 1,
  /// or a field [fromJson] cannot parse. That last one is a
  /// [CheckedFromJsonException], as a `checked: true` generated codec
  /// throws; the refusal keeps its stack trace and drops the exception,
  /// whose text can quote the document.
  @protected
  TDto decodeBytes(Uint8List bytes, DateTime modifiedAt) =>
      _decodeOrThrow(_migrateBytes(bytes, modifiedAt));

  /// [bytes], a stored document of another file — the one [container]
  /// reads — read as a document of this file: brought to [container]'s
  /// current version, then cut down to this file's document by [sectionOf],
  /// a frozen step pinned to that version, then decoded as [decodeBytes]
  /// decodes.
  ///
  /// For a document whose content moved into this file. Every refusal
  /// reports the stored document's version, since that is the file on disk.
  @protected
  TDto decodeBytesWithin(
    Uint8List bytes,
    DateTime modifiedAt, {
    required VersionedJsonSchema<VersionedJsonDto> container,
    required Map<String, dynamic> Function(Map<String, dynamic> stored)
    sectionOf,
  }) {
    final _VersionedJsonMigrationOutcome stored = container._migrateBytes(
      bytes,
      modifiedAt,
    );
    return switch (stored) {
      _VersionedJsonMigrationCurrentOutcome(
        :final Map<String, dynamic> json,
        :final int storedVersion,
      ) =>
        _decodeOrThrow(
          _migrateDocument(sectionOf(json), modifiedAt),
          reportedVersion: storedVersion,
        ),
      _VersionedJsonMigrationNewerOutcome() ||
      _VersionedJsonMigrationInvalidOutcome() ||
      _VersionedJsonMigrationMalformedOutcome() => _decodeOrThrow(stored),
    };
  }

  /// The value [read] takes out of [bytes], a stored document of this file
  /// brought to today's shape — `null` when it is not a document this build
  /// may act on (no JSON object, or a version this build does not reach).
  ///
  /// For salvaging one value out of a document that may not decode as a
  /// whole; [read] gets the migrated map and must take only what it can
  /// read tolerantly. [TValue] is that value's type, bound to [Object] so
  /// that `null` is added in one place only, by the return type.
  @protected
  TValue? readMigrated<TValue extends Object>(
    Uint8List bytes,
    DateTime modifiedAt,
    TValue? Function(Map<String, dynamic> json) read,
  ) => switch (_migrateBytes(bytes, modifiedAt)) {
    _VersionedJsonMigrationCurrentOutcome(:final Map<String, dynamic> json) =>
      read(json),
    _VersionedJsonMigrationNewerOutcome() ||
    _VersionedJsonMigrationInvalidOutcome() ||
    _VersionedJsonMigrationMalformedOutcome() => null,
  };

  /// [bytes], the stored text of a document, migrated.
  _VersionedJsonMigrationOutcome _migrateBytes(
    Uint8List bytes,
    DateTime modifiedAt,
  ) {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return const _VersionedJsonMigrationMalformedOutcome();
    }
    return _migrateText(text, modifiedAt);
  }

  /// [text], the stored text of a document, migrated.
  _VersionedJsonMigrationOutcome _migrateText(
    String text,
    DateTime modifiedAt,
  ) {
    final Object? document;
    try {
      document = jsonDecode(text);
    } on FormatException {
      return const _VersionedJsonMigrationMalformedOutcome();
    }
    return _migrateDocument(document, modifiedAt);
  }

  /// [document] brought from its own version up to [currentVersion], or the
  /// reason it was left alone.
  ///
  /// A version above [currentVersion] is newer data this reader cannot
  /// parse and must preserve. A version below 1 is below the floor a
  /// missing field defines — no shipped schema has ever produced it, so it
  /// is not a recognisable version at all, and looping [migrateOneStep]
  /// over it would dispatch to a step no schema holds. A version that is
  /// present but no integer is malformed for the same reason: reading it as
  /// version 1 would run every step over a document of unknown shape.
  _VersionedJsonMigrationOutcome _migrateDocument(
    Object? document,
    DateTime modifiedAt,
  ) {
    final Map<String, dynamic>? json = switch (document) {
      final Map<String, dynamic> object => object,
      _ => wrapUnversioned(document),
    };
    if (json == null) {
      return const _VersionedJsonMigrationMalformedOutcome();
    }
    final int storedVersion;
    switch (json[_versionKey]) {
      case null:
        storedVersion = 1;
      case final int version:
        storedVersion = version;
      default:
        return const _VersionedJsonMigrationMalformedOutcome();
    }
    if (storedVersion > currentVersion) {
      return _VersionedJsonMigrationNewerOutcome(storedVersion: storedVersion);
    }
    if (storedVersion < 1) {
      return _VersionedJsonMigrationInvalidOutcome(
        storedVersion: storedVersion,
      );
    }
    Map<String, dynamic> current = json;
    for (int version = storedVersion; version < currentVersion; version++) {
      current = migrateOneStep(current, version, modifiedAt);
    }
    return _VersionedJsonMigrationCurrentOutcome(
      current,
      storedVersion: storedVersion,
    );
  }

  /// The DTO [outcome] holds, or the refusal for it. [reportedVersion], when
  /// given, is the version every refusal reports in place of the outcome's
  /// own.
  TDto _decodeOrThrow(
    _VersionedJsonMigrationOutcome outcome, {
    int? reportedVersion,
  }) {
    switch (outcome) {
      case _VersionedJsonMigrationCurrentOutcome(
        :final Map<String, dynamic> json,
        :final int storedVersion,
      ):
        final int version = reportedVersion ?? storedVersion;
        if (holdsUnknownCode(json)) {
          throw VersionedJsonReadUnknownCodeException(storedVersion: version);
        }
        try {
          return fromJson(json);
        } on CheckedFromJsonException catch (_, s) {
          Error.throwWithStackTrace(
            VersionedJsonReadCorruptException(storedVersion: version),
            s,
          );
        }
      case _VersionedJsonMigrationNewerOutcome(:final int storedVersion):
        throw VersionedJsonReadNewerException(
          storedVersion: reportedVersion ?? storedVersion,
        );
      case _VersionedJsonMigrationInvalidOutcome(:final int storedVersion):
        throw VersionedJsonReadCorruptException(
          storedVersion: reportedVersion ?? storedVersion,
        );
      case _VersionedJsonMigrationMalformedOutcome():
        throw VersionedJsonReadCorruptException(storedVersion: reportedVersion);
    }
  }

  /// The DTO [outcome] holds, or `null` when it is a document this build may
  /// not act on — the lenient reading of [VersionedJsonFileSchema].
  TDto? _readOrNull(_VersionedJsonMigrationOutcome outcome) =>
      switch (outcome) {
        _VersionedJsonMigrationCurrentOutcome(
          :final Map<String, dynamic> json,
        ) =>
          _parseUnlessUnknownCode(json),
        _VersionedJsonMigrationNewerOutcome() ||
        _VersionedJsonMigrationInvalidOutcome() ||
        _VersionedJsonMigrationMalformedOutcome() => null,
      };

  /// [json] parsed, or `null` when it holds a code this build does not know.
  TDto? _parseUnlessUnknownCode(Map<String, dynamic> json) =>
      holdsUnknownCode(json) ? null : fromJson(json);
}
