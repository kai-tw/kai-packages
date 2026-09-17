import 'dart:io';

/// The machine's 1-, 5- and 15-minute load averages, read at the start and
/// end of a run.
///
/// A run's times mean little without it: the same unmodified suite has been
/// measured at 9s and at 29s on one workstation, depending on what else it
/// was running. Recorded so a slow run can be told from a busy machine.
class HostLoad {
  const HostLoad(this.averages);

  final List<double> averages;

  List<double> toJson() => averages;

  /// This machine's load, or `null` where it cannot be read. Never throws:
  /// a statistic is not worth failing a run over.
  static Future<HostLoad?> read() async {
    try {
      if (Platform.isLinux) {
        return parse(await File('/proc/loadavg').readAsString());
      }
      if (Platform.isMacOS) {
        final ProcessResult result = await Process.run('sysctl', <String>[
          '-n',
          'vm.loadavg',
        ]);
        return result.exitCode == 0 ? parse(result.stdout as String) : null;
      }
      return null;
    } on FileSystemException {
      return null;
    } on ProcessException {
      return null;
    }
  }

  /// The first three numbers in [text] — `/proc/loadavg` reads
  /// `0.52 0.58 0.59 1/467 12345`, `sysctl -n vm.loadavg` reads
  /// `{ 1.23 1.45 1.67 }` — or `null` when there are fewer.
  static HostLoad? parse(String text) {
    final List<double> numbers = RegExp(
      r'\d+(?:\.\d+)?',
    ).allMatches(text).take(3).map((Match m) => double.parse(m[0]!)).toList();
    return numbers.length == 3 ? HostLoad(numbers) : null;
  }
}
