import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../config/dart_lints_config_exception.dart';
import '../../lint_rule_base.dart';

/// Requires every implementation of one of the package's own interfaces to be
/// named in the one form the project chose.
///
/// Two forms are in use, and a project picks one ([style]):
///
/// - `impl` — `<Interface>Impl`: `ReaderRepositoryImpl`.
/// - `tech_prefix` — `<Technology><Interface>`: `SqliteReaderRepository`. The
///   name must add at least one word, and must not end in `Impl`.
///
/// Mixing the two in one codebase gives a kind two names (S2.9), so there is
/// no default: a project that enables this rule says which.
///
/// An interface here is a class of this package, declared `interface`, or
/// `abstract` with no concrete member. A concrete class is checked against each
/// such interface it implements or extends directly, and passes if its name
/// fits any of them. Abstract classes are sub-interfaces, not implementations,
/// and are not checked. Only files of a package (a `package:` URI) are checked,
/// against interfaces of that same package.
class InterfaceImplementationNaming extends ResolvedLintRule {
  InterfaceImplementationNaming({required this.style}) {
    if (!_styles.contains(style)) {
      throw DartLintsConfigException(
        'rule "interface_implementation_naming": style must be one of '
        '${_styles.join(', ')}, not "$style"',
      );
    }
  }

  static const List<String> _styles = <String>['impl', 'tech_prefix'];

  /// `impl` or `tech_prefix`.
  final String style;

  @override
  String get name => 'interface_implementation_naming';

  @override
  String get description => style == 'impl'
      ? 'An implementation of a package interface is named <Interface>Impl.'
      : 'An implementation of a package interface is named '
            '<Technology><Interface>.';

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(filePath, resolvedUnit, implSuffix: style == 'impl');
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(super.filePath, super.resolvedUnit, {required this.implSuffix});

  final bool implSuffix;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final ClassElement? element = node.declaredFragment?.element;
    if (element != null && !element.isAbstract) {
      _check(node, element);
    }
    super.visitClassDeclaration(node);
  }

  void _check(ClassDeclaration node, ClassElement element) {
    final String? package = _packageOf(element.library);
    if (package == null) {
      return;
    }
    final List<String> interfaces = <String>[
      for (final InterfaceType t in <InterfaceType>[
        ?element.supertype,
        ...element.interfaces,
      ])
        if (_isOwnInterface(t.element, package)) ?t.element.name,
    ];
    final String name = node.name.lexeme;
    if (interfaces.isEmpty || interfaces.any((String i) => _fits(name, i))) {
      return;
    }
    final String interface = interfaces.first;
    report(
      ruleName: 'interface_implementation_naming',
      message: implSuffix
          ? '$name implements $interface, so it is named ${interface}Impl — '
                "this project's form for an implementation."
          : '$name implements $interface, so it is named '
                '<Technology>$interface — the technology it is built on, then '
                "the interface: this project's form for an implementation.",
      offset: node.name.offset,
    );
  }

  bool _fits(String name, String interface) => implSuffix
      ? name == '${interface}Impl'
      : name.endsWith(interface) &&
            name.length > interface.length &&
            !name.endsWith('Impl');

  static bool _isOwnInterface(InterfaceElement element, String package) =>
      element is ClassElement &&
      _packageOf(element.library) == package &&
      (element.isInterface || _isPurelyAbstract(element));

  static bool _isPurelyAbstract(ClassElement element) =>
      element.isAbstract &&
      element.methods.every((MethodElement m) => m.isStatic || m.isAbstract) &&
      element.getters.every((GetterElement g) => g.isStatic || g.isAbstract) &&
      element.setters.every((SetterElement s) => s.isStatic || s.isAbstract) &&
      element.fields.every((FieldElement f) => f.isSynthetic || f.isStatic);

  /// The package [library] belongs to, or `null` when it is not in one.
  static String? _packageOf(LibraryElement library) {
    final Uri uri = library.uri;
    return uri.isScheme('package') ? uri.pathSegments.first : null;
  }
}
