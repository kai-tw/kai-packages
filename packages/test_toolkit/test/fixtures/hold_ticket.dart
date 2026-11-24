import 'dart:io';

import 'package:test_toolkit/test_toolkit.dart';

/// Run as `hold_ticket.dart <queue directory>`.
///
/// Takes a ticket, prints `ticket <n>` to stderr, and holds it until killed.
Future<void> main(List<String> args) async {
  final Ticket ticket = TicketQueue(Directory(args[0])).take();
  stderr.writeln('ticket ${ticket.number}');
  await Future<void>.delayed(const Duration(minutes: 5));
}
