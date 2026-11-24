import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A script in `test/fixtures`, running in a process of its own, with its
/// output collected line by line.
class FixtureProcess {
  FixtureProcess._(this.process) {
    _collect(process.stdout, stdoutLines);
    _collect(process.stderr, stderrLines);
  }

  /// Starts `test/fixtures/<script>.dart` with [arguments]. [slots] is the
  /// slot directory, with [slotCount] slots, so a test never touches the
  /// machine's real ones. Killed when the test ends.
  static Future<FixtureProcess> start(
    String script,
    List<String> arguments, {
    required String slots,
    int slotCount = 1,
    Map<String, String> environment = const <String, String>{},
  }) async {
    final Process process = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', p.join('test', 'fixtures', '$script.dart'), ...arguments],
      environment: <String, String>{
        'TEST_QUEUE_DIR': slots,
        'TEST_QUEUE_SLOTS': '$slotCount',
        // Never too little memory: these tests are about the slots.
        'TEST_QUEUE_GB_PER_SLOT': '1',
        'TEST_QUEUE_HELD': '',
        ...environment,
      },
    );
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    return FixtureProcess._(process);
  }

  final Process process;
  final List<String> stdoutLines = <String>[];
  final List<String> stderrLines = <String>[];
  final StreamController<void> _lines = StreamController<void>.broadcast();

  int get pid => process.pid;

  void _collect(Stream<List<int>> stream, List<String> into) {
    stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
      String line,
    ) {
      into.add(line);
      _lines.add(null);
    });
  }

  /// Completes once a line on stdout or stderr contains [text].
  Future<void> line(String text) async {
    bool seen() => <String>[
      ...stdoutLines,
      ...stderrLines,
    ].any((String l) => l.contains(text));
    if (seen()) {
      return;
    }
    await _lines.stream
        .firstWhere((_) => seen())
        .timeout(const Duration(seconds: 60));
  }
}
