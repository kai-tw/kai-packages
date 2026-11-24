import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_toolkit/test_toolkit.dart';

import 'support/fixture_process.dart';

void main() {
  late Directory directory;
  late TicketQueue queue;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('ticket_queue_');
    addTearDown(() => directory.deleteSync(recursive: true));
    queue = TicketQueue(directory);
  });

  Future<FixtureProcess> holdTicket(String expected) async {
    final FixtureProcess other = await FixtureProcess.start(
      'hold_ticket',
      <String>[directory.path],
      slots: directory.path,
    );
    await other.line('ticket $expected');
    return other;
  }

  test('numbers tickets in the order they are taken', () {
    final Ticket first = queue.take();
    final Ticket second = queue.take();
    final Ticket third = queue.take();

    expect(<int>[first.number, second.number, third.number], <int>[0, 1, 2]);
    expect(queue.waitingAhead(first), 0);
    expect(queue.waitingAhead(third), 2);
    for (final Ticket ticket in <Ticket>[first, second, third]) {
      ticket.leave();
    }
  });

  test(
    'stops counting a ticket once it leaves, and never reuses its number',
    () {
      final Ticket first = queue.take();
      final Ticket second = queue.take();

      first.leave();
      first.leave();

      expect(queue.waitingAhead(second), 0);
      final Ticket third = queue.take();
      expect(third.number, 2);
      second.leave();
      third.leave();
    },
  );

  test("counts another process's ticket while that process waits", () async {
    await holdTicket('0');

    final Ticket mine = queue.take();

    expect(mine.number, 1);
    expect(queue.waitingAhead(mine), 1);
    mine.leave();
  });

  test('deletes the ticket of a process that died waiting', () async {
    final FixtureProcess other = await holdTicket('0');
    final Ticket mine = queue.take();

    other.process.kill(ProcessSignal.sigkill);
    await other.process.exitCode;

    expect(queue.waitingAhead(mine), 0);
    expect(File(p.join(directory.path, 'ticket-0')).existsSync(), isFalse);
    mine.leave();
  });
}
