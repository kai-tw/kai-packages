import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../mutation_operator.dart';
import '../mutation_visitor.dart';

/// Deletes one side of a `??`: `a ?? b` proposes both `a` alone and `b`
/// alone, each its own mutant.
///
/// `b` alone tests whether any test actually exercises `a` being null — drop
/// the fallback's *reason to exist* and see if anything notices. `a` alone
/// tests the opposite: whether a test exercises the fallback actually being
/// reached. Both are offered per site because which one compiles depends on
/// nullability this operator does not itself analyze — `a`'s static type is
/// very often nullable exactly because it is the left side of a `??`, so `a`
/// alone frequently fails the surrounding context's non-null requirement and
/// gets discarded by the compile check. That is expected; proposing it
/// anyway costs nothing but one compile check, and `b` alone is usually the one
/// that survives to actually run.
///
/// This is a blind spot for a regex-based mutator for the same reason the
/// ternary is: `??` is two characters that also appear, unrelated, as `?`
/// (nullable type suffix, conditional expression, named-parameter default)
/// followed independently by whatever comes next. Nothing about matching
/// those two characters as text tells you where the left operand ends.
class NullCoalescingDeletion extends MutationOperator {
  @override
  String get name => 'null_coalescing_deletion';

  @override
  String get description =>
      'Deletes one side of `a ?? b`, proposing `a` alone and `b` alone.';

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
  void visitBinaryExpression(BinaryExpression node) {
    if (node.operator.lexeme == '??') {
      final Expression left = node.leftOperand;
      final Expression right = node.rightOperand;
      final String leftText = source.substring(left.offset, left.end);
      final String rightText = source.substring(right.offset, right.end);
      final String wholeText = source.substring(node.offset, node.end);

      propose(
        offset: node.offset,
        length: node.length,
        original: wholeText,
        replacement: rightText,
        operatorName: 'null_coalescing_deletion',
        description: "'$wholeText' -> '$rightText' (fallback only)",
      );
      propose(
        offset: node.offset,
        length: node.length,
        original: wholeText,
        replacement: leftText,
        operatorName: 'null_coalescing_deletion',
        description: "'$wholeText' -> '$leftText' (left only, no fallback)",
      );
    }
    super.visitBinaryExpression(node);
  }
}
