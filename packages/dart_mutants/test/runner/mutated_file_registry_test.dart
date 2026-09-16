import 'dart:async';
import 'dart:io';

import 'package:dart_mutants/src/runner/mutated_file_registry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late File file;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'mutated_file_registry_test_',
    );
    file = File(p.join(tempDir.path, 'target.dart'))
      ..writeAsStringSync('original content');
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('[partition] restore puts the tracked content back', () {
    final MutatedFileRegistry registry = MutatedFileRegistry();
    registry.track(file.path, 'original content');
    file.writeAsStringSync('mutated content');

    registry.restore(file.path);

    expect(file.readAsStringSync(), 'original content');
  });

  test('[boundary] restoring an untracked path is a no-op, not an error', () {
    final MutatedFileRegistry registry = MutatedFileRegistry();
    expect(() => registry.restore(file.path), returnsNormally);
  });

  test(
    '[boundary] the second track for the same path does not overwrite the '
    'first — only the true original is ever restored',
    () {
      final MutatedFileRegistry registry = MutatedFileRegistry();
      registry.track(file.path, 'true original');
      registry.track(file.path, 'a later mutant\'s "before" snapshot');
      file.writeAsStringSync('current mutated state');

      registry.restore(file.path);

      expect(file.readAsStringSync(), 'true original');
    },
  );

  test('[partition] restoreAll restores every tracked file', () {
    final File second = File(p.join(tempDir.path, 'second.dart'))
      ..writeAsStringSync('second original');
    final MutatedFileRegistry registry = MutatedFileRegistry();
    registry.track(file.path, 'original content');
    registry.track(second.path, 'second original');
    file.writeAsStringSync('mutated');
    second.writeAsStringSync('mutated');

    registry.restoreAll();

    expect(file.readAsStringSync(), 'original content');
    expect(second.readAsStringSync(), 'second original');
  });

  test('[boundary] restore after restoreAll is a no-op', () {
    final MutatedFileRegistry registry = MutatedFileRegistry();
    registry.track(file.path, 'original content');
    registry.restoreAll();
    file.writeAsStringSync('mutated again, unrelated to this registry now');

    registry.restore(file.path);

    // restoreAll already forgot this path, so a later restore() must not
    // resurrect a stale snapshot over whatever is there now.
    expect(
      file.readAsStringSync(),
      'mutated again, unrelated to this registry now',
    );
  });

  test(
    '[partition] armSignalRestore is idempotent and disarm leaves it '
    'callable again',
    () async {
      final MutatedFileRegistry registry = MutatedFileRegistry();
      expect(registry.isArmed, isFalse);
      registry.armSignalRestore();
      expect(registry.isArmed, isTrue);
      registry.armSignalRestore(); // must not double-subscribe
      await registry.disarm();
      expect(registry.isArmed, isFalse);
    },
  );

  test(
    '[boundary] a second armSignalRestore call is a true no-op — the '
    'already-armed guard, not just an accident of overwriting, is what '
    'blocks the second beforeExit from taking effect',
    () async {
      final MutatedFileRegistry registry = MutatedFileRegistry();
      bool firstCalled = false;
      bool secondCalled = false;

      registry.armSignalRestore(beforeExit: () => firstCalled = true);
      registry.armSignalRestore(beforeExit: () => secondCalled = true);
      registry.handleSignal();

      expect(firstCalled, isTrue);
      expect(secondCalled, isFalse);

      await registry.disarm();
    },
  );

  test(
    '[partition] handleSignal restores every tracked file before running '
    'beforeExit — the same effect _onSignal has, minus the process exit',
    () async {
      final MutatedFileRegistry registry = MutatedFileRegistry();
      registry.track(file.path, 'original content');
      file.writeAsStringSync('mutated content');
      bool beforeExitCalled = false;

      registry.armSignalRestore(beforeExit: () => beforeExitCalled = true);
      registry.handleSignal();

      expect(file.readAsStringSync(), 'original content');
      expect(beforeExitCalled, isTrue);

      await registry.disarm();
    },
  );

  test(
    '[partition] a delivered signal restores, runs beforeExit, then exits 1',
    () async {
      final StreamController<ProcessSignal> sigterm =
          StreamController<ProcessSignal>();
      final List<String> order = <String>[];
      final MutatedFileRegistry registry = MutatedFileRegistry(
        watchSignal: (ProcessSignal s) => s == ProcessSignal.sigterm
            ? sigterm.stream
            : const Stream<ProcessSignal>.empty(),
        exitProcess: (int code) => order.add('exit $code'),
      );
      registry.track(file.path, 'original content');
      file.writeAsStringSync('mutated content');
      registry.armSignalRestore(
        beforeExit: () => order.add(
          'beforeExit, file: ${file.readAsStringSync()}',
        ),
      );

      sigterm.add(ProcessSignal.sigterm);
      await pumpEventQueue();

      expect(order, <String>[
        'beforeExit, file: original content',
        'exit 1',
      ]);
      await registry.disarm();
      await sigterm.close();
    },
  );

  test(
    '[boundary] a platform that cannot watch SIGTERM still arms on SIGINT, '
    'and says so',
    () async {
      final _RecordingStdout err = _RecordingStdout();
      final MutatedFileRegistry registry = MutatedFileRegistry(
        watchSignal: (ProcessSignal s) => s == ProcessSignal.sigterm
            ? throw const SignalException('unsupported')
            : const Stream<ProcessSignal>.empty(),
      );

      IOOverrides.runZoned(registry.armSignalRestore, stderr: () => err);

      expect(registry.isArmed, isTrue);
      expect(
        err.text.toString(),
        contains('cannot watch SIGTERM on this platform (unsupported)'),
      );
      await registry.disarm();
    },
  );
}

class _RecordingStdout implements Stdout {
  final StringBuffer text = StringBuffer();

  @override
  void writeln([Object? object = '']) => text.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
