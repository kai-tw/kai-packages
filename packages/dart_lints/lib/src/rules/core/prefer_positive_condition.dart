import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../../lint_rule_base.dart';

/// Warns when a branch with **two** arms tests a negated condition.
///
/// `a != b ? x : y` and `if (!ready) { … } else { … }` ask the reader to hold
/// an inversion while they read both arms, and the arm they attach to the
/// comparison as written is the wrong one. Inverting the condition and
/// swapping the arms costs nothing and removes the inversion.
///
/// A single-armed form is not this shape — an early-return guard
/// (`if (!ready) return;`) has no second arm to mis-attach — and neither is an
/// `else if` chain, where the arms are a sequence rather than a pair.
///
/// `!= null` is excluded: it is the preferred spelling of a null check, and
/// `== null` with the arms swapped reads worse than what it replaces.
class PreferPositiveCondition extends LintRule {
  @override
  String get name => 'prefer_positive_condition';

  @override
  String get description =>
      'Put a two-armed condition in positive form. A negated condition with '
      'both arms present reads as its own opposite; invert it and swap the '
      'arms. Null checks (`!= null`) and single-armed guards are excluded.';

  @override
  LintVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(filePath, lineInfo, source);
}

class _Visitor extends LintVisitor {
  _Visitor(super.filePath, super.lineInfo, super.source);

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    _reportIfNegated(node.condition, 'ternary');
    super.visitConditionalExpression(node);
  }

  @override
  void visitIfStatement(IfStatement node) {
    final Statement? elseStatement = node.elseStatement;
    if (elseStatement != null && elseStatement is! IfStatement) {
      _reportIfNegated(node.expression, 'if/else');
    }
    super.visitIfStatement(node);
  }

  void _reportIfNegated(Expression condition, String shape) {
    if (!_isNegated(condition)) {
      return;
    }
    report(
      ruleName: 'prefer_positive_condition',
      message:
          'Negated condition with both arms present ($shape). Invert the '
          'condition and swap the arms — as written, the reader attaches the '
          'first arm to the comparison they just read.',
      offset: condition.offset,
    );
  }

  bool _isNegated(Expression condition) {
    final Expression expression = condition.unParenthesized;
    if (expression is PrefixExpression) {
      return expression.operator.lexeme == '!';
    }
    if (expression is IsExpression) {
      return expression.notOperator != null;
    }
    if (expression is BinaryExpression && expression.operator.lexeme == '!=') {
      return !_isNull(expression.leftOperand) &&
          !_isNull(expression.rightOperand);
    }
    return false;
  }

  bool _isNull(Expression expression) =>
      expression.unParenthesized is NullLiteral;
}
