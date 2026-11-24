import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../lint_rule_base.dart';

/// Requires a function registered as a listener to be named for the event
/// it answers: `on` and a capital, `_onScroll` rather than `_handleScroll`
/// or `_scrolled`.
///
/// A listener is registered in one place and runs from another, so its name
/// is what a reader has to go on at the declaration: `_onScroll` says "this
/// runs when something scrolls", where `_updateHeader` reads like a method
/// someone calls. One prefix also makes every listener in a file greppable.
///
/// Checked, wherever the call is:
///
/// - `Stream.listen`'s `onData`, and its `onError:` and `onDone:`;
/// - any `add…Listener` or `remove…Listener` method: `addListener`,
///   `removeListener`, `addStatusListener`, and the like on any type, since
///   the name is the convention.
///
/// Only a method or function passed by name is checked
/// (`controller.addListener(_handleScroll)`). An inline closure has no name
/// to fix; a parameter or field holding a function was named where it was
/// declared, usually `onX` already.
///
/// **Good:** `controller.addListener(_onScroll);`
/// **Bad:** `controller.addListener(_handleScroll);`
class ListenerNaming extends ResolvedLintRule {
  ListenerNaming({String? prefix}) : prefix = prefix ?? defaultPrefix;

  static const String defaultPrefix = 'on';

  /// The word a listener's name starts with, after any leading `_`.
  final String prefix;

  @override
  String get name => 'listener_naming';

  @override
  String get description =>
      "A method or function passed as a listener is named '$prefix' and a "
      "capital: '_onScroll', not '_handleScroll'.";

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(filePath, resolvedUnit, this);

  /// Whether [name], less any leading `_`, starts with [prefix] and then a
  /// capital: `onTap` does, `once` doesn't.
  bool isListenerName(String name) {
    final String bare = name.replaceFirst(RegExp(r'^_+'), '');
    if (!bare.startsWith(prefix) || bare.length == prefix.length) {
      return false;
    }
    final String next = bare[prefix.length];
    return next == next.toUpperCase() && next != next.toLowerCase();
  }
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(super.filePath, super.resolvedUnit, this.rule);

  final ListenerNaming rule;

  static final RegExp _registers = RegExp(r'^(add|remove)\w*Listener$');

  @override
  void visitMethodInvocation(MethodInvocation node) {
    for (final Expression listener in _listenersOf(node)) {
      _check(listener);
    }
    super.visitMethodInvocation(node);
  }

  /// The arguments of [node] that are listeners, or none when [node]
  /// doesn't register one.
  Iterable<Expression> _listenersOf(MethodInvocation node) {
    final String method = node.methodName.name;
    final NodeList<Expression> arguments = node.argumentList.arguments;
    if (_registers.hasMatch(method)) {
      return arguments.where((Expression a) => a is! NamedExpression);
    }
    if (method == 'listen' && _isStream(node.realTarget?.staticType)) {
      return <Expression>[
        for (final Expression a in arguments)
          if (a is! NamedExpression)
            a
          else if (a.name.label.name case 'onError' || 'onDone')
            a.expression,
      ];
    }
    return const <Expression>[];
  }

  void _check(Expression listener) {
    final Expression named = listener is FunctionReference
        ? listener.function
        : listener;
    final String? found = _declaredName(named);
    if (found == null || rule.isListenerName(found)) {
      return;
    }
    report(
      ruleName: rule.name,
      message:
          "'$found' is passed as a listener, so name it for the "
          "event it answers, starting with '${rule.prefix}': "
          "'${_suggestion(found)}'.",
      offset: listener.offset,
    );
  }

  /// [name] with [ListenerNaming.prefix] put in front, keeping its
  /// underscore. A leading `handle`, Flutter's own word for these, is
  /// replaced rather than kept: `_handleScroll` becomes `_onScroll`, and
  /// `_scrolled` becomes `_onScrolled`.
  String _suggestion(String name) {
    final String underscores = RegExp(r'^_*').stringMatch(name) ?? '';
    String bare = name.substring(underscores.length);
    final RegExpMatch? handle = RegExp('^handle([A-Z].*)').firstMatch(bare);
    if (handle != null) {
      bare = handle[1]!;
    }
    final String head = bare.isEmpty ? '' : bare[0].toUpperCase();
    final String tail = bare.length < 2 ? '' : bare.substring(1);
    return '$underscores${rule.prefix}$head$tail';
  }

  /// Whether [type] is `Stream` or one of its subtypes.
  static bool _isStream(DartType? type) {
    if (type is! InterfaceType) {
      return false;
    }
    return <InterfaceType>[type, ...type.element.allSupertypes].any(
      (InterfaceType t) =>
          t.element.name == 'Stream' && t.element.library.isDartAsync,
    );
  }

  /// The name [expression] refers to, when it names a method or a function
  /// this package declares, reached as `name` or `this.name`; `null` for
  /// anything else.
  ///
  /// `controller.add` and `list.add` are someone else's methods, passed on
  /// to forward events, and can't be renamed here; neither can a framework
  /// method such as `markNeedsBuild`. A closure, a variable, a parameter, a
  /// field and a getter have no listener name of their own.
  String? _declaredName(Expression expression) {
    final Element? element = switch (expression) {
      final SimpleIdentifier identifier => identifier.element,
      PropertyAccess(
        target: ThisExpression(),
        :final SimpleIdentifier propertyName,
      ) =>
        propertyName.element,
      _ => null,
    };
    final bool isFunction =
        element is MethodElement ||
        element is TopLevelFunctionElement ||
        element is LocalFunctionElement;
    return isFunction && element != null && _isOwn(element)
        ? element.name
        : null;
  }

  /// Whether [element] is declared in this library, or in another library
  /// of the same package.
  bool _isOwn(Element element) {
    final LibraryElement? library = element.library;
    final LibraryElement current = resolvedUnit.libraryElement;
    if (library == null || library == current) {
      return library != null;
    }
    final String? package = _packageOf(current.uri);
    return package != null && package == _packageOf(library.uri);
  }

  /// The package [uri] is in, for a `package:` URI; otherwise `null`.
  static String? _packageOf(Uri uri) =>
      uri.isScheme('package') ? uri.pathSegments.first : null;
}
