import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../lint_rule_base.dart';
import 'reserved_suffix.dart';

/// Warns when a public widget class ends in a suffix reserved for another role.
///
/// A widget named `FooState` collides on import with the state class of the
/// same name, and the reader of a call site cannot tell which they have. The
/// suffixes are configurable; see [ReservedSuffix].
///
/// Private classes (leading `_`) are exempt, which also covers the framework's
/// own `_FooState extends State<Foo>` pattern — those are state objects, not
/// widgets.
class AvoidReservedWidgetSuffix extends ResolvedLintRule {
  AvoidReservedWidgetSuffix({
    List<Map<String, Object?>>? reservedSuffixes,
    List<String>? widgetSupertypes,
  }) : reservedSuffixes =
           reservedSuffixes?.map(ReservedSuffix.fromMap).toList() ??
           _defaultReservedSuffixes,
       widgetSupertypes =
           widgetSupertypes ??
           const <String>['StatelessWidget', 'StatefulWidget'];

  /// Reserved out of the box, so the rule enforces without configuration.
  ///
  /// `State` and `Sheet` are Flutter's own: `State` is the framework's state
  /// object and `Sheet` is the Material component whose full spelling is
  /// `BottomSheet`. `Cubit`, `Bloc`, `Notifier` and `Provider` name
  /// state-management roles; in a codebase without one of them nothing ends in
  /// it, so carrying it costs such a project nothing.
  ///
  /// `Widget` is not reserved: a name ending in it still says the type is a
  /// widget, which is its kind. A project that wants the bare word gone lists
  /// it.
  static const List<ReservedSuffix> _defaultReservedSuffixes = <ReservedSuffix>[
    ReservedSuffix(
      suffix: 'State',
      hint:
          'Rename to View / Placeholder / Indicator / Banner — State is '
          'reserved for the framework and for state classes.',
    ),
    ReservedSuffix(
      suffix: 'Cubit',
      hint:
          'Rename to a descriptive widget role — Cubit is reserved for '
          'state holders.',
    ),
    ReservedSuffix(
      suffix: 'Bloc',
      hint:
          'Rename to a descriptive widget role — Bloc is reserved for state '
          'holders.',
    ),
    ReservedSuffix(
      suffix: 'Notifier',
      hint:
          'Rename to a descriptive widget role — Notifier is reserved for '
          'state holders.',
    ),
    ReservedSuffix(
      suffix: 'Provider',
      hint:
          'Rename to a descriptive widget role — Provider is reserved for '
          'dependency and state providers.',
    ),
    ReservedSuffix(
      suffix: 'Sheet',
      unless: 'BottomSheet',
      hint:
          'Modal bottom sheets must spell out BottomSheet so call sites '
          'are unambiguous.',
    ),
  ];

  /// Suffixes a widget name may not end in. Configuring an empty list turns the
  /// rule off, which is a project's call to make explicitly — it is not what
  /// silence means.
  final List<ReservedSuffix> reservedSuffixes;

  /// Supertypes that make a class a widget subject to the naming rule.
  final List<String> widgetSupertypes;

  @override
  String get name => 'avoid_reserved_widget_suffix';

  @override
  String get description =>
      'Widget class names must not end in a suffix reserved for another role: '
      '${reservedSuffixes.map((ReservedSuffix r) => r.suffix).join(' / ')}.';

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(filePath, resolvedUnit, reservedSuffixes, widgetSupertypes);
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(
    super.filePath,
    super.resolvedUnit,
    this.reservedSuffixes,
    this._widgetSupertypes,
  );

  final List<ReservedSuffix> reservedSuffixes;
  final List<String> _widgetSupertypes;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final String name = node.name.lexeme;
    if (name.startsWith('_')) {
      return;
    }
    if (!_isWidget(node)) {
      return;
    }

    // First match only: the suffixes are alternatives, and a name ending in two
    // of them has one problem, not two.
    for (final ReservedSuffix reserved in reservedSuffixes) {
      if (!reserved.matches(name)) {
        continue;
      }
      report(
        ruleName: 'avoid_reserved_widget_suffix',
        message:
            "$name uses the reserved '${reserved.suffix}' suffix on a widget. "
            '${reserved.hint}',
        offset: node.name.offset,
      );
      return;
    }
  }

  bool _isWidget(ClassDeclaration node) {
    final List<InterfaceType>? supertypes =
        node.declaredFragment?.element.allSupertypes;
    if (supertypes == null) {
      return false;
    }
    return supertypes.any(
      (InterfaceType t) => _widgetSupertypes.contains(t.element.name),
    );
  }
}
