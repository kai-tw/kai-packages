import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../lint_rule_base.dart';
import 'name_words.dart';

/// Requires every direct subtype of a `sealed` class to carry its family's
/// name: the base's category words in front, the base's kind word at the end.
///
/// A sealed family is closed, and a reader meeting one member anywhere — a
/// `switch` arm, a log line, a stack frame — should be able to tell which
/// family it belongs to from its name alone. The base `ConnectionFailure`
/// reads as category `Connection`, kind `Failure` (see [NameWords]); so a
/// member reads `Connection<case>Failure`.
///
/// A base with a single word (`Failure`) has no category, and only the kind
/// is required. The member must add at least one word: a subtype named
/// exactly like its base is not a case of it.
///
/// **Bad:**
/// ```dart
/// sealed class ConnectionFailure {}
/// class TimeoutFailure extends ConnectionFailure {}
/// class ConnectionTimeout extends ConnectionFailure {}
/// ```
///
/// **Good:**
/// ```dart
/// sealed class ConnectionFailure {}
/// class ConnectionTimeoutFailure extends ConnectionFailure {}
/// ```
class SealedFamilyNaming extends ResolvedLintRule {
  @override
  String get name => 'sealed_family_naming';

  @override
  String get description =>
      'A direct subtype of a sealed class starts with its category words and '
      'ends with its kind word.';

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(filePath, resolvedUnit);
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(super.filePath, super.resolvedUnit);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final ClassElement? element = node.declaredFragment?.element;
    if (element != null) {
      _check(node, element);
    }
    super.visitClassDeclaration(node);
  }

  void _check(ClassDeclaration node, ClassElement element) {
    final NameWords member = NameWords(node.name.lexeme);
    for (final InterfaceType parent in _directSupertypes(element)) {
      final InterfaceElement base = parent.element;
      if (base is! ClassElement || !base.isSealed) {
        continue;
      }
      final NameWords family = NameWords(base.name ?? '');
      if (_belongs(member, family)) {
        continue;
      }
      report(
        ruleName: 'sealed_family_naming',
        message:
            '${member.name} is a direct subtype of sealed ${family.name}, so '
            "its name starts with '${family.category}' and ends with "
            "'${family.kind}', with the case in between: "
            '${family.category}<Case>${family.kind}. A member named '
            'otherwise cannot be traced to its family at a switch arm, a log '
            'line or a stack frame.',
        offset: node.name.offset,
      );
      // One report per class: a class under two sealed bases that fits
      // neither has one naming problem to solve, not two.
      return;
    }
  }

  /// Word by word, not character by character: `ConnectionsTimeoutFailure`
  /// does not start with the category `Connection`.
  static bool _belongs(NameWords member, NameWords family) {
    final int categoryLength = family.words.length - 1;
    if (member.kind != family.kind ||
        member.words.length <= family.words.length) {
      return false;
    }
    for (int i = 0; i < categoryLength; i++) {
      if (member.words[i] != family.words[i]) {
        return false;
      }
    }
    return true;
  }

  static Iterable<InterfaceType> _directSupertypes(ClassElement element) =>
      <InterfaceType>[
        ?element.supertype,
        ...element.interfaces,
        ...element.mixins,
      ];
}
