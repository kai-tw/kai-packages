import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:versioned_json/versioned_json.dart';
import 'package:versioned_json/versioned_json_io.dart';

import 'support/note_dto.dart';
import 'support/note_schema.dart';
import 'support/three_version_migrator.dart';

/// Real files in a temp directory: the file system is the only collaborator.
void main() {
  const VersionedJsonMigrator migrator = ThreeVersionMigrator();
  final DateTime stale = DateTime(2020, 1, 1, 12);
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('versioned_json_io_test_');
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
      entity.uri.pathSegments.last,
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

  Map<String, dynamic> readBack(File file) =>
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  void expectUntouched(File file, String content) {
    expect(file.readAsStringSync(), content);
    expect(file.lastModifiedSync(), stale);
  }

  group('migrateFile across the version axis', () {
    test('version 1 runs every step and writes the result back', () async {
      final File file = writeJson('v1.json', <String, dynamic>{
        'schemaVersion': 1,
        'payload': 'hello',
      });

      final Map<String, dynamic>? result = await migrator.migrateFile(file);

      expect(result!['schemaVersion'], 3);
      expect(result['payload'], 'hello');
      expect(result['step1to2'], isTrue);
      expect(result['step2to3'], isTrue);
      expect(readBack(file), result);
      expect(entryNames(), <String>['v1.json']);
    });

    test('the step receives the file\'s modification time', () async {
      final File file = writeJson('v1.json', <String, dynamic>{
        'schemaVersion': 1,
      });

      final Map<String, dynamic>? result = await migrator.migrateFile(file);

      expect(result!['migratedAt'], stale.toUtc().toIso8601String());
    });

    test('version 2 runs only the last step', () async {
      final File file = writeJson('v2.json', <String, dynamic>{
        'schemaVersion': 2,
        'payload': 'mid',
      });

      final Map<String, dynamic>? result = await migrator.migrateFile(file);

      expect(result!['schemaVersion'], 3);
      expect(result.containsKey('step1to2'), isFalse);
      expect(result['step2to3'], isTrue);
      expect(readBack(file), result);
    });

    test('the current version is returned without a write', () async {
      final Map<String, dynamic> body = <String, dynamic>{
        'schemaVersion': 3,
        'payload': 'current',
      };
      final File file = writeJson('v3.json', body);

      final Map<String, dynamic>? result = await migrator.migrateFile(file);

      expect(result, body);
      expectUntouched(file, jsonEncode(body));
    });

    test('a missing version key reads as version 1', () async {
      final File file = writeJson('legacy.json', <String, dynamic>{
        'payload': 'legacy',
      });

      final Map<String, dynamic>? result = await migrator.migrateFile(file);

      expect(result!['schemaVersion'], 3);
      expect(result['step1to2'], isTrue);
      expect(result['payload'], 'legacy');
    });

    test('a too-new version throws and the file is left untouched', () async {
      final String content = jsonEncode(<String, dynamic>{
        'schemaVersion': 4,
        'payload': 'future',
        'futureOnlyField': <String, int>{'a': 1, 'b': 2},
      });
      final File file = writeRaw('v4.json', content);

      await expectLater(
        migrator.migrateFile(file),
        throwsA(isA<SchemaVersionTooNewException>()),
      );
      expectUntouched(file, content);
    });

    test('an invalid version throws and the file is left untouched', () async {
      final String content = jsonEncode(<String, dynamic>{
        'schemaVersion': '2',
        'payload': 'x',
      });
      final File file = writeRaw('bad-version.json', content);

      await expectLater(
        migrator.migrateFile(file),
        throwsA(isA<SchemaVersionInvalidException>()),
      );
      expectUntouched(file, content);
    });
  });

  group('migrateFile on content that is not a JSON object', () {
    test('a missing file returns null', () async {
      expect(await migrator.migrateFile(fileNamed('nope.json')), isNull);
    });

    final Map<String, String> unreadable = <String, String>{
      'an empty file': '',
      'malformed JSON': '{not json at all',
      'a JSON array': '[1, 2, 3]',
      'a JSON string': '"schemaVersion"',
    };
    for (final MapEntry<String, String> entry in unreadable.entries) {
      test('${entry.key} returns null and is left untouched', () async {
        final File file = writeRaw('unreadable.json', entry.value);

        expect(await migrator.migrateFile(file), isNull);
        expectUntouched(file, entry.value);
      });
    }

    test('bytes that are not UTF-8 return null', () async {
      final File file = fileNamed('binary.json')
        ..writeAsBytesSync(<int>[0x7B, 0xFF, 0xFE, 0x7D]);

      expect(await migrator.migrateFile(file), isNull);
      expect(file.readAsBytesSync(), <int>[0x7B, 0xFF, 0xFE, 0x7D]);
    });
  });

  group('migrateDirectory', () {
    test('counts only rewritten files and leaves the rest untouched', () async {
      final File v1 = writeJson('a.json', <String, dynamic>{
        'schemaVersion': 1,
        'name': 'a',
      });
      final String current = jsonEncode(<String, dynamic>{
        'schemaVersion': 3,
        'name': 'b',
      });
      final File v3 = writeRaw('b.json', current);
      const String malformed = '{not json';
      final File broken = writeRaw('d.json', malformed);
      const String text = 'plain text';
      final File notJson = writeRaw('e.txt', text);

      expect(await migrator.migrateDirectory(tempDir), 1);

      expect(readBack(v1)['schemaVersion'], 3);
      expectUntouched(v3, current);
      expectUntouched(broken, malformed);
      expectUntouched(notJson, text);
    });

    test('goes on past files whose version cannot be migrated', () async {
      final String future = jsonEncode(<String, dynamic>{
        'schemaVersion': 4,
        'futureField': 'preserved',
      });
      final File tooNew = writeRaw('c.json', future);
      final String invalid = jsonEncode(<String, dynamic>{'schemaVersion': 0});
      final File invalidFile = writeRaw('f.json', invalid);
      final List<File> older = <File>[
        for (final String name in <String>['a', 'b', 'd', 'e', 'g'])
          writeJson('$name.json', <String, dynamic>{'schemaVersion': 1}),
      ];

      expect(await migrator.migrateDirectory(tempDir), older.length);

      for (final File file in older) {
        expect(readBack(file)['schemaVersion'], 3, reason: file.path);
      }
      expectUntouched(tooNew, future);
      expectUntouched(invalidFile, invalid);
    });

    test('a second run rewrites nothing', () async {
      writeJson('a.json', <String, dynamic>{'schemaVersion': 1});

      expect(await migrator.migrateDirectory(tempDir), 1);
      expect(await migrator.migrateDirectory(tempDir), 0);
    });

    test('a missing directory returns 0', () async {
      final Directory ghost = Directory(
        '${tempDir.path}${Platform.pathSeparator}never-made',
      );

      expect(await migrator.migrateDirectory(ghost), 0);
    });

    test('an empty directory returns 0', () async {
      expect(await migrator.migrateDirectory(tempDir), 0);
    });
  });

  group('VersionedJsonSchema files', () {
    const NoteSchema schema = NoteSchema();

    test('readFile migrates in place and parses', () async {
      final File file = writeJson('note.json', <String, dynamic>{
        'schemaVersion': 1,
        'payload': 'hello',
      });

      final NoteDto? dto = await schema.readFile(file);

      expect(dto!.payload, 'hello');
      expect(dto.schemaVersion, 3);
      expect(readBack(file)['schemaVersion'], 3);
    });

    test('readFile returns null for a missing file', () async {
      expect(await schema.readFile(fileNamed('nope.json')), isNull);
    });

    test('readFile lets a too-new version propagate', () async {
      final File file = writeJson('note.json', <String, dynamic>{
        'schemaVersion': 9,
        'payload': 'future',
      });

      await expectLater(
        schema.readFile(file),
        throwsA(isA<SchemaVersionTooNewException>()),
      );
    });

    test('writeFile replaces the content and reads back', () async {
      final File file = writeRaw('note.json', 'old content');

      await schema.writeFile(file, const NoteDto(payload: 'written'));

      expect(readBack(file), <String, dynamic>{
        'schemaVersion': 3,
        'payload': 'written',
      });
      expect((await schema.readFile(file))!.payload, 'written');
      expect(entryNames(), <String>['note.json']);
    });

    test('writeFile stamps the version a toJson leaves out', () async {
      final File file = fileNamed('keyless.json');

      await const _KeylessNoteSchema().writeFile(
        file,
        const _KeylessNoteDto(schemaVersion: 3),
      );

      expect(readBack(file), <String, dynamic>{
        'schemaVersion': 3,
        'payload': 'keyless',
      });
    });

    test(
      'writeFile rejects a DTO that is not at the current version',
      () async {
        const String content = 'old content';
        final File file = writeRaw('note.json', content);

        await expectLater(
          schema.writeFile(
            file,
            const NoteDto(payload: 'stale', schemaVersion: 2),
          ),
          throwsA(isA<ArgumentError>()),
        );
        expectUntouched(file, content);
        expect(entryNames(), <String>['note.json']);
      },
    );
  });

  group('file-system failures', () {
    final String? skip = _permissionSkipReason();

    test('migrateFile propagates an unreadable file', () async {
      final File file = writeJson('locked.json', <String, dynamic>{
        'schemaVersion': 1,
      });
      _chmod(<String>['000', file.path]);

      await expectLater(
        migrator.migrateFile(file),
        throwsA(isA<FileSystemException>()),
      );
    }, skip: skip);

    test('readFile propagates an unreadable file', () async {
      final File file = writeJson('locked.json', <String, dynamic>{
        'schemaVersion': 3,
        'payload': 'p',
      });
      _chmod(<String>['000', file.path]);

      await expectLater(
        const NoteSchema().readFile(file),
        throwsA(isA<FileSystemException>()),
      );
    }, skip: skip);

    test(
      'a failed write-back propagates and leaves the file as it was',
      () async {
        final String content = jsonEncode(<String, dynamic>{
          'schemaVersion': 1,
        });
        final File file = writeRaw('v1.json', content);
        _chmod(<String>['a-w', tempDir.path]);

        await expectLater(
          migrator.migrateFile(file),
          throwsA(isA<FileSystemException>()),
        );

        _chmod(<String>['u+w', tempDir.path]);
        expectUntouched(file, content);
        expect(entryNames(), <String>['v1.json']);
      },
      skip: skip,
    );

    test(
      'migrateDirectory skips an unreadable file and migrates the rest',
      () async {
        final String lockedContent = jsonEncode(<String, dynamic>{
          'schemaVersion': 1,
        });
        final File locked = writeRaw('c.json', lockedContent);
        final List<File> older = <File>[
          for (final String name in <String>['a', 'b', 'd', 'e'])
            writeJson('$name.json', <String, dynamic>{'schemaVersion': 1}),
        ];
        _chmod(<String>['000', locked.path]);

        expect(await migrator.migrateDirectory(tempDir), older.length);

        for (final File file in older) {
          expect(readBack(file)['schemaVersion'], 3, reason: file.path);
        }
        _chmod(<String>['u+rw', locked.path]);
        expectUntouched(locked, lockedContent);
      },
      skip: skip,
    );
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

/// A DTO whose `toJson` leaves out the version, as a generated serialiser does
/// for a getter.
class _KeylessNoteDto implements VersionedJsonDto {
  const _KeylessNoteDto({required this.schemaVersion});

  @override
  final int schemaVersion;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{'payload': 'keyless'};
}

class _KeylessNoteSchema extends VersionedJsonSchema<_KeylessNoteDto> {
  const _KeylessNoteSchema();

  @override
  VersionedJsonMigrator get migrator => const ThreeVersionMigrator();

  @override
  _KeylessNoteDto fromJson(Map<String, dynamic> json) =>
      _KeylessNoteDto(schemaVersion: json['schemaVersion'] as int);
}
