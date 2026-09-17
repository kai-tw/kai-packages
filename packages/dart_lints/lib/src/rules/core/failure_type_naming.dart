import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../config/dart_lints_config_exception.dart';
import '../../lint_rule_base.dart';

/// Requires a failure type's name and its type to say the same thing.
///
/// `Error` and `Exception` are not interchangeable words in Dart: an `Error`
/// is a programming fault nobody should catch, an `Exception` a condition a
/// caller is expected to handle. A name that claims one while the type is the
/// other sends the reader to the wrong handling. So:
///
/// - a subtype of `Error` ends in `Error`, and a class ending in `Error` is a
///   subtype of `Error`;
/// - an implementation of `Exception` ends in the project's failure word, and a
///   class ending in that word, or in `Exception`, implements `Exception`.
///
/// The failure word is `Exception` or `Failure` — one per project, since two
/// words for one kind of type is a second vocabulary to keep in step.
///
/// **Bad** (failure word `Exception`):
/// ```dart
/// class ParseError implements Exception {}
/// class InvariantBroken extends Error {}
/// class QuotaExceeded implements Exception {}
/// ```
///
/// **Good:**
/// ```dart
/// class ParseException implements Exception {}
/// class InvariantError extends Error {}
/// ```
class FailureTypeNaming extends ResolvedLintRule {
  FailureTypeNaming({String? failureWord, List<String>? exemptSubtypesOf})
    : failureWord = failureWord ?? 'Exception',
      exemptSubtypesOf = exemptSubtypesOf ?? const <String>[] {
    if (!_allowedWords.contains(this.failureWord)) {
      throw DartLintsConfigException(
        'rule "failure_type_naming": failureWord must be one of '
        '${_allowedWords.join(', ')}, not "${this.failureWord}"',
      );
    }
  }

  static const List<String> _allowedWords = <String>['Exception', 'Failure'];

  /// The word an `Exception` implementation's name ends in.
  final String failureWord;

  /// Types, by name, whose subtypes are named by another scheme and are not
  /// checked — a lint package whose rule classes are named after the rules
  /// they implement, say `AvoidCatchingError`, lists its rule base types.
  final List<String> exemptSubtypesOf;

  @override
  String get name => 'failure_type_naming';

  @override
  String get description =>
      'Error subtypes end in Error; Exception implementations end in '
      '$failureWord; and each such name is true of its type.';

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(filePath, resolvedUnit, failureWord, exemptSubtypesOf);
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(
    super.filePath,
    super.resolvedUnit,
    this.failureWord,
    this.exemptSubtypesOf,
  );

  final String failureWord;
  final List<String> exemptSubtypesOf;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final ClassElement? element = node.declaredFragment?.element;
    if (element != null && !_exempt(element)) {
      final String? problem = _problem(node.name.lexeme, element);
      if (problem != null) {
        report(
          ruleName: 'failure_type_naming',
          message: problem,
          offset: node.name.offset,
        );
      }
    }
    super.visitClassDeclaration(node);
  }

  String? _problem(String name, ClassElement element) {
    final bool isError = _extendsCore(element, 'Error');
    final bool isException = _extendsCore(element, 'Exception');
    if (isError) {
      return name.endsWith('Error')
          ? null
          : "$name extends Error, so its name ends in 'Error'. An Error is a "
                'programming fault, and the name is what tells a reader not to '
                'catch it.';
    }
    if (isException) {
      return name.endsWith(failureWord)
          ? null
          : '$name implements Exception, so its name ends in '
                "'$failureWord', this project's word for a failure a caller "
                'handles.';
    }
    return _claimedIdentity(name);
  }

  /// What a name that is neither an `Error` nor an `Exception` wrongly claims.
  String? _claimedIdentity(String name) {
    for (final String word in <String>{'Error', 'Exception', failureWord}) {
      if (name.endsWith(word)) {
        final String type = word == 'Error' ? 'Error' : 'Exception';
        return "$name ends in '$word' but is not a subtype of $type. Make it "
            'one, or rename it so the name does not claim what the type is '
            'not.';
      }
    }
    return null;
  }

  bool _exempt(ClassElement element) => element.allSupertypes.any(
    (InterfaceType t) => exemptSubtypesOf.contains(t.element.name),
  );

  /// Whether [element] is a subtype of `dart:core`'s [typeName].
  static bool _extendsCore(ClassElement element, String typeName) =>
      element.allSupertypes.any(
        (InterfaceType t) =>
            t.element.name == typeName && t.element.library.isDartCore,
      );
}
