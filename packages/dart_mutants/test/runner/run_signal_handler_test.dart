import 'dart:async';
import 'dart:io';

import 'package:dart_mutants/src/runner/run_signal_handler.dart';
import 'package:test/test.dart';

void main() {
  test(
    '[partition] arm is idempotent and disarm leaves it callable again',
    () async {
      final RunSignalHandler handler = RunSignalHandler();
      expect(handler.isArmed, isFalse);
      handler.arm();
      expect(handler.isArmed, isTrue);
      handler.arm(); // must not double-subscribe
      await handler.disarm();
      expect(handler.isArmed, isFalse);
    },
  );

  test(
    '[boundary] a second arm call is a true no-op — the already-armed '
    'guard, not just an accident of overwriting, is what blocks the second '
    'beforeExit from taking effect',
    () async {
      final RunSignalHandler handler = RunSignalHandler();
      bool firstCalled = false;
      bool secondCalled = false;

      handler.arm(beforeExit: () => firstCalled = true);
      handler.arm(beforeExit: () => secondCalled = true);
      handler.handleSignal();

      expect(firstCalled, isTrue);
      expect(secondCalled, isFalse);

      await handler.disarm();
    },
  );

  test(
    '[partition] a delivered signal runs beforeExit, then exits 1',
    () async {
      final StreamController<ProcessSignal> sigterm =
          StreamController<ProcessSignal>();
      final List<String> order = <String>[];
      final RunSignalHandler handler = RunSignalHandler(
        watchSignal: (ProcessSignal s) => s == ProcessSignal.sigterm
            ? sigterm.stream
            : const Stream<ProcessSignal>.empty(),
        exitProcess: (int code) => order.add('exit $code'),
      );
      handler.arm(beforeExit: () => order.add('beforeExit'));

      sigterm.add(ProcessSignal.sigterm);
      await pumpEventQueue();

      expect(order, <String>['beforeExit', 'exit 1']);
      await handler.disarm();
      await sigterm.close();
    },
  );

  test(
    '[boundary] a platform that cannot watch SIGTERM still arms on SIGINT, '
    'and says so',
    () async {
      final _RecordingStdout err = _RecordingStdout();
      final RunSignalHandler handler = RunSignalHandler(
        watchSignal: (ProcessSignal s) => s == ProcessSignal.sigterm
            ? throw const SignalException('unsupported')
            : const Stream<ProcessSignal>.empty(),
      );

      IOOverrides.runZoned(handler.arm, stderr: () => err);

      expect(handler.isArmed, isTrue);
      expect(
        err.text.toString(),
        contains('cannot watch SIGTERM on this platform (unsupported)'),
      );
      await handler.disarm();
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
