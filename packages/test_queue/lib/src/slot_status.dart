import 'slot_holder.dart';

/// One slot as `test_queue status` reports it.
class SlotStatus {
  const SlotStatus(this.number, this.holder);

  final int number;

  /// Who holds the slot, or `null` when it is free.
  final SlotHolder? holder;
}
