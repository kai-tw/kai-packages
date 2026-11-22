import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../lint_rule_base.dart';
import 'feature_layout.dart';

/// Warns when a class declared under `lib/features/**/domain/exceptions/`
/// does not extend `AppException` (transitively) or implements `Exception`
/// directly.
///
/// Domain exceptions are the contract presentation catches. Forcing every
/// one through `AppException` keeps `toString()` uniform and gives Cubits
/// a single base type they can catch when they need to.
class DomainExceptionExtendsAppException extends ResolvedLintRule {
  DomainExceptionExtendsAppException({
    List<String>? featureRoots,
    List<String>? layers,
    List<String>? baseClasses,
  }) : layout = FeatureLayout(roots: featureRoots, layers: layers),
       baseClasses = baseClasses ?? const <String>['AppException'];

  final FeatureLayout layout;

  /// Accepted exception bases. Empty disables the rule: a project whose
  /// exceptions are a flat set of `implements Exception` classes has no base to
  /// extend, and demanding one would be inventing its architecture.
  final List<String> baseClasses;

  @override
  String get name => 'domain_exception_extends_app_exception';

  @override
  String get description =>
      'Domain exceptions must extend ${baseClasses.join(" / ")}, never '
      'implement Exception directly.';

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(filePath, resolvedUnit, layout, baseClasses);
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(super.filePath, super.resolvedUnit, this.layout, this.baseClasses);

  final FeatureLayout layout;
  final List<String> baseClasses;

  bool get _isInDomainExceptions =>
      baseClasses.isNotEmpty &&
      layout.isIn(filePath, 'domain', subdirectory: 'exceptions');

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (!_isInDomainExceptions) {
      return;
    }

    final List<InterfaceType>? supertypes =
        node.declaredFragment?.element.allSupertypes;
    if (supertypes == null) {
      return;
    }

    final bool extendsAppException = supertypes.any(
      (InterfaceType t) => baseClasses.contains(t.element.name),
    );

    // Skip a base class itself if it is declared here.
    if (baseClasses.contains(node.name.lexeme)) {
      return;
    }

    if (!extendsAppException) {
      report(
        ruleName: 'domain_exception_extends_app_exception',
        message:
            '${node.name.lexeme} in domain/exceptions/ must extend '
            'AppException (directly or via a feature base class).',
        offset: node.name.offset,
      );
    }
  }
}
