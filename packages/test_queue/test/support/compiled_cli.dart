import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The `test_queue` command, compiled once for a test file, with a slot
/// directory of its own so a test never touches the machine's real slots.
class CompiledCli {
  CompiledCli._(this.scratch, this.executable);

  /// Compiles `bin/test_queue.dart`. Call from `setUpAll`; [delete] in
  /// `tearDownAll`.
  static Future<CompiledCli> compile() async {
    final Directory scratch = Directory.systemTemp.createTempSync('tq_cli_');
    final String executable = p.join(scratch.path, 'test_queue');
    final ProcessResult result = await Process.run('dart', <String>[
      'compile',
      'exe',
      p.join('bin', 'test_queue.dart'),
      '-o',
      executable,
    ]);
    if (result.exitCode != 0) {
      fail('could not compile the CLI:\n${result.stderr}');
    }
    return CompiledCli._(scratch, executable);
  }

  final Directory scratch;
  final String executable;

  /// A fresh slot directory, for one test.
  String slotDirectory() =>
      Directory(scratch.path).createTempSync('slots_').path;

  /// Starts `test_queue` with [arguments], with [slots] as its slot
  /// directory and two slots, however much memory this machine has.
  Future<Process> start(List<String> arguments, String slots) async {
    final Process process = await Process.start(
      executable,
      arguments,
      environment: <String, String>{
        'TEST_QUEUE_DIR': slots,
        'TEST_QUEUE_SLOTS': '2',
        // Never too little memory: these tests are about the slots.
        'TEST_QUEUE_GB_PER_SLOT': '1',
        // A run killed outright leaves its temporary directory behind.
        'TMPDIR': scratch.path,
      },
    );
    // SIGTERM, so the run kills what it started on the way out.
    addTearDown(() => process.kill());
    return process;
  }

  /// Runs `test_queue` with [arguments] to the end.
  Future<ProcessResult> run(List<String> arguments, String slots) =>
      Process.run(
        executable,
        arguments,
        environment: <String, String>{
          'TEST_QUEUE_DIR': slots,
          'TEST_QUEUE_SLOTS': '2',
          'TEST_QUEUE_GB_PER_SLOT': '1',
          'TMPDIR': scratch.path,
        },
      );

  /// Completes once [process] writes a line containing [text] to stderr.
  static Future<void> stderrLine(Process process, String text) => process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((String line) => line.contains(text))
      .timeout(const Duration(seconds: 30));

  void delete() => scratch.deleteSync(recursive: true);
}
