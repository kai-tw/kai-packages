import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../mutation_operator.dart';
import '../mutation_visitor.dart';

/// Deletes one statement, replacing it with an empty `;`.
///
/// This asks a question none of the expression-level operators can. Swapping
/// a ternary's branches or a comparison's boundary asks "is this expression
/// pinned?" — it presumes the line runs and something depends on which way it
/// went. Deleting a statement asks the prior question: **does any test assert
/// that this line's effect happened at all?** A guard like
/// `if (mounted) { setState(...) }` contains no ternary, no `??`, and no
/// comparison, so every other operator in this package walks straight past
/// it; delete the `setState(...)` and a suite that never asserted the
/// resulting rebuild stays green.
///
/// Only a statement whose parent is a [Block] is proposed. That is the
/// standard definition of statement deletion, and in this codebase it is very
/// nearly total coverage rather than a compromise: the `lints` ruleset these
/// projects use enforces braces on flow-control bodies, so a statement that
/// runs conditionally is a block child too. A brace-less `if (x) return;`
/// would be missed, and is the one known gap.
///
/// Replacing with `;` rather than cutting the text out keeps the edit a pure
/// replacement — an empty statement is syntactically legal anywhere a
/// statement was, so the mutant always parses, and whether it *compiles* is
/// left to the one thing that can actually answer that. Deleting a `return`
/// from a value-returning function, or a variable declaration something later
/// reads, produces a mutant the compile check rejects; that costs one
/// compile check and scores nothing, which is the same bargain
/// `NullCoalescingDeletion` already makes deliberately.
///
/// Deleting a statement can also produce an *equivalent* mutant — a trailing
/// bare `return;` in a void function is the common one, since falling off the
/// end does the same thing. Recognising those needs flow analysis this
/// operator does not do, so they surface as survivors for a person to dismiss
/// rather than being filtered out on a guess.
class StatementDeletion extends MutationOperator {
  @override
  String get name => 'statement_deletion';

  @override
  String get description =>
      'Deletes one statement, asking whether any test asserts its effect '
      'happened at all.';

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
  void visitBlock(Block node) {
    for (final Statement statement in node.statements) {
      // An already-empty statement has nothing to delete; proposing `;` -> `;`
      // would be a no-op mutant that the test command scores as "undetected"
      // forever, since no test can possibly fail on it.
      if (statement is EmptyStatement) {
        continue;
      }
      final String original = source.substring(statement.offset, statement.end);
      propose(
        offset: statement.offset,
        length: statement.length,
        original: original,
        replacement: ';',
        operatorName: 'statement_deletion',
        description: "deleted '${_summarise(original)}'",
      );
    }
    super.visitBlock(node);
  }
}

/// Collapses [statement] to a single short line for a report a person reads.
/// A deleted statement can be an entire multi-line block; printing it whole
/// would bury the one-per-line undetected-mutant list it appears in.
String _summarise(String statement) {
  final String flattened = statement.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flattened.length <= 60
      ? flattened
      : '${flattened.substring(0, 57)}...';
}
