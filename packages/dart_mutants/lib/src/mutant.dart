/// One candidate mutation: replace [length] characters starting at [offset]
/// in [filePath] with [replacement].
///
/// A `Mutant` is a proposal, not a verdict. Before it counts toward a score
/// it must survive the compile check (an AST-legal edit is not
/// guaranteed to be a type-legal one — swapping two ternary branches of
/// different static types is syntactically fine and a compile error), and
/// only then does the real test command decide whether it was caught.
class Mutant {
  const Mutant({
    required this.filePath,
    required this.offset,
    required this.length,
    required this.line,
    required this.column,
    required this.original,
    required this.replacement,
    required this.operatorName,
    required this.description,
  });

  final String filePath;
  final int offset;
  final int length;

  /// 1-based, matching `dart analyze`'s own report locations.
  final int line;
  final int column;

  /// The exact source text being replaced — kept so a mutant can be applied
  /// and reverted without re-reading the file, and so a report can show the
  /// before/after without re-deriving it from offsets.
  final String original;
  final String replacement;

  /// Which [MutationOperator] produced this, e.g. `'ternary_swap'`. Stable
  /// and machine-readable — a report groups or filters by it.
  final String operatorName;

  /// A one-line, human-readable summary of what changed, for a report a
  /// person reads directly without cross-referencing offsets against source.
  final String description;

  /// Applies this mutant to [source], which must be the same content the
  /// mutant was generated from — an offset computed against one version of a
  /// file is meaningless against another.
  String applyTo(String source) {
    return source.replaceRange(offset, offset + length, replacement);
  }
}
