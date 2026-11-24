import 'dart:io';

import 'package:test/test.dart';
import 'package:test_toolkit/test_toolkit.dart';

void main() {
  group('ProcessTable.parse', () {
    test('reads pid, ppid, uid and the whole command line', () {
      final ProcessTable table = ProcessTable.parse(
        '    1     0     0 /sbin/launchd\n'
        '  412     1  1000 /usr/bin/some tool --with "spaces"\n',
      );

      expect(table.rows, hasLength(2));
      final ProcessRow? row = table.find(412);
      expect(row?.ppid, 1);
      expect(row?.uid, 1000);
      expect(row?.command, '/usr/bin/some tool --with "spaces"');
    });

    test('skips a line that is not a process row', () {
      final ProcessTable table = ProcessTable.parse(
        'PID PPID UID COMMAND\n\n   7  1  0 init\n',
      );

      expect(table.rows.map((ProcessRow r) => r.pid), <int>[7]);
    });
  });

  test('find is null for a pid that is not running', () {
    expect(const ProcessTable(<ProcessRow>[]).find(5), isNull);
  });

  test('descendantsOf lists every parent before its children', () {
    final ProcessTable table = ProcessTable.parse(
      ' 10 1 0 root\n'
      ' 30 20 0 grandchild\n'
      ' 20 10 0 child\n'
      ' 21 10 0 sibling\n'
      ' 99 1 0 unrelated\n',
    );

    expect(table.descendantsOf(10).map((ProcessRow r) => r.pid), <int>[
      20,
      21,
      30,
    ]);
  });

  test('stillRunning drops a pid now used by a different command', () {
    const ProcessRow old = ProcessRow(
      pid: 5,
      ppid: 1,
      uid: 0,
      command: 'flutter_tester',
    );
    const ProcessRow gone = ProcessRow(pid: 6, ppid: 1, uid: 0, command: 'x');
    final ProcessTable now = ProcessTable.parse(' 5 1 0 something else\n');

    expect(now.stillRunning(<ProcessRow>[old, gone]), isEmpty);
    expect(
      ProcessTable.parse(' 5 1 0 flutter_tester\n').stillRunning(<ProcessRow>[
        old,
      ]),
      hasLength(1),
    );
  });

  test('read finds this process', () {
    expect(ProcessTable.read().find(pid), isNotNull);
  });

  test('killTree kills the root and what it started', () async {
    final Process shell = await Process.start('sh', <String>[
      '-c',
      'sleep 61 & sleep 62; true',
    ]);
    // Long enough for both children to be in the process table.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final List<ProcessRow> children = ProcessTable.read().descendantsOf(
      shell.pid,
    );
    expect(
      children.map((ProcessRow r) => r.command),
      containsAll(<String>['sleep 61', 'sleep 62']),
    );

    ProcessTable.killTree(shell.pid);
    await shell.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(ProcessTable.read().stillRunning(children), isEmpty);
  });
}
