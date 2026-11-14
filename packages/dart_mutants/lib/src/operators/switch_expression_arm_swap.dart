import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../mutation_operator.dart';
import '../mutation_visitor.dart';

/// Replaces one switch-expression arm's result with an adjacent arm's
/// result, leaving every pattern and guard exactly where it was: `1 => a, 2
/// => b` proposes `1 => b, 2 => b` and, separately, `1 => a, 2 => a` — two
/// independent one-arm mutants per adjacent pair, not one mutant that
/// changes both arms at once. Each is applied and tested on its own, so a
/// test suite has to notice specifically *that* arm returning the wrong
/// value, not merely that the switch as a whole changed somewhere.
///
/// This targets the state -> text/value mapping idiom a switch expression is
/// most often used for (`return switch (status) { Loading() => 'loading...',
/// Done() => 'done', ... }`). A regex mutator has no representation for "the
/// switch expression's arms" at all — `dart_mutant`'s own operator reference
/// lists no switch-expression coverage, and a text-pattern approach for
/// "swap two arrow-separated values inside a switch" would be indistinguishable
/// from an ordinary map-literal `:` or a lambda `=>` without parsing the
/// construct, which is the same problem in different clothes.
///
/// Only adjacent pairs feed each other, not every pairing — an N-arm switch
/// gets 2(N-1) mutants rather than a combinatorial N*(N-1), which is enough
/// to exercise "this arm's result belongs to a different arm" without the
/// mutant count exploding on a long switch. A borrowed result is not
/// guaranteed to compile (the two arms' result types can differ enough that
/// the swap breaks the switch expression's own inferred type); as with every
/// operator in this package, that is the compile check's job to catch,
/// not this operator's.
class SwitchExpressionArmSwap extends MutationOperator {
  @override
  String get name => 'switch_expression_arm_swap';

  @override
  String get description =>
      "Replaces one switch-expression arm's result with an adjacent arm's, "
      'keeping every pattern and guard in place.';

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
  void visitSwitchExpression(SwitchExpression node) {
    final List<SwitchExpressionCase> cases = node.cases;
    for (int i = 0; i < cases.length - 1; i++) {
      _crossPropose(cases[i], cases[i + 1]);
    }
    super.visitSwitchExpression(node);
  }

  /// Proposes each of [first] and [second] independently taking on the
  /// other's result — two mutants, neither dependent on the other.
  void _crossPropose(SwitchExpressionCase first, SwitchExpressionCase second) {
    final Expression a = first.expression;
    final Expression b = second.expression;
    final String aText = source.substring(a.offset, a.end);
    final String bText = source.substring(b.offset, b.end);

    propose(
      offset: a.offset,
      length: a.end - a.offset,
      original: aText,
      replacement: bText,
      operatorName: 'switch_expression_arm_swap',
      description: "switch arm result '$aText' replaced with '$bText'",
    );
    propose(
      offset: b.offset,
      length: b.end - b.offset,
      original: bText,
      replacement: aText,
      operatorName: 'switch_expression_arm_swap',
      description: "switch arm result '$bText' replaced with '$aText'",
    );
  }
}
