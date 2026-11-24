import 'package:test_memory_limit/test_memory_limit.dart';

/// Run as `allocate.dart <max megabytes> <megabytes to allocate>`.
///
/// Sets a limit, then allocates in a synchronous loop that never yields, the
/// way a runaway test does, and prints `done` if it gets to the end.
Future<void> main(List<String> args) async {
  final int maxMegabytes = int.parse(args[0]);
  final int allocateMegabytes = int.parse(args[1]);
  await MemoryLimit(
    maxBytes: maxMegabytes * 1024 * 1024,
    interval: const Duration(milliseconds: 50),
  ).start();

  final List<List<int>> kept = <List<int>>[];
  // Each list of 2^17 ints is 1 MB.
  for (int i = 0; i < allocateMegabytes; i++) {
    kept.add(List<int>.filled(1 << 17, i));
  }
  final Stopwatch held = Stopwatch()..start();
  while (held.elapsed < const Duration(milliseconds: 500)) {
    kept.last[0]++;
  }
  print('done ${kept.length}');
}
