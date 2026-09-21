/// A span of waiting, written the way somebody deciding whether to keep
/// waiting reads it: `3h 20m`, `14m`, `45s`.
///
/// Rounded on purpose. Every span this formats is either a projection or a
/// limit compared against one, and a figure printed to the second reads as
/// a promise the run cannot keep.
String formatWait(Duration d) {
  if (d.inMinutes < 1) {
    return '${d.inSeconds}s';
  }
  if (d.inHours < 1) {
    return '${d.inMinutes}m';
  }
  return '${d.inHours}h ${d.inMinutes % 60}m';
}
