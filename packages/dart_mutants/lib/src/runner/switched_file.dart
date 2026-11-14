import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import '../mutant.dart';

/// The environment variable a switched file reads to pick its one mutant.
/// Unset, empty or any id the file does not hold leaves it unmodified.
const String mutantIdVariable = 'DART_MUTANTS_ID';

/// The environment variable naming the file a switched file appends each
/// switch it reaches to, one id a line, the first time it reaches it. Unset
/// or empty, nothing is written. A switch a run never reaches holds a mutant
/// that run cannot detect: with the mutant on, the run executes exactly what
/// it executes with it off.
const String reachedVariable = 'DART_MUTANTS_REACHED';

/// One file with many mutants written into it at once, each behind a switch
/// read at run time — a mutant schema. Compiled once, it runs as any one of
/// its mutants, or as the unmodified code, by setting [mutantIdVariable].
///
/// [source] is that content; [switched] holds the ids it carries, and
/// [skipped] says why each other id was left out.
class SwitchedFile {
  const SwitchedFile(this.source, this.switched, this.skipped);

  final String source;
  final Set<int> switched;
  final Map<int, String> skipped;
}

/// Writes each of [mutants] (by id) into [source] behind a switch.
///
/// A mutant is switched at the smallest expression or statement holding it,
/// widened to the whole expression around it so flow analysis — a null check
/// promoting a variable later in the same expression — sees the mutated and
/// the unmodified code each in one piece:
///
/// ```dart
/// if (a > b) …        →  if ((_dmOn(3) ? (a >= b) : (a > b))) …
/// save();             →  if (_dmOn(7)) { ; } else { save(); }
/// ```
///
/// Several mutants at one node chain; a mutant inside another's node is
/// switched inside that node's unmodified branch. Only one mutant is ever on,
/// so each mutated branch holds that mutant alone.
///
/// Run with [reachedVariable] set, the file also says which switches the run
/// reached — see `SwitchedRunner.selectByReach`.
///
/// Left out, with the reason in [SwitchedFile.skipped]: a part file, which
/// cannot import `dart:io`; anything in a constant context, which cannot read
/// the environment; a whole local declaration, whose name a branch would hide;
/// a function's own body; and a bare `$name` in a string. Whether what is left
/// compiles is not checked here — see the runner, which asks the check.
SwitchedFile switchMutants(String source, Map<int, Mutant> mutants) {
  final CompilationUnit unit = parseString(
    content: source,
    throwIfDiagnostics: false,
  ).unit;
  if (unit.directives.any((Directive d) => d is PartOfDirective)) {
    return SwitchedFile(source, const <int>{}, <int, String>{
      for (final int id in mutants.keys) id: 'part file',
    });
  }
  final Map<int, String> skipped = <int, String>{};
  // Keyed by node identity: every mutant widened to one node chains there.
  final Map<AstNode, List<int>> atNode = <AstNode, List<int>>{};
  for (final MapEntry<int, Mutant> entry in mutants.entries) {
    final Mutant m = entry.value;
    final AstNode? node = _nodeAt(unit, m.offset, m.offset + m.length);
    final String? why = node == null
        ? 'not in an expression or statement'
        : _whyNot(node);
    if (why != null) {
      skipped[entry.key] = why;
    } else {
      atNode.putIfAbsent(node!, () => <int>[]).add(entry.key);
    }
  }
  if (atNode.isEmpty) {
    return SwitchedFile(source, const <int>{}, skipped);
  }
  return SwitchedFile(
    _Writer(source, atNode, mutants).write(_importOffset(unit)),
    <int>{for (final List<int> ids in atNode.values) ...ids},
    skipped,
  );
}

/// Renders the switched file: each node in [_atNode] replaced by its
/// switch, a nested one inside its container's unmodified branch.
class _Writer {
  _Writer(this._source, this._atNode, this._mutants)
    : _nodes = _atNode.keys.toList()..sort(_outerFirst);

  final String _source;
  final Map<AstNode, List<int>> _atNode;
  final Map<int, Mutant> _mutants;
  final List<AstNode> _nodes;

  /// The index into [_nodes] of the next node to switch.
  int _next = 0;

  /// Earlier first, and the outer of two that start together.
  static int _outerFirst(AstNode a, AstNode b) => a.offset == b.offset
      ? b.end.compareTo(a.end)
      : a.offset.compareTo(b.offset);

  /// The whole file, with the `dart:io` import at [importAt] and the switch
  /// itself at the end.
  String write(int importAt) {
    final StringBuffer out = StringBuffer()
      ..write(_source.substring(0, importAt))
      ..write("\nimport 'dart:async' as _dmAsync;\n")
      ..write("import 'dart:io' as _dmIo;\n");
    _next = 0;
    _span(out, importAt, _source.length);
    // The reached file is written from the root zone, so a test that swaps
    // the file system out with `IOOverrides` cannot swallow the write.
    out.write(
      '\n\nfinal int _dmId = int.tryParse('
      "_dmIo.Platform.environment['$mutantIdVariable'] ?? '') ?? -1;\n"
      'final String _dmReach = '
      "_dmIo.Platform.environment['$reachedVariable'] ?? '';\n"
      'final Set<int> _dmReached = <int>{};\n'
      'bool _dmOn(int id) {\n'
      '  if (_dmReach.isNotEmpty && _dmReached.add(id)) {\n'
      '    _dmAsync.Zone.root.run(\n'
      '      () => _dmIo.File(_dmReach).writeAsStringSync(\n'
      r"        '$id\n',"
      '\n'
      '        mode: _dmIo.FileMode.append,\n'
      '        flush: true,\n'
      '      ),\n'
      '    );\n'
      '  }\n'
      '  return _dmId == id;\n'
      '}\n',
    );
    return out.toString();
  }

