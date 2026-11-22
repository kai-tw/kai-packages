import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';

import '../../lint_rule_base.dart';

/// Ties a yes-or-no question to its name, in both directions.
///
/// A name that asks a question (`isEmpty`, `canPop`, `hasError`) belongs to a
/// getter that answers it with a boolean; a getter that answers with a
/// boolean asks its question with one of those words. Three shapes are
/// reported:
///
/// - a boolean getter whose name doesn't start with a question word —
///   `bool get aborted`, which reads like a verb or a field;
/// - a getter named as a question that returns something else —
///   `int get isCount`;
/// - a method named as a question that takes nothing — `bool isReady()`,
///   which has nothing to compute from but `this` and should be a getter.
///
/// "Boolean" means `bool` or `Future<bool>`, nullable or not: an async
/// yes-or-no is still a yes-or-no, and `null` is the answer "unknown".
///
/// Left alone:
///
/// - a method with parameters (`isAtLeast(other)`) or type parameters, which
///   can't be a getter;
/// - a field, local variable or parameter — a `bool` field is a getter from
///   the outside, but widget parameters follow Flutter's own `enabled` and
///   `dense`;
/// - an `@override`, whose name was chosen where it is declared;
/// - a declaration without a return type, which this rule can't classify.
class BoolGetterNaming extends LintRule {
  BoolGetterNaming({List<String>? prefixes})
    : prefixes = prefixes ?? defaultPrefixes;

  static const List<String> defaultPrefixes = <String>['is', 'can', 'has'];

  /// The words a boolean getter's name may start with.
  final List<String> prefixes;

  @override
  String get name => 'bool_getter_naming';

  @override
  String get description =>
      'Name a boolean getter as a question (${prefixes.join('/')}Xxx), and '
      'use those names only for boolean getters. A method named that way '
      'with no parameters should be a getter.';

  @override
  LintVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(filePath, lineInfo, source, prefixes);
}

class _Visitor extends LintVisitor {
  _Visitor(super.filePath, super.lineInfo, super.source, this.prefixes);

  final List<String> prefixes;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!node.isSetter && !node.isOperator && !_isOverride(node.metadata)) {
      _check(
        nameToken: node.name,
        returnType: node.returnType,
        isGetter: node.isGetter,
        isBareCall:
            (node.parameters?.parameters.isEmpty ?? false) &&
            node.typeParameters == null,
      );
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // A local function can't be a getter, so only top-level ones count.
    if (node.parent is CompilationUnit &&
        !node.isSetter &&
        !_isOverride(node.metadata)) {
      final FunctionExpression function = node.functionExpression;
      _check(
        nameToken: node.name,
        returnType: node.returnType,
        isGetter: node.isGetter,
        isBareCall:
            (function.parameters?.parameters.isEmpty ?? false) &&
            function.typeParameters == null,
      );
    }
    super.visitFunctionDeclaration(node);
  }

  void _check({
    required Token nameToken,
    required TypeAnnotation? returnType,
    required bool isGetter,
    required bool isBareCall,
  }) {
    final String name = nameToken.lexeme;
    if (isGetter) {
      _checkGetter(nameToken, returnType);
    } else if (isBareCall && _isQuestion(name)) {
      _report(
        nameToken,
        '`$name()` takes no arguments and is named as a yes-or-no question, '
        'so it should be a boolean getter: `get $name`.',
      );
    }
  }

  void _checkGetter(Token nameToken, TypeAnnotation? returnType) {
    if (returnType == null) {
      return;
    }
    final String name = nameToken.lexeme;
    final bool isQuestion = _isQuestion(name);
    final bool isBoolean = _isBoolean(returnType);
    if (isBoolean && !isQuestion) {
      _report(
        nameToken,
        'Boolean getter `$name` should be named as a question: start it '
        'with ${_prefixList()}.',
      );
    } else if (!isBoolean && isQuestion) {
      _report(
        nameToken,
        '`$name` is named as a yes-or-no question but returns '
        '`${returnType.toSource()}`. Return `bool`, or rename it.',
      );
    }
  }

  void _report(Token nameToken, String message) => report(
    ruleName: 'bool_getter_naming',
    message: message,
    offset: nameToken.offset,
  );

  String _prefixList() => prefixes.map((String p) => '`$p`').join(', ');

  /// Whether [name] starts with a question word followed by a capital:
  /// `isEmpty` and `_canPop` do, `issue` and `cancel` don't.
  bool _isQuestion(String name) {
    final String bare = name.startsWith('_') ? name.substring(1) : name;
    for (final String prefix in prefixes) {
      if (bare.length > prefix.length && bare.startsWith(prefix)) {
        final String next = bare[prefix.length];
        if (next != next.toLowerCase()) {
          return true;
        }
      }
    }
    return false;
  }

  /// Whether [type] is `bool` or `Future<bool>`, nullable or not.
  bool _isBoolean(TypeAnnotation type) {
    if (_isBool(type)) {
      return true;
    }
    final TypeAnnotation? awaited = _futureArgument(type);
    return awaited != null && _isBool(awaited);
  }

  /// Whether [type] is `bool` or `bool?`, written without an import prefix.
  bool _isBool(TypeAnnotation type) =>
      type is NamedType &&
      type.importPrefix == null &&
      type.name.lexeme == 'bool' &&
      type.typeArguments == null;

  /// The `T` in `Future<T>`, or `null` when [type] isn't written that way.
  TypeAnnotation? _futureArgument(TypeAnnotation type) {
    if (type is! NamedType ||
        type.importPrefix != null ||
        type.name.lexeme != 'Future') {
      return null;
    }
    final List<TypeAnnotation> arguments =
        type.typeArguments?.arguments ?? <TypeAnnotation>[];
    return arguments.length == 1 ? arguments.single : null;
  }

  bool _isOverride(NodeList<Annotation> metadata) =>
      metadata.any((Annotation a) => a.name.name == 'override');
}
