import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../lint_rule_base.dart';

/// Flags a `BuildContext` parameter on the constructor of a `SnackBar`
/// subclass.
///
/// Notification SnackBars are built by the shell's notification listener
/// (`lib/app/`), which resolves `AppLocalizations` once at the dispatch
/// boundary and hands it to the feature's SnackBar subclass **by value**
/// (`lib/app/CLAUDE.md §Notification Bus Flow`). A subclass that takes a
/// `BuildContext` re-reaches into the widget tree to resolve l10n — the
/// exact coupling the resolved-by-value contract removes, and the shape
/// the founder corrected over three passes.
///
/// Detection is the SnackBar supertype chain + a constructor parameter
/// typed `BuildContext`; `this.`-field and `super.`-forwarding params,
/// closures, and the `Builder(builder: (context) ...)` the base passes
/// into `SnackBar.content` are never constructor parameters and never
/// match.
///
/// **Bad:**
/// ```dart
/// class DataImportSnackBar extends NoticeSnackBar {
///   DataImportSnackBar(BuildContext context) : ...;
/// }
/// ```
///
/// **Good:**
/// ```dart
/// class DataImportSnackBar extends NoticeSnackBar {
///   DataImportSnackBar(AppLocalizations l10n) : ...;
/// }
/// ```
class AvoidBuildContextInSnackBar extends ResolvedLintRule {
  @override
  String get name => 'avoid_buildcontext_in_snackbar';

  @override
  String get description =>
      'A SnackBar subclass constructor must take resolved AppLocalizations '
      'by value, never a BuildContext.';

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
    if (!_isSnackBar(node)) {
      super.visitClassDeclaration(node);
      return;
    }

    // Scan: any constructor parameter typed BuildContext.
    for (final ConstructorDeclaration ctor
        in node.members.whereType<ConstructorDeclaration>()) {
      for (final FormalParameter param in ctor.parameters.parameters) {
        final NamedType? type = _parameterType(param);
        if (type != null && type.name.lexeme == 'BuildContext') {
          report(
            ruleName: 'avoid_buildcontext_in_snackbar',
            message:
                '${node.name.lexeme} is a SnackBar subclass taking a '
                'BuildContext — pass the resolved AppLocalizations by value '
                'instead. The shell resolves l10n once at the dispatch '
                'boundary (lib/app/CLAUDE.md §Notification Bus Flow).',
            offset: type.offset,
          );
        }
      }
    }

    super.visitClassDeclaration(node);
  }

  bool _isSnackBar(ClassDeclaration node) {
    final List<InterfaceType>? supertypes =
        node.declaredFragment?.element.allSupertypes;
    if (supertypes == null) {
      return false;
    }

    return supertypes.any((InterfaceType t) => t.element.name == 'SnackBar');
  }

  /// The declared type of a formal parameter, unwrapping the optional /
  /// named wrapper. Returns null for `this.`-fields, `super.`-forwarding,
  /// closures, and untyped params — none carry a `BuildContext` annotation.
  NamedType? _parameterType(FormalParameter param) {
    final FormalParameter inner = param is DefaultFormalParameter
        ? param.parameter
        : param;

    if (inner is SimpleFormalParameter) {
      final TypeAnnotation? type = inner.type;
      return type is NamedType ? type : null;
    }

    return null;
  }
}
