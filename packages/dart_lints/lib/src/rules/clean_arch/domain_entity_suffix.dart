import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../../lint_rule_base.dart';
import '../core/name_words.dart';
import 'feature_layout.dart';

/// Requires a public class in a feature's entity directory to end in `Entity`.
///
/// The domain layer's entities cross every other layer — a repository returns
/// one, a cubit holds one, a widget draws one — and next to a DTO or a view
/// model of the same concept they are told apart by the suffix alone. Where
/// entities live is the project's call: by default
/// `<featureRoot>/<feature>/domain/entities/`, from [FeatureLayout] plus
/// [entityDirectory].
///
/// Private classes and enums are not checked: a private class is not an
/// entity anyone else holds, and an enum in the directory is a value an entity
/// carries.
///
/// **Bad:**
/// ```dart
/// // lib/features/library/domain/entities/book.dart
/// class Book {}
/// ```
///
/// **Good:**
/// ```dart
/// class BookEntity {}
/// ```
class DomainEntitySuffix extends LintRule {
  DomainEntitySuffix({
    List<String>? featureRoots,
    List<String>? layers,
    String? domainLayer,
    String? entityDirectory,
    String? suffix,
    List<String>? forbiddenWords,
  }) : layout = FeatureLayout(roots: featureRoots, layers: layers),
       domainLayer = domainLayer ?? 'domain',
       entityDirectory = entityDirectory ?? 'entities',
       suffix = suffix ?? 'Entity',
       forbiddenWords = forbiddenWords ?? const <String>[];

  final FeatureLayout layout;

  /// The layer entities belong to.
  final String domainLayer;

  /// The directory under [domainLayer] that holds them.
  final String entityDirectory;

  /// The word an entity's name ends in.
  final String suffix;

  /// Words an entity's name must not contain — a project that reserves
  /// `Data` for DTOs lists it here. None by default.
  final List<String> forbiddenWords;

  @override
  String get name => 'domain_entity_suffix';

  @override
  String get description =>
      'A public class in $domainLayer/$entityDirectory/ ends in $suffix.';

  @override
  LintVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(filePath, lineInfo, source, this);
}

class _Visitor extends LintVisitor {
  _Visitor(super.filePath, super.lineInfo, super.source, this.rule)
    : _inEntities = rule.layout.isIn(
        filePath,
        rule.domainLayer,
        subdirectory: rule.entityDirectory,
      );

  final DomainEntitySuffix rule;
  final bool _inEntities;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final String name = node.name.lexeme;
    if (_inEntities && !name.startsWith('_')) {
      final String? problem = _problem(name);
      if (problem != null) {
        report(
          ruleName: 'domain_entity_suffix',
          message: problem,
          offset: node.name.offset,
        );
      }
    }
    super.visitClassDeclaration(node);
  }

  String? _problem(String name) {
    final String where = '${rule.domainLayer}/${rule.entityDirectory}/';
    if (!name.endsWith(rule.suffix)) {
      return '$name is declared in $where, so it is an entity and its name '
          "ends in '${rule.suffix}': $name${rule.suffix}. The suffix is what "
          'tells it apart from a model or DTO of the same concept in another '
          'layer.';
    }
    final NameWords words = NameWords(name);
    for (final String word in rule.forbiddenWords) {
      if (words.contains(word)) {
        return "$name is an entity in $where, and '$word' names another kind "
            'in this project. Drop it from the name.';
      }
    }
    return null;
  }
}
