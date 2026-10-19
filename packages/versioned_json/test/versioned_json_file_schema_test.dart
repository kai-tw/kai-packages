import 'dart:convert';
import 'dart:io';

import 'package:json_annotation/json_annotation.dart';
import 'package:test/test.dart';
import 'package:versioned_json/versioned_json.dart';

import 'support/note_dto.dart';
import 'support/note_schema.dart';

/// Real files in a temp directory: the file system is the only collaborator.
///
/// A sweep hands nothing back, so every sweep case reads the file it left on
/// disk; a file left alone keeps both its bytes and its backdated timestamp.
void main() {
  const NoteSchema schema = NoteSchema();
  final DateTime stale = DateTime(2020, 1, 1, 12);
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('versioned_json_file_test_');
  });

  tearDown(() {
    // Undo any mode a permission test set, so the directory can be removed.
    if (!Platform.isWindows) {
      _chmod(<String>['-R', 'u+rwx', tempDir.path]);
    }
    tempDir.deleteSync(recursive: true);
  });

  File fileNamed(String name) =>
      File('${tempDir.path}${Platform.pathSeparator}$name');

  /// The names in [tempDir], so a test can see that no staging file is left.
  List<String> entryNames() => <String>[
    for (final FileSystemEntity entity in tempDir.listSync())
      entity.uri.pathSegments.lastWhere((String s) => s.isNotEmpty),
  ]..sort();

  /// Backdates the file, so a later write is visible as a newer timestamp
  /// even when it rewrites identical bytes.
  File writeRaw(String name, String content) {
    final File file = fileNamed(name)..writeAsStringSync(content);
    file.setLastModifiedSync(stale);
    return file;
  }

  File writeJson(String name, Map<String, dynamic> json) =>
      writeRaw(name, jsonEncode(json));

  Map<String, dynamic> onDisk(File file) =>
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  void expectUntouched(File file, String content) {
    expect(file.readAsStringSync(), content);
    expect(file.lastModifiedSync(), stale);
  }

  group('migrateFile across the version axis', () {
    test('version 1 runs every step and is written once at the current '
        'version', () async {
      final File file = writeJson('v1.json', <String, dynamic>{
        'schemaVersion': 1,
        'payload': 'hello',
      });

      await schema.migrateFile(file);

      expect(onDisk(file), <String, dynamic>{
        'schemaVersion': 3,
        'payload': 'hello',
        'steps': <dynamic>['1to2', '2to3'],
        'migratedAt': stale.toUtc().toIso8601String(),
      });
      expect(entryNames(), <String>['v1.json']);
    });

    test('version 2 runs only the last step', () async {
      final File file = writeJson('v2.json', <String, dynamic>{
        'schemaVersion': 2,
        'payload': 'mid',
      });

      await schema.migrateFile(file);

      expect(onDisk(file), <String, dynamic>{
        'schemaVersion': 3,
        'payload': 'mid',
        'steps': <dynamic>['2to3'],
      });
    });

    test('a file without a version reads as version 1', () async {
      final File file = writeJson('legacy.json', <String, dynamic>{
        'payload': 'legacy',
      });

      await schema.migrateFile(file);

      expect(onDisk(file)['steps'], <dynamic>['1to2', '2to3']);
      expect(onDisk(file)['schemaVersion'], 3);
    });

    test('the current version is not rewritten', () async {
      final String content = jsonEncode(<String, dynamic>{
        'schemaVersion': 3,
        'payload': 'current',
      });
      final File file = writeRaw('v3.json', content);

      await schema.migrateFile(file);

      expectUntouched(file, content);
    });

    test('a newer version is left untouched, fields this build does not know '
        'included', () async {
      final String content = jsonEncode(<String, dynamic>{
        'schemaVersion': 4,
        'payload': 'future',
        'futureOnlyField': <String, int>{'a': 1},
      });
      final File file = writeRaw('v4.json', content);

      await schema.migrateFile(file);

      expectUntouched(file, content);
    });

    test('version 0 is left untouched, and no step is asked for it', () async {
      final String content = jsonEncode(<String, dynamic>{
        'schemaVersion': 0,
        'payload': 'below-floor',
      });
      final File file = writeRaw('v0.json', content);

      // NoteSchema throws for a step it holds none of, so completing proves
      // the floor stopped the loop before migrateOneStep.
      await schema.migrateFile(file);

      expectUntouched(file, content);
    });

    test('the rewrite declares the current version even when the last step '
        'does not stamp it', () async {
      final File file = writeJson('unstamped.json', <String, dynamic>{
        'schemaVersion': 1,
        'payload': 'p',
      });

      await const _UnstampedNoteSchema().migrateFile(file);

      // A file left declaring version 1 would be migrated again on every
      // sweep, its step re-run over a document already past it.
      expect(onDisk(file), <String, dynamic>{
        'schemaVersion': 2,
        'payload': 'p',
        'stepped': true,
      });
    });

    test('a missing step throws and leaves the file as it was', () async {
      final String content = jsonEncode(<String, dynamic>{'payload': 'stuck'});
      final File file = writeRaw('stuck.json', content);

      await expectLater(
        const _SteplessNoteSchema().migrateFile(file),
        throwsA(isA<VersionedJsonMigrationException>()),
      );
      expectUntouched(file, content);
    });
  });

  group('migrateFile on content that is no document', () {
    test('a missing file is not created', () async {
      final File missing = fileNamed('absent.json');

      await schema.migrateFile(missing);

      expect(missing.existsSync(), isFalse);
    });

    for (final MapEntry<String, String> entry in <String, String>{
      'an empty file': '',
      'malformed JSON': '{not json',
      'JSON that is no object': '[1, 2, 3]',
      'a version that is no integer': '{"schemaVersion": "1"}',
    }.entries) {
      test('${entry.key} is left untouched', () async {
        final File file = writeRaw('bad.json', entry.value);

        await schema.migrateFile(file);

        expectUntouched(file, entry.value);
      });
    }

    test('bytes that are not UTF-8 are left untouched', () async {
      final File file = fileNamed('latin1.json');
      final List<int> bytes = <int>[0x7b, 0xff, 0xfe, 0x7d];
      file
        ..writeAsBytesSync(bytes)
        ..setLastModifiedSync(stale);

      await schema.migrateFile(file);

      expect(file.readAsBytesSync(), bytes);
      expect(file.lastModifiedSync(), stale);
    });
  });

  group('migrateDirectory', () {
    test('rewrites only the older files and leaves every other one '
        'untouched', () async {
      final File older = writeJson('a.json', <String, dynamic>{
        'schemaVersion': 1,
        'payload': 'a',
      });
      final Map<File, String> untouched = <File, String>{
        for (final MapEntry<String, String> entry in <String, String>{
          'b.json': jsonEncode(<String, dynamic>{'schemaVersion': 3}),
          'c.json': jsonEncode(<String, dynamic>{'schemaVersion': 4}),
          'd.json': '{not json',
          // A version-1 document a sweep that did not filter by extension
          // would rewrite.
          'e.txt': jsonEncode(<String, dynamic>{'schemaVersion': 1}),
          // A staging file, next to a target the sweep does not rewrite.
          'b.json.tmp': jsonEncode(<String, dynamic>{'schemaVersion': 1}),
        }.entries)
          writeRaw(entry.key, entry.value): entry.value,
      };
      Directory(fileNamed('nested.json').path).createSync();

      await schema.migrateDirectory(tempDir);

      expect(onDisk(older)['schemaVersion'], 3);
      for (final MapEntry<File, String> entry in untouched.entries) {
        expectUntouched(entry.key, entry.value);
      }
    });

    test('a second sweep rewrites nothing', () async {
      final File file = writeJson('a.json', <String, dynamic>{
        'schemaVersion': 1,
      });
      await schema.migrateDirectory(tempDir);
      final String afterFirst = file.readAsStringSync();
      file.setLastModifiedSync(stale);

      await schema.migrateDirectory(tempDir);

      expectUntouched(file, afterFirst);
    });

    test('a missing directory is not created', () async {
      final Directory missing = Directory(fileNamed('never-made').path);

      await schema.migrateDirectory(missing);

      expect(missing.existsSync(), isFalse);
    });

    test('an empty directory stays empty', () async {
      await schema.migrateDirectory(tempDir);

      expect(entryNames(), isEmpty);
    });
  });

  group('readFile', () {
    test('migrates an older file in place on its way to the DTO', () async {
      final File file = writeJson('old.json', <String, dynamic>{
        'schemaVersion': 1,
        'payload': 'old',
      });

      final NoteDto? dto = await schema.readFile(file);

      expect(dto?.payload, 'old');
      expect(dto?.steps, <String>['1to2', '2to3']);
      expect(onDisk(file)['schemaVersion'], 3);
    });

    test('reads a missing file as null', () async {
      expect(await schema.readFile(fileNamed('absent.json')), isNull);
    });

    test('reads a document this build may not act on as null, and leaves it '
        'untouched', () async {
      final Map<String, String> contents = <String, String>{
        'newer.json': jsonEncode(<String, dynamic>{'schemaVersion': 4}),
        'malformed.json': '{not json',
        'unknown.json': jsonEncode(<String, dynamic>{
          'schemaVersion': 1,
          'payload': 'p',
          'colour': 'ultraviolet',
        }),
      };
      for (final MapEntry<String, String> entry in contents.entries) {
        final File file = writeRaw(entry.key, entry.value);

        expect(await schema.readFile(file), isNull, reason: entry.key);
      }
      expectUntouched(fileNamed('newer.json'), contents['newer.json']!);
      expectUntouched(fileNamed('malformed.json'), contents['malformed.json']!);
    });

    test('migrates an older document holding an unknown code in place, '
        'keeping the code, before reading it as null', () async {
      final File file = writeJson('older.json', <String, dynamic>{
        'schemaVersion': 1,
        'payload': 'p',
        'colour': 'ultraviolet',
      });

      expect(await schema.readFile(file), isNull);

      expect(onDisk(file), <String, dynamic>{
        'schemaVersion': 3,
        'payload': 'p',
        'colour': 'ultraviolet',
        'steps': <dynamic>['1to2', '2to3'],
        'migratedAt': stale.toUtc().toIso8601String(),
      });
    });

    test('lets a field fromJson cannot parse propagate', () async {
      final File file = writeJson('bad.json', <String, dynamic>{
        'schemaVersion': 3,
        'payload': 7,
      });

      await expectLater(
        schema.readFile(file),
        throwsA(isA<CheckedFromJsonException>()),
      );
    });
  });

  group('writeFile', () {
    test(
      'replaces the content with the encoded DTO, which reads back',
      () async {
        final File file = writeRaw('note.json', 'old content');
        const NoteDto written = NoteDto(
          payload: 'written',
          colour: NoteColour.yellow,
        );

        await schema.writeFile(file, written);

        expect(file.readAsStringSync(), schema.encode(written));
        final NoteDto? readBack = await schema.readFile(file);
        expect(readBack?.payload, 'written');
        expect(readBack?.colour, NoteColour.yellow);
        expect(entryNames(), <String>['note.json']);
      },
    );

    test('creates a file that did not exist', () async {
      final File file = fileNamed('new.json');

      await schema.writeFile(file, const NoteDto(payload: 'p'));

      expect(onDisk(file)['schemaVersion'], 3);
      expect(entryNames(), <String>['new.json']);
    });

    test('stages in <target>.tmp: a staging file a crash left behind is '
        'replaced, not left beside a new one', () async {
      final File file = writeRaw('note.json', 'old content');
      writeRaw('note.json.tmp', 'left by a crash');

      await schema.writeFile(file, const NoteDto(payload: 'p'));

      expect(onDisk(file)['payload'], 'p');
      expect(entryNames(), <String>['note.json']);
    });

    test('stages in <target>.tmp: a write whose staging path is taken fails '
        'and leaves the target untouched', () async {
      const String content = 'old content';
      final File file = writeRaw('note.json', content);
      Directory(fileNamed('note.json.tmp').path).createSync();

      await expectLater(
        schema.writeFile(file, const NoteDto(payload: 'p')),
        throwsA(isA<FileSystemException>()),
      );

      expectUntouched(file, content);
      expect(entryNames(), <String>['note.json', 'note.json.tmp']);
    });

    test('a failed rename removes its staging file', () async {
      final Directory occupied = Directory(fileNamed('note.json').path)
        ..createSync();
      File(
        '${occupied.path}${Platform.pathSeparator}inside.txt',
      ).writeAsStringSync('kept');

      await expectLater(
        schema.writeFile(File(occupied.path), const NoteDto(payload: 'p')),
        throwsA(isA<FileSystemException>()),
      );

      expect(entryNames(), <String>['note.json']);
      expect(
        <String>[
          for (final FileSystemEntity entity in occupied.listSync())
            entity.uri.pathSegments.last,
        ],
        <String>['inside.txt'],
      );
    });
  });

  group('file-system failures', () {
    final String? skip = _permissionSkipReason();

    test('readFile reads an unreadable file as null and leaves it as it '
        'was', () async {
      final String content = jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'payload': 'p',
      });
      final File file = writeRaw('locked.json', content);
      _chmod(<String>['000', file.path]);

      expect(await schema.readFile(file), isNull);

      _chmod(<String>['u+rw', file.path]);
      expectUntouched(file, content);
    }, skip: skip);

    test('a failed write-back propagates, leaving the file as it was and no '
        'staging file behind', () async {
      final String content = jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'payload': 'p',
      });
      final File file = writeRaw('v1.json', content);
      _chmod(<String>['a-w', tempDir.path]);

      await expectLater(
        schema.migrateFile(file),
        throwsA(isA<FileSystemException>()),
      );

      _chmod(<String>['u+w', tempDir.path]);
      expectUntouched(file, content);
      expect(entryNames(), <String>['v1.json']);
    }, skip: skip);
  });
}

