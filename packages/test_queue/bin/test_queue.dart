import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:test_queue/test_queue.dart';

const String _usage = '''
Runs test suites through one queue shared by every caller on this machine.

  test_queue run [options] <command> [arguments]
      Waits for a slot and enough free memory, then runs the command. Every
      process the command starts is killed when it ends.
  test_queue status
      Lists the slots, who holds them, the free memory, and stray test
      processes.
  test_queue reap [--dry-run]
      Kills test processes left running by runs that are gone.

Exit codes: the command's own; 64 for a usage error; 75 when the wait ran
out (nothing ran, and trying again later is fine); 124 when --timeout ran
out; 127 when the command could not be started.''';

const int _usageError = 64;
const int _waitRanOut = 75;
const int _notStarted = 127;

Future<void> main(List<String> arguments) async {
  final ArgResults args;
  final QueueSettings settings;
  try {
    args = _parser().parse(arguments);
    settings = QueueSettings.fromEnvironment(
      Platform.environment,
      memoryBytes: await MemoryProbe().totalBytes(),
    );
  } on FormatException catch (e) {
    _fail(_explain(e));
    return;
  }
  exitCode = await _dispatch(args, settings);
}

Future<int> _dispatch(ArgResults args, QueueSettings settings) async {
  final ArgResults? command = args.command;
  return switch (command?.name) {
    'run' when command != null => _run(command, settings),
    'status' => _status(settings),
    'reap' when command != null => _reap(command),
    _ => _help(args),
  };
}

String _explain(FormatException e) =>
    e.source == null ? e.message : '${e.message}, not "${e.source}".';

ArgParser _parser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addCommand(
    'run',
    ArgParser(allowTrailingOptions: false)
      ..addOption('slots', defaultsTo: '1', help: 'Slots this run needs.')
      ..addOption(
        'wait',
        defaultsTo: '120',
        help: 'Seconds to wait for a slot and free memory.',
      )
      ..addOption('timeout', help: 'Seconds the command may run.')
      ..addOption('label', help: 'Name shown to runs that wait on this one.'),
  )
  ..addCommand('status')
  ..addCommand(
    'reap',
    ArgParser()..addFlag('dry-run', negatable: false, help: 'Only list them.'),
  );

int _help(ArgResults args) {
  stdout.writeln(_usage);
  return args.flag('help') ? 0 : _usageError;
}

Future<int> _run(ArgResults args, QueueSettings settings) async {
  final _RunRequest request;
  try {
    request = _RunRequest.parse(args, settings.slotCount);
  } on FormatException catch (e) {
    _fail(_explain(e));
    return _usageError;
  }
  if (Platform.environment.containsKey(QueueSettings.heldVariable)) {
    return _start(request, const <String, String>{});
  }
  final HeldSlots? held = await _admit(settings, request);
  if (held == null) {
    return _waitRanOut;
  }
  try {
    stderr.writeln(
      'test_queue: slot ${held.numbers.join(', ')} · '
      '${request.command.join(' ')}',
    );
    return await _start(request, <String, String>{
      QueueSettings.heldVariable: held.numbers.join(','),
    });
  } finally {
    held.release();
  }
}

/// What `test_queue run` was asked to do.
class _RunRequest {
  _RunRequest({
    required this.command,
    required this.slots,
    required this.wait,
    required this.timeout,
    required this.label,
  });

  /// Throws a [FormatException] for an option that is not a usable number,
  /// or for a run that needs more slots than the machine has.
  factory _RunRequest.parse(ArgResults args, int slotCount) {
    if (args.rest.isEmpty) {
      throw const FormatException('run needs a command to run');
    }
    final int slots = _slotCount(args.option('slots'));
    if (slots > slotCount) {
      throw FormatException(
        'this run needs $slots slots, and this machine has $slotCount',
      );
    }
    return _RunRequest(
      command: args.rest,
      slots: slots,
      wait: _seconds('wait', args.option('wait')) ?? _defaultWait,
      timeout: _seconds('timeout', args.option('timeout')),
      label: args.option('label'),
    );
  }

