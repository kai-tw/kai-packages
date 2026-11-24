import 'slot_holder.dart';
import 'slot_pool.dart';
import 'slot_status.dart';

/// No test slot came free in time.
class SlotTimeoutException implements Exception {
  /// Reads who holds each of [pool]'s slots now, for the message.
  SlotTimeoutException(this.waited, SlotPool pool)
    : holders = <String>[
        for (final SlotStatus status in pool.survey())
          if (status.holder case final SlotHolder holder)
            'slot-${status.number}  ${holder.describe(DateTime.now())}',
      ];

  /// How long the process waited.
  final Duration waited;

  /// One line per slot that was held when the wait ended.
  final List<String> holders;

  String get message {
    final String howLong = waited.inMinutes >= 1
        ? '${waited.inMinutes} min'
        : '${waited.inSeconds} s';
    final String first =
        'test_toolkit: waited $howLong for a test slot and none came free. '
        'Holding them now:';
    return <String>[
      first,
      for (final String holder in holders) '  $holder',
    ].join('\n');
  }

  @override
  String toString() => message;
}
