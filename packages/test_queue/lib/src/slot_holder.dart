import 'dart:convert';

/// Who is holding a slot, written next to the slot so a run that has to wait
/// can say what it is waiting for.
class SlotHolder {
  const SlotHolder({
    required this.pid,
    required this.label,
    required this.workingDirectory,
    required this.command,
    required this.startedAt,
  });

  /// The holder written to [text], or `null` when [text] is not one. A
  /// holder is written just after its slot is locked, so a reader can find
  /// the slot taken and the file not written yet.
  factory SlotHolder.decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return SlotHolder.unknown;
    }
    if (json case <String, Object?>{
      'pid': final int pid,
      'label': final String label,
      'workingDirectory': final String workingDirectory,
      'command': final String command,
      'startedAt': final String startedAt,
    }) {
      final DateTime? started = DateTime.tryParse(startedAt);
      if (started != null) {
        return SlotHolder(
          pid: pid,
          label: label,
          workingDirectory: workingDirectory,
          command: command,
          startedAt: started,
        );
      }
    }
    return SlotHolder.unknown;
  }

  /// A holder whose details could not be read.
  static final SlotHolder unknown = SlotHolder(
    pid: 0,
    label: '(unknown)',
    workingDirectory: '',
    command: '',
    startedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  final int pid;

  /// A name a person recognises: the project, or what `--label` says.
  final String label;
  final String workingDirectory;
  final String command;
  final DateTime startedAt;

  String encode() => jsonEncode(<String, Object>{
    'pid': pid,
    'label': label,
    'workingDirectory': workingDirectory,
    'command': command,
    'startedAt': startedAt.toUtc().toIso8601String(),
  });

  /// One line for a person: label, pid, how long so far, and the command.
  String describe(DateTime now) {
    if (identical(this, unknown)) {
      return '(holder not readable)';
    }
    final Duration held = now.difference(startedAt);
    final String minutes = held.inMinutes.toString();
    final String seconds = (held.inSeconds % 60).toString().padLeft(2, '0');
    return '$label  pid $pid  ${minutes}m${seconds}s  $command';
  }
}
