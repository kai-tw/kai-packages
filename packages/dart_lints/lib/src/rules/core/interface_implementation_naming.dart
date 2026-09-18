import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../config/dart_lints_config_exception.dart';
import '../../lint_rule_base.dart';

/// Requires every implementation of one of the package's own interfaces to be
/// named in the one form the project chose.
///
/// Three [style]s, and a project picks one:
///
/// - `impl` — `<Interface>Impl`: `ReaderRepositoryImpl`.
/// - `tech_prefix` — `<Technology><Interface>`: `SqliteReaderRepository`. The
///   name must add at least one word, and must not end in `Impl`.
/// - `impl_or_prefix` — either, for a project where an interface with one
///   implementation names it `<Interface>Impl` and one with several gives each
///   a distinguishing word. That reading needs no count of the
///   implementations: two classes cannot share the `<Interface>Impl` name, so
///   the second implementation has to distinguish itself, and the first is
///   never made wrong by the second arriving — which counting them would do,
///   turning a file nobody touched red.
///
/// Mixing forms freely gives a kind two names (S2.9), so there is no default:
/// a project that enables this rule says which.
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

  static const List<String> _styles = <String>[
    'impl',
    'tech_prefix',
    'impl_or_prefix',
  ];

  /// `impl`, `tech_prefix` or `impl_or_prefix`.
  final String style;

  @override
  String get name => 'interface_implementation_naming';

  @override
  String get description => switch (style) {
    'impl' =>
      'An implementation of a package interface is named <Interface>Impl.',
    'tech_prefix' =>
      'An implementation of a package interface is named '
          '<Technology><Interface>.',
    _ =>
      'An implementation of a package interface is named <Interface>Impl or '
          '<Distinguisher><Interface>.',
  };

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(
    filePath,
    resolvedUnit,
    acceptsImpl: style != 'tech_prefix',
    acceptsPrefix: style != 'impl',
  );
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(
    super.filePath,
    super.resolvedUnit, {
    required this.acceptsImpl,
    required this.acceptsPrefix,
  });

  final bool acceptsImpl;
  final bool acceptsPrefix;

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
      message:
          '$name implements $interface, so it is named ${_form(interface)} — '
          "this project's form for an implementation.",
      offset: node.name.offset,
    );
  }

  /// What the name should look like, as the style allows.
  String _form(String interface) {
    if (!acceptsPrefix) {
      return '${interface}Impl';
    }
    final String prefixed =
        '<Distinguisher>$interface — the word that tells this implementation '
        'from another of the same interface, then the interface';
    return acceptsImpl ? '${interface}Impl or $prefixed' : prefixed;
  }

  bool _fits(String name, String interface) =>
      (acceptsImpl && name == '${interface}Impl') ||
      (acceptsPrefix &&
          name.endsWith(interface) &&
          name.length > interface.length &&
          !name.endsWith('Impl'));

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