  /// Writes [from]..[to] to [out], switching each node from [_next] on that
  /// ends inside it.
  void _span(StringBuffer out, int from, int to) {
    int at = from;
    while (_next < _nodes.length && _nodes[_next].end <= to) {
      final AstNode node = _nodes[_next++];
      out
        ..write(_source.substring(at, node.offset))
        ..write(_switch(node));
      at = node.end;
    }
    out.write(_source.substring(at, to));
  }

  /// [node] behind its mutants' switches, with the nodes nested in it
  /// switched in its unmodified branch.
  String _switch(AstNode node) {
    final StringBuffer original = StringBuffer();
    _span(original, node.offset, node.end);
    final String plain = _source.substring(node.offset, node.end);
    final List<int> ids = _atNode[node]!;
    if (node is Statement) {
      final String chain = ids
          .map((int id) => 'if (_dmOn($id)) { ${_mutated(plain, node, id)} }')
          .join(' else ');
      return '$chain else { $original }';
    }
    final String chain = ids
        .map((int id) => '_dmOn($id) ? (${_mutated(plain, node, id)}) : ')
        .join();
    return '($chain($original))';
  }

  String _mutated(String plain, AstNode node, int id) {
    final Mutant m = _mutants[id]!;
    final int start = m.offset - node.offset;
    return plain.replaceRange(start, start + m.length, m.replacement);
  }
}

/// The node a mutant spanning [start]..[end] is switched at, before
/// [_whyNot] has had its say.
AstNode? _nodeAt(CompilationUnit unit, int start, int end) {
  final _Finder finder = _Finder(start, end);
  unit.accept(finder);
  final AstNode? node = finder.best;
  if (node is ExpressionStatement &&
      !(node.offset == start && node.end == end)) {
    return _widened(node.expression);
  }
  return node is Expression ? _widened(node) : node;
}

/// [node] widened to the whole expression around it, short of a named
/// argument, whose name a conditional cannot hold.
Expression _widened(Expression node) {
  Expression widest = node;
  for (
    AstNode? parent = widest.parent;
    parent is Expression && parent is! NamedExpression;
    parent = widest.parent
  ) {
    widest = parent;
  }
  return widest;
}

/// Why [node] cannot be switched, or `null` when it can.
String? _whyNot(AstNode node) {
  final String? shape = node is Expression
      ? _expressionProblem(node)
      : _statementProblem(node);
  if (shape != null) {
    return shape;
  }
  return _constant(node) ? 'constant context' : null;
}

String? _expressionProblem(Expression node) {
  final AstNode? parent = node.parent;
  return parent is InterpolationExpression && parent.rightBracket == null
      ? 'bare interpolation'
      : null;
}

String? _statementProblem(AstNode node) {
  if (node is VariableDeclarationStatement ||
      node is FunctionDeclarationStatement) {
    return 'local declaration';
  }
  // A function body, or the block of a `try`, `catch` or `finally`.
  return _holdsAnyStatement(node.parent)
      ? null
      : 'statement that must stay a block';
}

/// Whether [parent] takes any statement where it holds one, so an `if` can
/// stand in for it.
bool _holdsAnyStatement(AstNode? parent) =>
    parent is Block ||
    parent is SwitchMember ||
    parent is IfStatement ||
    parent is ForStatement ||
    parent is WhileStatement ||
    parent is DoStatement ||
    parent is LabeledStatement;

/// Whether [node] sits where Dart needs a constant.
bool _constant(AstNode node) {
  for (AstNode? n = node; n != null; n = n.parent) {
    if (_markedConstant(n) || _alwaysConstant(n)) {
      return true;
    }
  }
  return false;
}

/// A node made constant by a `const` keyword, its own or its constructor's.
bool _markedConstant(AstNode n) => switch (n) {
  InstanceCreationExpression() => n.isConst,
  TypedLiteral() => n.constKeyword != null,
  VariableDeclarationList() => n.isConst,
  ConstructorInitializer() =>
    (n.parent as ConstructorDeclaration).constKeyword != null,
  _ => false,
};

/// A node whose expressions are constant wherever it appears.
bool _alwaysConstant(AstNode n) =>
    n is Annotation ||
    n is SwitchCase ||
    n is GuardedPattern ||
    n is FormalParameter ||
    n is EnumConstantDeclaration;

/// Where the `dart:io` import goes: after the last `library`, `import` or
/// `export` directive, which every switch point follows.
int _importOffset(CompilationUnit unit) {
  int at = 0;
  for (final Directive d in unit.directives) {
    if (d is LibraryDirective || d is ImportDirective || d is ExportDirective) {
      at = d.end;
    }
  }
  return at;
}

/// The innermost expression or statement covering [start]..[end].
class _Finder extends GeneralizingAstVisitor<void> {
  _Finder(this.start, this.end);

  final int start;
  final int end;
  AstNode? best;

  @override
  void visitNode(AstNode node) {
    if (node.offset > start || node.end < end) {
      return;
    }
    if (node is Expression || node is Statement) {
      best = node;
    }
    super.visitNode(node);
  }
}
