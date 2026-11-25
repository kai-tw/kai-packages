import 'dart:io';

import 'package:test_toolkit/test_toolkit.dart';

/// Run as `write.dart <max megabytes> <megabytes to write> <file>`.
///
/// Sets a disk limit, then writes [file] in a synchronous loop that never
/// yields, the way a runaway test's log does, and prints `done` if it gets to
/// the end. The caller deletes the file: a killed process can't.
Future<void> main(List<String> args) async {
  final int maxMegabytes = int.parse(args[0]);
  final int writeMegabytes = int.parse(args[1]);
  final File file = File(args[2]);
  await DiskLimit(
    maxWrittenBytes: maxMegabytes * 1024 * 1024,
    interval: const Duration(milliseconds: 50),
    path: file.parent.path,
  ).start();

  final List<int> megabyte = List<int>.filled(1024 * 1024, 0x61);
  final RandomAccessFile out = file.openSync(mode: FileMode.write);
  for (int i = 0; i < writeMegabytes; i++) {
    out.writeFromSync(megabyte);
    // Flushed, so the free space drops now, not when the system gets to it.
    out.flushSync();
  }
  final Stopwatch held = Stopwatch()..start();
  while (held.elapsed < const Duration(milliseconds: 500)) {}
  out.closeSync();
  print('done $writeMegabytes');
}
