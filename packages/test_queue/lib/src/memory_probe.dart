import 'dart:io';

/// Runs a command and hands back what it printed, or `null` when it could not
/// be run or failed.
typedef CommandOutput =
    Future<String?> Function(String executable, List<String> arguments);

/// Reads how much memory the machine has, and how much a new test run could
/// still use.
class MemoryProbe {
  MemoryProbe({CommandOutput? run, Future<String?> Function()? readMeminfo})
    : _run = run ?? _runCommand,
      _readMeminfo = readMeminfo ?? _readProcMeminfo;

  final CommandOutput _run;
  final Future<String?> Function() _readMeminfo;

  /// The machine's installed memory in bytes, or `null` where it cannot be
  /// read.
  Future<int?> totalBytes() async {
    if (Platform.isMacOS) {
      final String? out = await _run('sysctl', <String>['-n', 'hw.memsize']);
      return out == null ? null : int.tryParse(out.trim());
    }
    if (Platform.isLinux) {
      return parseMeminfo(await _readMeminfo() ?? '', 'MemTotal');
    }
    return null;
  }

  /// The bytes a new process could use without pushing the machine into
  /// swap, or `null` where they cannot be read.
  Future<int?> availableBytes() async {
    if (Platform.isMacOS) {
      return parseVmStat(await _run('vm_stat', const <String>[]) ?? '');
    }
    if (Platform.isLinux) {
      return parseMeminfo(await _readMeminfo() ?? '', 'MemAvailable');
    }
    return null;
  }

  /// The free, inactive, speculative and purgeable pages in `vm_stat`
  /// output, in bytes: the memory macOS hands out before it has to compress
  /// or swap anything.
  ///
  /// `kern.memorystatus_level` was the other candidate and was rejected: it
  /// counts memory the compressor could still make room in as free, and read
  /// 77% free on a machine whose free and reclaimable pages added up to 38%.
  static int? parseVmStat(String text) {
    final RegExpMatch? size = RegExp(
      r'page size of (\d+) bytes',
    ).firstMatch(text);
    if (size == null) {
      return null;
    }
    int pages = 0;
    for (final String kind in const <String>[
      'free',
      'inactive',
      'speculative',
      'purgeable',
    ]) {
      final RegExpMatch? count = RegExp(
        'Pages $kind:\\s+(\\d+)',
      ).firstMatch(text);
      if (count == null) {
        return null;
      }
      pages += int.parse(count.group(1) ?? '');
    }
    return pages * int.parse(size.group(1) ?? '');
  }

  /// The `/proc/meminfo` field [key] in bytes, or `null` when it is missing.
  static int? parseMeminfo(String text, String key) {
    final RegExpMatch? match = RegExp(
      '^$key:\\s+(\\d+) kB',
      multiLine: true,
    ).firstMatch(text);
    return match == null ? null : int.parse(match.group(1) ?? '') * 1024;
  }

  static Future<String?> _runCommand(
    String executable,
    List<String> arguments,
  ) async {
    try {
      final ProcessResult result = await Process.run(executable, arguments);
      return result.exitCode == 0 ? result.stdout as String : null;
    } on ProcessException {
      return null;
    }
  }

  static Future<String?> _readProcMeminfo() async {
    try {
      return await File('/proc/meminfo').readAsString();
    } on FileSystemException {
      return null;
    }
  }
}
