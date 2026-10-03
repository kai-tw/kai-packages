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
    tempDir.deleteSync(recursive: true);
  });

  File fileNamed(String name) =>
      File('${tempDir.path}${Platform.pathSeparator}$name');

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
    });
  });
}
