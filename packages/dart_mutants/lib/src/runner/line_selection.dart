/// One `--lines` value: a file, and the lines of it to mutate.
class LineSelection {
  const LineSelection(this.file, this.lines);

  /// Parses `<file>:<ranges>`, ranges being `3-7,12`. Throws a
  /// [FormatException] naming what is wrong.
  factory LineSelection.parse(String value) {
    final int colon = value.lastIndexOf(':');
    if (colon <= 0 || colon == value.length - 1) {
      throw FormatException(
        'expected <file>:<ranges>, e.g. lib/a.dart:3-7,12',
        value,
      );
    }
    return LineSelection(value.substring(0, colon), <int>{
      for (final String range in value.substring(colon + 1).split(','))
        ..._linesOf(range, value),
    });
  }

  final String file;
  final Set<int> lines;
}

/// The lines `3-7` or `12` names, or a [FormatException] about [value].
List<int> _linesOf(String range, String value) {
  final List<String> bounds = range.split('-');
  final int? start = int.tryParse(bounds.first);
  final int? end = int.tryParse(bounds.last);
  if (bounds.length > 2 ||
      start == null ||
      end == null ||
      start < 1 ||
      end < start) {
    throw FormatException('not a line range: "$range"', value);
  }
  return <int>[for (int line = start; line <= end; line++) line];
}
