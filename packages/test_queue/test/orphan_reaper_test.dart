import 'dart:io';

import 'package:test/test.dart';
import 'package:test_queue/test_queue.dart';

const String _tester =
    '/home/u/flutter/bin/cache/artifacts/engine/darwin-x64/flutter_tester '
    '--enable-checked-mode';

void main() {
  group('isTestProcess', () {
    test('is true for flutter_tester', () {
      expect(OrphanReaper.isTestProcess(_tester), isTrue);
    });

    test('is true for the flutter tool running test, and only test', () {
      const String tool =
          '/sdk/bin/dartvm --packages=/flutter/packages/flutter_tools/'
          '.dart_tool/package_config.json /flutter/bin/cache/'
          'flutter_tools.snapshot';

      expect(OrphanReaper.isTestProcess('$tool test --coverage'), isTrue);
      expect(OrphanReaper.isTestProcess('$tool pub get'), isFalse);
      expect(OrphanReaper.isTestProcess('$tool run -d macos'), isFalse);
    });

    test('is true for the compiler flutter test starts', () {
      expect(
        OrphanReaper.isTestProcess(
          '/sdk/bin/dartaotruntime /sdk/bin/snapshots/frontend_server_aot'
          '.dart.snapshot --sdk-root /flutter/bin/cache/artifacts/engine/'
          'common/flutter_patched_sdk/',
        ),
        isTrue,
      );
    });

    test("is false for the Dart SDK's resident compiler", () {
      expect(
        OrphanReaper.isTestProcess(
          '/sdk/bin/dartaotruntime frontend_server_aot.dart.snapshot '
          '--sdk-root /flutter_patched_sdk --resident-info-file-name=/x',
        ),
        isFalse,
      );
    });

    test('is true for the development service of a flutter_tester', () {
      expect(
        OrphanReaper.isTestProcess(
          '/sdk/bin/dart development-service --vm-service-uri=http://x '
          '--app-name=Kind: Flutter - Device: flutter tester - Package: a',
        ),
        isTrue,
      );
    });

    test('is false for anything else', () {
      expect(OrphanReaper.isTestProcess('/sdk/bin/dart mcp-server'), isFalse);
      expect(
        OrphanReaper.isTestProcess('/bin/sh -c echo flutter_tester'),
        isFalse,
      );
    });
  });

  group('reap', () {
    late List<int> killed;
    late int reads;

    setUp(() {
      killed = <int>[];
      reads = 0;
    });

    /// A reaper whose first look sees [first] and every later look [later],
    /// with this process in both so the reaper can learn this user's uid.
    OrphanReaper reaper(String first, String later) => OrphanReaper(
      readTable: () => ProcessTable.parse(
        ' $pid 1 1000 dart\n${reads++ == 0 ? first : later}',
      ),
      kill: killed.add,
      confirmDelay: Duration.zero,
    );

    test("kills this user's orphaned testers that stay orphaned", () async {
      const String rows = ' 40 1 1000 $_tester\n';

      final List<ProcessRow> reaped = await reaper(rows, rows).reap();

      expect(reaped.map((ProcessRow r) => r.pid), <int>[40]);
      expect(killed, <int>[40]);
    });

    test('leaves a tester alone that still has its parent', () async {
      const String rows = ' 40 39 1000 $_tester\n';

      expect(await reaper(rows, rows).reap(), isEmpty);
      expect(killed, isEmpty);
    });

    test("leaves another user's tester alone", () async {
      const String rows = ' 40 1 1001 $_tester\n';

      expect(await reaper(rows, rows).reap(), isEmpty);
    });

    test('leaves a tester alone that is gone by the second look', () async {
      expect(await reaper(' 40 1 1000 $_tester\n', '').reap(), isEmpty);
      expect(killed, isEmpty);
    });

    test('dryRun lists without killing', () async {
      const String rows = ' 40 1 1000 $_tester\n';

      final List<ProcessRow> reaped = await reaper(
        rows,
        rows,
      ).reap(dryRun: true);

      expect(reaped, hasLength(1));
      expect(killed, isEmpty);
    });
  });
}
