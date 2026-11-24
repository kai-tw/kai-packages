import 'package:test_toolkit/test_toolkit.dart';

/// Run as `prepare_test_process.dart <hold milliseconds> <slot wait seconds>`.
///
/// Calls [prepareTestProcess] the way `flutter_test_config.dart` does, prints
/// `prepared` once it returns, then stays alive for the hold time, as the
/// tests in a test file would, and prints `done`.
Future<void> main(List<String> args) async {
  final int holdMilliseconds = int.parse(args[0]);
  final int waitSeconds = int.parse(args[1]);
  await prepareTestProcess(slotWait: Duration(seconds: waitSeconds));
  print('prepared');
  await Future<void>.delayed(Duration(milliseconds: holdMilliseconds));
  print('done');
}
