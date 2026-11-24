/// Slots a run holds until [release].
class HeldSlots {
  HeldSlots(this.numbers, this._release);

  /// Which slots, by number.
  final List<int> numbers;
  final void Function() _release;
  bool _released = false;

  /// Gives the slots back. Later calls do nothing: a second release would
  /// close a slot's file again, after another run may have taken the slot.
  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _release();
  }
}
