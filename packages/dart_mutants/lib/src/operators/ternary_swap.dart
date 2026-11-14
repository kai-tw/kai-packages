import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../mutation_operator.dart';
import '../mutation_visitor.dart';

/// Swaps a ternary's two branches: `a ? b : c` becomes `a ? c : b`.
///
/// This is the mutation a regex-based mutator cannot express at all — there
/// is no text pattern that means "the ternary operator", only `?` and `:`,
/// both of which appear in contexts that have nothing to do with a
/// conditional expression (null-aware access, named-parameter syntax, a map
/// literal). An AST walk sees the real node; a regex cannot.
///
/// A swapped ternary is not guaranteed to compile — the two branches can
/// have incompatible static types even though the swap is syntactically
/// legal (`isLoading ? null : count` swapped is `count : null`, fine either
/// way here, but `isLoading ? 0 : 'done'` swapped needs the surrounding
/// context to accept either type in either position, which it often will
/// not). That is expected and is exactly what the compile check this
/// package always runs before counting a mutant exists to catch — this
/// operator does not try to predict it.
class TernarySwap extends MutationOperator {
  @override
  String get name => 'ternary_swap';

  @override
  String get description =>
      "Swaps a ternary's branches: `a ? b : c` becomes `a ? c : b`.";

  @override
  MutationVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(filePath, lineInfo, source);
}

class _Visitor extends MutationVisitor {
  _Visitor(super.filePath, super.lineInfo, super.source);

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    final Expression thenExpr = node.thenExpression;
    final Expression elseExpr = node.elseExpression;
    final String thenText = source.substring(thenExpr.offset, thenExpr.end);
    final String elseText = source.substring(elseExpr.offset, elseExpr.end);

    propose(
      offset: thenExpr.offset,
      length: elseExpr.end - thenExpr.offset,
      original: source.substring(thenExpr.offset, elseExpr.end),
      replacement: '$elseText : $thenText',
      operatorName: 'ternary_swap',
      description: "ternary branches swapped: '$thenText' <-> '$elseText'",
    );

    super.visitConditionalExpression(node);
  }
}
