import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../../lint_rule_base.dart';
import 'feature_layout.dart';

/// Warns when a class in `lib/features/**/domain/` is annotated with
/// `@freezed`, `@Freezed(...)`, or `@unfreezed`.
///
/// Domain entities must extend `Equatable` with a `const` constructor and
/// a manual `copyWith`. `@freezed` is reserved for data-layer DTOs.
///
/// **Bad:**
/// ```dart
/// // lib/features/x/domain/entities/foo.dart
/// @freezed
/// abstract class Foo with _$Foo { ... }
/// ```
///
/// **Good:**
/// ```dart
/// class Foo extends Equatable {
///   const Foo({required this.id});
///   final String id;
///   @override
///   List<Object?> get props => <Object?>[id];
/// }
/// ```
class AvoidFreezedInDomain extends LintRule {
  AvoidFreezedInDomain({
    List<String>? featureRoots,
    List<String>? layers,
    String? requiredBase,
  }) : layout = FeatureLayout(roots: featureRoots, layers: layers),
       requiredBase = requiredBase ?? 'Equatable';

  final FeatureLayout layout;

  /// The base a domain entity is expected to extend instead. Named because
  /// the choice of value-equality base is a project's, not this rule's.
  final String requiredBase;

  @override
  String get name => 'avoid_freezed_in_domain';

  @override
  String get description =>
      'Avoid @freezed in domain/. Domain entities must extend .';

  @override
  LintVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(filePath, lineInfo, source, layout, requiredBase);
}

class _Visitor extends LintVisitor {
  _Visitor(
    super.filePath,
    super.lineInfo,
    super.source,
    this.layout,
    this.requiredBase,
  );

  final FeatureLayout layout;
  final String requiredBase;

  static const Set<String> _forbidden = <String>{
    'freezed',
    'Freezed',
    'unfreezed',
  };

  bool get _isInDomain => layout.isIn(filePath, 'domain');

  @override
  void visitAnnotation(Annotation node) {
    if (_isInDomain && _forbidden.contains(node.name.name)) {
      report(
        ruleName: 'avoid_freezed_in_domain',
        message:
            '@${node.name.name} is forbidden in domain/. Domain entities '
            'must extend  with a manual copyWith.',
        offset: node.offset,
      );
    }
    super.visitAnnotation(node);
  }
}
