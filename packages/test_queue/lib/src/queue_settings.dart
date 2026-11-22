import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the machine's slots live, how many there are, and how much free
/// memory a run needs before it starts. Every caller on the machine has to
/// read the same values, or each of them counts a budget of its own, which
/// is the failure this package exists to end.
class QueueSettings {
  const QueueSettings({
    required this.directory,
    required this.slotCount,
    required this.memoryPerSlot,
  });

  /// The settings [environment] names, with the defaults below for any it
  /// leaves out.
  ///
  /// Throws a [FormatException] when a variable is set to something that is
  /// not a whole number, 1 or more.
  factory QueueSettings.fromEnvironment(
    Map<String, String> environment, {
    required int? memoryBytes,
  }) {
    final int? slots = _positive(environment, slotsVariable);
    final int? gigabytes = _positive(environment, memoryVariable);
    return QueueSettings(
      directory: Directory(
        environment[directoryVariable] ??
            p.join(_cacheHome(environment), 'test_queue', 'slots'),
      ),
      slotCount: slots ?? slotsFor(memoryBytes),
      memoryPerSlot: gigabytes == null
          ? defaultMemoryPerSlot
          : gigabytes * _gigabyte,
    );
  }

  static const String directoryVariable = 'TEST_QUEUE_DIR';
  static const String slotsVariable = 'TEST_QUEUE_SLOTS';
  static const String memoryVariable = 'TEST_QUEUE_GB_PER_SLOT';

  /// Set for a command a run starts, so a `test_queue run` inside it runs
  /// straight through instead of waiting for a slot its own parent holds.
  static const String heldVariable = 'TEST_QUEUE_HELD';

  static const int _gigabyte = 1024 * 1024 * 1024;

  /// What one `flutter test` was measured using at its peak: 1.4 GB for the
  /// compiler, 1.1 GB for five `flutter_tester` processes, and 0.2 GB for
  /// the `flutter` tool. Rounded up to 3 GB.
  static const int defaultMemoryPerSlot = 3 * _gigabyte;

  /// One slot for every 4 GB beyond the first 8, which the system, the
  /// editor and the browser keep; at least one. Memory that cannot be read
  /// gets the one slot that is always safe.
  static int slotsFor(int? memoryBytes) {
    if (memoryBytes == null) {
      return 1;
    }
    final int count = (memoryBytes ~/ _gigabyte - 8) ~/ 4;
    return count < 1 ? 1 : count;
  }

  final Directory directory;
  final int slotCount;

  /// The free memory one slot's run needs before it may start, in bytes.
  final int memoryPerSlot;

  static int? _positive(Map<String, String> environment, String name) {
    final String? given = environment[name];
    if (given == null) {
      return null;
    }
    final int? parsed = int.tryParse(given.trim());
    if (parsed == null || parsed < 1) {
      throw FormatException('\$$name must be a whole number, 1 or more', given);
    }
    return parsed;
  }

  static String _cacheHome(Map<String, String> environment) =>
      environment['XDG_CACHE_HOME'] ??
      p.join(environment['HOME'] ?? '.', '.cache');
}
