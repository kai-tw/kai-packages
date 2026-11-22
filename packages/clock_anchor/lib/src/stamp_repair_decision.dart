/// What to do with one timestamp that was written while the clock may have
/// been wrong.
class StampRepairDecision {
  /// The stamp is not implausibly ahead of the current reading.
  const StampRepairDecision.keep()
    : action = StampRepairAction.keep,
      repairedTo = null,
      excess = Duration.zero;

  /// The current reading is not trustworthy enough to judge the stamp.
  ///
  /// Distinct from [StampRepairDecision.keep] on purpose: nothing is wrong
  /// with the stamp *as far as we can tell*, and the caller should ask again
  /// once an anchor exists rather than record that it checked.
  const StampRepairDecision.defer()
    : action = StampRepairAction.defer,
      repairedTo = null,
      excess = Duration.zero;

  /// The stamp is [excess] ahead of what the clock can justify and should be
  /// re-issued at [repairedTo].
  const StampRepairDecision.repair({
    required this.repairedTo,
    required this.excess,
  }) : action = StampRepairAction.repair;

  /// Which of the three outcomes this is.
  final StampRepairAction action;

  /// The instant a repaired stamp should be re-issued at; null unless
  /// [action] is [StampRepairAction.repair].
  final DateTime? repairedTo;

  /// How far ahead of the trusted reading the stamp sits. Zero unless
  /// [action] is [StampRepairAction.repair].
  final Duration excess;

  /// Convenience for the common branch.
  bool get isRepairNeeded => action == StampRepairAction.repair;

  @override
  String toString() => 'StampRepairDecision(${action.name}, excess=$excess)';
}

/// The three outcomes of inspecting a stamp.
enum StampRepairAction {
  /// Leave it alone.
  keep,

  /// Re-issue it.
  repair,

  /// Cannot tell yet; ask again with a trustworthy reading.
  defer,
}
