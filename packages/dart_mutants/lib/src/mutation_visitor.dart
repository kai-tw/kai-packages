import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'mutant.dart';
import 'mutation_operator.dart';

/// Walks one file's AST collecting the [Mutant]s one [MutationOperator]
/// proposes for it.
abstract class MutationVisitor extends RecursiveAstVisitor<void> {
  MutationVisitor(this.filePath, this.lineInfo, this.source);

  final String filePath;
  final LineInfo lineInfo;
  final String source;
  final List<Mutant> mutants = <Mutant>[];

  /// Builds a [Mutant] at [offset]/[length], deriving [Mutant.line] and
  /// [Mutant.column] from [lineInfo] so no operator has to do that itself.
  ///
  /// A [replacement] that is the very text it replaces is dropped: the code
  /// would be byte-identical, so no test could ever catch it, and it would
  /// sit among the survivors as a hole that is not there. Swapping two
  /// switch arms with one result, or a ternary's two equal branches, is how
  /// operators get there.
  void propose({
    required int offset,
    required int length,
    required String original,
    required String replacement,
    required String operatorName,
    required String description,
  }) {
    if (source.substring(offset, offset + length) == replacement) {
      return;
    }
    final CharacterLocation location = lineInfo.getLocation(offset);
    mutants.add(
      Mutant(
        filePath: filePath,
        offset: offset,
        length: length,
        line: location.lineNumber,
        column: location.columnNumber,
        original: original,
        replacement: replacement,
        operatorName: operatorName,
        description: description,
      ),
    );
  }
}
