import 'slot_holder.dart';

/// One slot, and who holds it.
class SlotStatus {
  const SlotStatus(this.number, this.holder);

  final int number;

  /// Who holds the slot, or `null` when it is free.
  final SlotHolder? holder;
}
