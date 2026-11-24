import 'package:test_toolkit/test_toolkit.dart';

/// One of the test slots `TestSlots` hands out, held until [release].
class TestSlot {
  TestSlot(this.number, this._release);

  final int number;
  final void Function() _release;

  /// Gives the slot back. Once only: a second call would close the slot's
  /// file again, after another lane may hold the same slot.
  void release() => _release();

  /// Set for a test process started while holding this slot. The
  /// `guardTestProcess()` in its `flutter_test_config.dart` then knows the
  /// slot is held for it, instead of waiting for a second one: with every
  /// slot held by a lane, that wait would never end.
  Map<String, String> get childEnvironment => <String, String>{
    QueueSettings.heldVariable: '$number',
  };
}
