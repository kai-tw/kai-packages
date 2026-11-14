import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../mutation_operator.dart';
import '../mutation_visitor.dart';

/// Replaces an arithmetic operator with its inverse: `+` <-> `-`,
/// `*` <-> `/`.
///
/// The off-by-one and the inverted-sign are the classic arithmetic bugs, and
/// an index, an offset, or a running total computed the wrong way is exactly
/// the kind of error a test suite can walk past while asserting only that a
/// result "is not null" or that a list "is not empty". This is the operator
/// that makes such an assertion admit it is not measuring the number.
///
/// Only the inverse is proposed per operator, following the same reduced-set
/// reasoning documented on `RelationalOperatorReplacement`: `+` -> `*` is
/// usually either caught by everything or equivalent at the identity values,
/// and adds a full analyze-and-test cycle for signal the inverse already
/// gives.
///
/// Two type-level facts make a real share of these mutants unusable, and both
/// are left to the compile check rather than guessed at here, because
/// the AST alone genuinely cannot tell:
///
/// - `+` is also `String` and `List` concatenation. `'a' + 'b'` mutates to
///   `'a' - 'b'`, which does not compile — there is no `-` on `String`.
/// - `/` on two `int`s evaluates to `double`, so `int n = a * b` mutating to
///   `a / b` is a type error even though both operands are numbers. (`~/` is
///   the int-preserving one, and is deliberately not offered as a `*`
///   replacement: it would compile far more often while being a much weaker
///   mutation, since `a ~/ b` and `a * b` differ so wildly that any assertion
///   on the value catches it.)
///
/// Both are proposed anyway and rejected by the check at one analyze each,
/// which costs a little and — critically — scores nothing. A mutant that
/// fails to compile is `invalid`, never `detected`; it cannot inflate a
/// score, only the runtime.
class ArithmeticOperatorReplacement extends MutationOperator {
  @override
  String get name => 'arithmetic_operator_replacement';

  @override
  String get description =>
      'Replaces an arithmetic operator with its inverse: `+` <-> `-`, '
      '`*` <-> `/`.';

  @override
  MutationVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(filePath, lineInfo, source);
}

const Map<String, String> _replacements = <String, String>{
  '+': '-',
  '-': '+',
  '*': '/',
  '/': '*',
};

class _Visitor extends MutationVisitor {
  _Visitor(super.filePath, super.lineInfo, super.source);

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final String original = node.operator.lexeme;
    final String? replacement = _replacements[original];
    if (replacement != null) {
      propose(
        offset: node.operator.offset,
        length: node.operator.length,
        original: original,
        replacement: replacement,
        operatorName: 'arithmetic_operator_replacement',
        description: "'$original' -> '$replacement'",
      );
    }
    super.visitBinaryExpression(node);
  }
}
