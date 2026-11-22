/// A lane waited longer than `--slot-wait` for a test slot.
///
/// A run that waits for good would only move a hang from a stuck test to the
/// queue in front of it, where nobody sees it. So the run stops instead, and
/// says who held the slots.
class SlotWaitException implements Exception {
  const SlotWaitException(this.waited, this.holders);

  /// How long the lane waited.
  final Duration waited;

  /// Who held each slot when the wait ran out, one line each.
  final List<String> holders;

  String get message {
    final String who = holders.isEmpty
        ? 'nothing this run could see held them'
        : 'held by:\n${holders.map((String h) => '  $h').join('\n')}';
    return 'no test slot came free in ${waited.inSeconds}s; $who';
  }

  @override
  String toString() => 'SlotWaitException: $message';
}
