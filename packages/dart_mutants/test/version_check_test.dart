import 'dart:convert';
import 'dart:io';

import 'package:dart_mutants/src/version_check.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String cache;
  final DateTime now = DateTime.utc(2026, 11, 5, 12);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('version_check_test_');
    cache = p.join(dir.path, 'dart_mutants', 'latest_release.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  VersionCheck check(String current, String? latest, {List<int>? asked}) =>
      VersionCheck(
        current: current,
        cachePath: cache,
        now: () => now,
        fetchLatest: () async {
          asked?.add(1);
          return latest;
        },
      );

  void keep(String latest, DateTime at) => File(cache)
    ..createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode(<String, String>{
        'latest': latest,
        'checkedAt': at.toIso8601String(),
      }),
    );

  test('[partition] the newest release runs, and a newer one too', () async {
    await check('0.9.0', '0.9.0').check();
    await check('0.10.0', '0.9.0').check();
  });

  test('[decision] an older engine stops the run, naming the release to '
      'move to', () async {
    await expectLater(
      check('0.8.0', '0.9.0').check(),
      throwsA(
        isA<OutdatedEngineException>().having(
          (OutdatedEngineException e) => e.message,
          'message',
          allOf(contains('0.9.0 is out'), contains('dart_mutants-v0.9.0')),
        ),
      ),
    );
  });

  test('[decision] with no answer and nothing kept, the run stops too — an '
      'engine it cannot vouch for is not run', () async {
    await expectLater(
      check('0.9.0', null).check(),
      throwsA(isA<OutdatedEngineException>()),
    );
  });

  test('[state] an answer is kept for a day: the next run within it asks '
      'nothing, and one after it asks again', () async {
    final List<int> asked = <int>[];
    await check('0.9.0', '0.9.0', asked: asked).check();
    await check('0.9.0', '0.9.0', asked: asked).check();
    expect(asked, hasLength(1));

    keep('0.9.0', now.subtract(const Duration(days: 2)));
    await check('0.9.0', '0.9.0', asked: asked).check();
    expect(asked, hasLength(2));
  });

  test('[boundary] a release kept from the last day is still enforced, '
      'without asking', () async {
    keep('0.9.0', now.subtract(const Duration(hours: 1)));
    final List<int> asked = <int>[];
    await expectLater(
      check('0.8.0', '0.8.0', asked: asked).check(),
      throwsA(isA<OutdatedEngineException>()),
    );
    expect(asked, isEmpty);
  });

  group('newestTag', () {
    test('[partition] the highest version wins, by number not by text', () {
      expect(
        newestTag(
          'a\trefs/tags/dart_mutants-v0.9.0\n'
          'b\trefs/tags/dart_mutants-v0.10.0\n'
          'c\trefs/tags/dart_mutants-v0.8.1\n',
        ),
        '0.10.0',
      );
    });

    test('[boundary] other packages\' tags and odd names are ignored', () {
      expect(
        newestTag(
          'a\trefs/tags/ui_kit-v9.0.0\n'
          'b\trefs/tags/dart_mutants-v1.0.0-dev\n',
        ),
        isNull,
      );
    });
  });
}
