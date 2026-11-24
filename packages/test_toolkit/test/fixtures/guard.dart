import 'package:test_toolkit/test_toolkit.dart';

/// Run as `guard.dart <hold milliseconds> <slot wait seconds>`.
///
/// Calls [guardTestProcess] the way `flutter_test_config.dart` does, prints
/// `guarded` once it returns, then stays alive for the hold time, as the
/// tests in a test file would, and prints `done`.
Future<void> main(List<String> args) async {
  final int holdMilliseconds = int.parse(args[0]);
  final int waitSeconds = int.parse(args[1]);
  await guardTestProcess(slotWait: Duration(seconds: waitSeconds));
  print('guarded');
  await Future<void>.delayed(Duration(milliseconds: holdMilliseconds));
  print('done');
}