  final List<String> command;
  final int slots;

  /// How long to wait for a slot and free memory before giving up.
  final Duration wait;

  static const Duration _defaultWait = Duration(seconds: 120);
  final Duration? timeout;
  final String? label;

  static int _slotCount(String? text) {
    final int? count = int.tryParse(text ?? '');
    if (count == null || count < 1) {
      throw FormatException('--slots must be a whole number, 1 or more', text);
    }
    return count;
  }

  static Duration? _seconds(String name, String? text) {
    if (text == null) {
      return null;
    }
    final int? seconds = int.tryParse(text);
    if (seconds == null || seconds < 0) {
      throw FormatException('--$name must be a whole number of seconds', text);
    }
    return Duration(seconds: seconds);
  }
}

Future<HeldSlots?> _admit(QueueSettings settings, _RunRequest request) async {
  final TestQueue queue = TestQueue(
    pool: SlotPool(settings.directory, settings.slotCount),
    memoryPerSlot: settings.memoryPerSlot,
  );
  final HeldSlots? held = await queue.admit(
    slots: request.slots,
    holder: _holder(request.label, request.command),
    wait: request.wait,
    onWait: (String reason) => stderr.writeln('test_queue: $reason'),
    onReaped: (ProcessRow stray) =>
        stderr.writeln('test_queue: killed a stray test process: $stray'),
  );
  if (held == null) {
    stderr.writeln(
      'test_queue: gave up after ${request.wait.inSeconds}s. Nothing ran. '
      'Narrow the run, or try again once a holder above has finished.',
    );
  }
  return held;
}

SlotHolder _holder(String? label, List<String> command) => SlotHolder(
  pid: pid,
  label:
      label ??
      Platform.environment['TEST_QUEUE_LABEL'] ??
      p.basename(Directory.current.path),
  workingDirectory: Directory.current.path,
  command: command.join(' '),
  startedAt: DateTime.now(),
);

Future<int> _start(_RunRequest request, Map<String, String> environment) async {
  try {
    return await TreeRunner().run(
      request.command,
      timeout: request.timeout,
      environment: environment,
    );
  } on ProcessException catch (e) {
    stderr.writeln('test_queue: could not start ${request.command.first}: $e');
    return _notStarted;
  }
}

Future<int> _status(QueueSettings settings) async {
  final DateTime now = DateTime.now();
  final int? available = await MemoryProbe().availableBytes();
  final String free = available == null ? 'unknown' : '${_gb(available)} GB';
  stdout
    ..writeln(
      'test_queue · ${settings.slotCount} slots · ${settings.directory.path}',
    )
    ..writeln(
      'memory free: $free · needed per slot: '
      '${_gb(settings.memoryPerSlot)} GB',
    );
  for (final SlotStatus status in SlotPool(
    settings.directory,
    settings.slotCount,
  ).survey()) {
    stdout.writeln(
      '  slot-${status.number}  ${status.holder?.describe(now) ?? 'free'}',
    );
  }
  final List<ProcessRow> strays = await OrphanReaper().reap(dryRun: true);
  if (strays.isNotEmpty) {
    stdout.writeln(
      'stray test processes (`test_queue reap` kills them):\n'
      '${strays.map((ProcessRow row) => '  $row').join('\n')}',
    );
  }
  return 0;
}

Future<int> _reap(ArgResults args) async {
  final bool dryRun = args.flag('dry-run');
  final List<ProcessRow> strays = await OrphanReaper().reap(dryRun: dryRun);
  for (final ProcessRow row in strays) {
    stdout.writeln('${dryRun ? 'would kill' : 'killed'}  $row');
  }
  if (strays.isEmpty) {
    stdout.writeln('no stray test processes.');
  }
  return 0;
}

String _gb(int bytes) => (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

void _fail(String message) {
  stderr.writeln('test_queue: $message');
  exitCode = _usageError;
}
