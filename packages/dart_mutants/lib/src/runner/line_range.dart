/// A span of source lines, both ends inclusive and 1-based.
class LineRange {
  const LineRange(this.start, this.end);

  final int start;
  final int end;

  @override
  bool operator ==(Object other) =>
      other is LineRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => '$start-$end';
}
