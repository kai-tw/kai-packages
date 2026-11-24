import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_toolkit/test_toolkit.dart';

void main() {
  Future<ProcessResult> allocate(int maxMegabytes, int megabytes) =>
      Process.run(Platform.resolvedExecutable, <String>[
        'run',
        p.join('test', 'fixtures', 'allocate.dart'),
        '$maxMegabytes',
        '$megabytes',
      ]);

  test(
    'kills a process stuck allocating past its limit, and says why',
    () async {
      final ProcessResult result = await allocate(200, 2000);

      expect(result.exitCode, -ProcessSignal.sigkill.signalNumber);
      expect(result.stdout, isNot(contains('done')));
      expect(
        result.stderr,
        contains('over its 0.2 GB limit; killing it.'),
      );
    },
  );

  test('leaves a process under its limit alone', () async {
    final ProcessResult result = await allocate(2000, 50);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('done 50'));
    expect(result.stderr, isNot(contains('test_toolkit')));
  });

  test('rejects a limit below 1', () {
    expect(() => guardTestProcess(maxGigabytes: 0), throwsArgumentError);
    expect(() => MemoryLimit(maxBytes: 0), throwsArgumentError);
    expect(
      () => MemoryLimit(maxBytes: 1, interval: Duration.zero),
      throwsArgumentError,
    );
  });
}
