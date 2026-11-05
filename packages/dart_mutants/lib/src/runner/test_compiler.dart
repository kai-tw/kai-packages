import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'flutter_sdk.dart';
import 'process_command.dart';

/// The compiler `flutter test` keeps running, compiling one entry at a time
/// to a full kernel file at [outputDill].
///
/// One process for the whole run: after the first compile, each next one
/// only reads what changed, about 1.5–3s for a test file of a large app
/// where `flutter test` spends that on every run. A compile with errors
/// stops the process, as `flutter test` does; the next compile starts a new
/// one.
class TestCompiler {
  TestCompiler(
    this._sdk, {
    required this.packageConfig,
    required this.workingDirectory,
    required this.outputDill,
  });

  final FlutterSdk _sdk;
  final String packageConfig;
  final String workingDirectory;
  final String outputDill;

  Process? _process;
  StreamSubscription<String>? _lines;

  /// Completes with whether the compile in flight wrote a program without
  /// errors.
  Completer<bool>? _pending;
  String? _boundary;
  int _requests = 0;

  /// Compiles [entry]; `true` when [outputDill] now holds it, compiled
  /// without errors, within [timeout].
  Future<bool> compile(String entry, Duration timeout) async {
    final bool fresh = _process == null;
    final Process process = _process ??= await _start();
    final String uri = Uri.file(entry).toString();
    final String key = 'dm${_requests++}';
    final Completer<bool> result = _pending = Completer<bool>();
    process.stdin.write(
      fresh ? 'compile $uri\n' : 'recompile $uri $key\n$uri\n$key\n',
    );
    final bool compiled = await result.future.timeout(
      timeout,
      onTimeout: () => false,
    );
    if (!compiled) {
      await close();
      return false;
    }
    // Accepted, then reset: the next compile writes a whole program again,
    // not just what changed since this one.
    process.stdin.write('accept\nreset\n');
    return true;
  }

  Future<Process> _start() async {
    final Process process = await Process.start(_sdk.dartAotRuntime, <String>[
      _sdk.frontendServer,
      '--sdk-root',
      '${_sdk.patchedSdk}${p.separator}',
      '--incremental',
      '--no-print-incremental-dependencies',
      '--target=flutter',
      '--experimental-emit-debug-metadata',
      '--output-dill',
      outputDill,
      '--packages',
      packageConfig,
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=false',
      '--enable-asserts',
      '--track-widget-creation',
      '--verbosity=error',
    ], workingDirectory: workingDirectory);
    ProcessCommand.track(process.pid);
    unawaited(process.stderr.drain<void>());
    unawaited(_ignoreBrokenPipe(process));
    unawaited(_watchExit(process));
    _lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    return process;
  }

  /// Writing to a compiler that died fails on its stdin, not where it was
  /// written, as a broken pipe — a `SocketException`, since that is what a
  /// child's pipes are in `dart:io`. Its exit already answers whatever was
  /// waiting.
  static Future<void> _ignoreBrokenPipe(Process process) async {
    try {
      await process.stdin.done;
    } on SocketException {
      return;
    }
  }

  Future<void> _watchExit(Process process) async {
    await process.exitCode;
    ProcessCommand.untrack(process.pid);
    if (identical(_process, process)) {
      _process = null;
    }
    _finish(compiled: false);
  }

  /// `result <boundary>` opens an answer, diagnostics follow, and
  /// `<boundary> <dill> <errors>` closes it.
  void _onLine(String line) {
    if (line.startsWith('result ')) {
      _boundary = line.substring('result '.length);
      return;
    }
    final String? boundary = _boundary;
    if (boundary == null || !line.startsWith('$boundary ')) {
      return;
    }
    _boundary = null;
    final List<String> parts = line.substring(boundary.length + 1).split(' ');
    _finish(
      compiled:
          parts.length == 2 &&
          parts.first.isNotEmpty &&
          int.tryParse(parts.last) == 0,
    );
  }

  void _finish({required bool compiled}) {
    final Completer<bool>? pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(compiled);
    }
  }

  /// Stops the compiler. Safe to call when it never started, and twice.
  Future<void> close() async {
    final Process? process = _process;
    _process = null;
    _boundary = null;
    if (process == null) {
      return;
    }
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await _lines?.cancel();
    _lines = null;
  }
}
