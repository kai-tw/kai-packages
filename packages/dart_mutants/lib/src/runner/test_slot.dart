/// One of the test slots `TestSlots` hands out, held until [release].
class TestSlot {
  TestSlot(this.number, this._release);

  final int number;
  final void Function() _release;

  /// Gives the slot back. Once only: a second call would close the slot's
  /// file again, after another lane may hold the same slot.
  void release() => _release();
}
