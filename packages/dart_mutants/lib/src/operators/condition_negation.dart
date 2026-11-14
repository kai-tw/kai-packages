import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../mutation_operator.dart';
import '../mutation_visitor.dart';

/// Negates a branch condition: `if (x)` -> `if (!(x))`.
///
/// This covers the guard that has no operator in it at all. `if (mounted)`,
/// `if (isLoading)`, `if (items.isEmpty)` — a condition that is a single bare
/// truth value offers nothing for the comparison or null-coalescing operators
/// to grab, yet it decides whether a whole block runs. Negation is the only
/// mutation that reaches it, and the question it asks is direct: does any
/// test pin which side of this guard it lands on, or do all of them happen to
/// take the same branch?
///
/// A condition whose top level is already a comparison is skipped, because
/// `RelationalOperatorReplacement` covers it: negating `a < b` gives
/// `!(a < b)`, which behaves as `a >= b` — a mutant that operator already
/// proposes.
///
/// The reason to skip is the score, not the runtime. Two mutants that behave
/// identically live or die together, so a surviving one would be counted
/// twice in the same file's denominator — one weakness reported as two, in a
/// number a caller checks merges on. The wasted analyze-and-test cycle is the
/// lesser cost.
///
/// The equivalence is exact for integral operands and breaks on `double`:
/// at `double.nan`, `!(a < b)` is true where `a >= b` is false. So this skip
/// gives up one genuinely distinct mutant on every floating-point comparison
/// — a real loss, not a free one.
///
/// Be precise about why that is acceptable, because the obvious version of
/// the claim is false. It is NOT that double comparisons are rare here; this
/// runs against Flutter code, where they are everywhere — offsets, extents,
/// scroll positions, animation values. The claim that actually holds is
/// narrower: NaN rarely *reaches* a live comparison. That is the one to
/// re-check before pointing this at numeric code where NaN is a real input
/// rather than a bug, and the one that would make this skip wrong.
///
/// Only the top level is checked — `if (a < b && c)` still gets negated,
/// since inverting the whole conjunction is not something any per-operator
/// replacement produces.
///
/// An if-case (`if (x case int n)`) is skipped entirely. Its `expression` is
/// the value being matched, not a boolean, so `!(x)` there is a type error
/// the compile check would reject on every occurrence — a guaranteed-
/// invalid mutant is pure cost, and unlike the speculative ones this package
/// does propose, it has no case in which it survives.
///
/// The parentheses are not optional. `!` binds tighter than nearly
/// everything, so `!x == y` parses as `(!x) == y` — negating the wrong thing
/// while still compiling, which is the one failure mode a mutation tool must
/// never have. Wrapping is what makes the edit mean what it says.
class ConditionNegation extends MutationOperator {
  @override
  String get name => 'condition_negation';

  @override
  String get description =>
      'Negates a branch condition: `if (x)` -> `if (!(x))`.';

  @override
  MutationVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(filePath, lineInfo, source);
}

/// Comparisons already covered by `RelationalOperatorReplacement` — negating
/// one of these at the top level re-proposes a mutant that operator makes.
const Set<String> _relationalOperators = <String>{
  '<',
  '<=',
  '>',
  '>=',
  '==',
  '!=',
};

class _Visitor extends MutationVisitor {
  _Visitor(super.filePath, super.lineInfo, super.source);

  @override
  void visitIfStatement(IfStatement node) {
    if (node.caseClause == null) {
      _negate(node.expression);
    }
    super.visitIfStatement(node);
  }

  @override
  void visitIfElement(IfElement node) {
    if (node.caseClause == null) {
      _negate(node.expression);
    }
    super.visitIfElement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _negate(node.condition);
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    _negate(node.condition);
    super.visitDoStatement(node);
  }

  void _negate(Expression condition) {
    if (condition is BinaryExpression &&
        _relationalOperators.contains(condition.operator.lexeme)) {
      return;
    }
    final String original = source.substring(condition.offset, condition.end);
    propose(
      offset: condition.offset,
      length: condition.length,
      original: original,
      replacement: '!($original)',
      operatorName: 'condition_negation',
      description: "'$original' -> '!($original)'",
    );
  }
}
