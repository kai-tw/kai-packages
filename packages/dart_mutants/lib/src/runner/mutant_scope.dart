import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'line_range.dart';

/// The lines of the function, method or constructor whose code contains
/// [offset] — the unit coverage is asked about for a mutant there — or
/// `null` when there is none that coverage can speak for.
///
/// **Why the enclosing function and not the mutant's own line.** The VM
/// instruments calls and function entries, not statements. Measured:
/// `final String s = b ? 'x' : g();`, executed with `b` true, is reported at
/// **zero** hits — its only instrumented point is the call to `g`, which
/// that run skipped — and `return s;` below it is not reported at all. A
/// ternary swap on that line reads as uncovered while a test would catch
/// it. A function's entry is always instrumented, so "did any test enter
/// this function" is a question coverage answers truthfully.
///
/// `null`, meaning "run everything", for code outside any function body —
/// field and top-level initializers, default values, annotations — and for a
/// `const` constructor, whose initializers run at compile time where no
/// coverage sees them.
LineRange? executableScope(
  CompilationUnit unit,
  LineInfo lineInfo,
  int offset,
) {
  final _ScopeFinder finder = _ScopeFinder(offset);
  unit.accept(finder);
  final AstNode? scope = _declarationOf(finder.innermost);
  if (scope == null) {
    return null;
  }
  return LineRange(
    lineInfo.getLocation(scope.offset).lineNumber,
    lineInfo.getLocation(scope.end).lineNumber,
  );
}

/// The declaration a function body or constructor belongs to, widened to
/// include the name the VM records the function's entry against. `null`
/// for a const constructor.
AstNode? _declarationOf(AstNode? node) {
  final AstNode? owner = node is FunctionBody ? node.parent : node;
  if (owner is ConstructorDeclaration) {
    return owner.constKeyword == null ? owner : null;
  }
  if (owner is FunctionExpression && owner.parent is FunctionDeclaration) {
    return owner.parent;
  }
  return owner;
}

class _ScopeFinder extends GeneralizingAstVisitor<void> {
  _ScopeFinder(this.offset);

  final int offset;

  /// The innermost function body or constructor containing [offset].
  AstNode? innermost;

  @override
  void visitNode(AstNode node) {
    if (node.offset > offset || node.end <= offset) {
      return;
    }
    if (node is FunctionBody || node is ConstructorDeclaration) {
      innermost = node;
    }
    super.visitNode(node);
  }
}