/// Why the permission tests cannot run here, or null when they can: file modes
/// are POSIX-only, and root reads and writes regardless of them.
String? _permissionSkipReason() {
  if (Platform.isWindows) {
    return 'file modes are POSIX-only';
  }
  final ProcessResult id = Process.runSync('id', <String>['-u']);
  return (id.stdout as String).trim() == '0' ? 'root ignores file modes' : null;
}

void _chmod(List<String> arguments) {
  final ProcessResult result = Process.runSync('chmod', arguments);
  expect(result.exitCode, 0, reason: 'chmod ${arguments.join(' ')}');
}

/// A schema at version 2 whose one step leaves the version as it found it.
class _UnstampedNoteSchema extends VersionedJsonFileSchema<NoteDto> {
  const _UnstampedNoteSchema();

  @override
  int get currentVersion => 2;

  @override
  Map<String, dynamic> migrateOneStep(
    Map<String, dynamic> source,
    int sourceVersion,
    DateTime modifiedAt,
  ) => <String, dynamic>{...source, 'stepped': true};

  @override
  NoteDto fromJson(Map<String, dynamic> json) => NoteDto.fromJson(json);
}

/// A schema raised to version 2 that holds no step.
class _SteplessNoteSchema extends VersionedJsonFileSchema<NoteDto> {
  const _SteplessNoteSchema();

  @override
  int get currentVersion => 2;

  @override
  NoteDto fromJson(Map<String, dynamic> json) => NoteDto.fromJson(json);
}
