import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../lint_rule_base.dart';
import 'state_holder_role.dart';

/// Requires a state holder's name and its type to say the same thing, and its
/// state type to be named for it.
///
/// For each configured [StateHolderRole]:
///
/// - a subtype of the base ends in the role's suffix — `ReaderSettingsCubit`,
///   not `ReaderSettings`;
/// - a class ending in the suffix is a subtype of that base — a
///   `ReaderSettingsCubit` that is not a `Cubit` is lying at every call site;
/// - where the role says which type argument is the state, and the state is a
///   type of the project, it is named for the holder: `ReaderSettingsCubit`
///   holds a `ReaderSettingsState`.
///
/// When suffixes overlap, the longest one a name ends in decides:
/// `FooAsyncNotifier` claims `AsyncNotifier`, not `Notifier`.
///
/// The state name is asked only of the class that writes the state type
/// argument, and only where that class is not a double. Three shapes hold a
/// state they did not name, and none of them can rename it:
///
/// - a class that merely **implements** the base;
/// - a **test double** — it extends the base and implements a subtype of it
///   (`class _StubFooCubit extends Cubit<FooState> implements FooCubit`). The
///   state is the real holder's, and narrowing it is a compile error, because
///   a class cannot implement `StateStreamable` at two different states;
/// - a **subclass of a concrete holder** (`class RetryingFooCubit extends
///   FooCubit`), which writes no type argument at all.
///
/// An alias counts as the name it is written under: a holder declared
/// `extends SharedListCubit<Foo, FooState>`, where `FooState` is a
/// `typedef` for a shared generic state, satisfies the check — `FooState` is
/// what every call site reads.
///
/// One class serves two registered rules — `require_cubit_suffix` for the
/// `bloc` bundle and `require_notifier_suffix` for `riverpod` — because the
/// check is the same and only the framework differs. Riverpod's code-generated
/// notifiers (`class Todos extends _$Todos`) extend a generated base, not
/// `Notifier`, so they are not state holders to this rule.
///
/// **Bad:**
/// ```dart
/// class ReaderSettings extends Cubit<ReaderSettingsState> {}
/// class ReaderCubit {}
/// class LibraryCubit extends Cubit<ShelfData> {}
/// ```
///
/// **Good:**
/// ```dart
/// class ReaderSettingsCubit extends Cubit<ReaderSettingsState> {}
/// class LibraryCubit extends Cubit<LibraryState> {}
/// ```
class StateHolderNaming extends ResolvedLintRule {
  StateHolderNaming({
    required this.name,
    required this.roles,
    String? stateSuffix,
  }) : stateSuffix = stateSuffix ?? 'State';

  @override
  final String name;

  final List<StateHolderRole> roles;

  /// The word a state type's name ends in.
  final String stateSuffix;

  @override
  String get description =>
      'A ${roles.map((StateHolderRole r) => r.base).join(' / ')} subtype '
      'carries the matching suffix, a class with the suffix is that subtype, '
      'and its state type is named <Concept>$stateSuffix.';

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(filePath, resolvedUnit, this);
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(super.filePath, super.resolvedUnit, this.rule);

  final StateHolderNaming rule;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final ClassElement? element = node.declaredFragment?.element;
    if (element != null) {
      final String? problem = _problem(node, node.name.lexeme, element);
      if (problem != null) {
        report(ruleName: rule.name, message: problem, offset: node.name.offset);
      }
    }
    super.visitClassDeclaration(node);
  }

  String? _problem(ClassDeclaration node, String name, ClassElement element) {
    // A base itself, or a generated framework class, is not a holder anyone
    // named.
    if (name.startsWith(r'$') ||
        rule.roles.any((StateHolderRole r) => r.base == name)) {
      return null;
    }
    final StateHolderRole? byType = _roleOf(element);
    final StateHolderRole? byName = _roleNamed(name);
    if (byType == null) {
      return byName == null
          ? null
          : "$name ends in '${byName.suffix}' but is not a ${byName.base}. "
                'Make it one, or rename it so the name does not claim a role '
                'the type does not have.';
    }
    if (byName?.suffix != byType.suffix) {
      return '$name is a ${byType.base}, so its name ends in '
          "'${byType.suffix}': the suffix announces the role at every call "
          'site, grep hit and stack frame.';
    }
    return _stateProblem(node, name, element, byType);
  }

  String? _stateProblem(
    ClassDeclaration node,
    String name,
    ClassElement element,
    StateHolderRole role,
  ) {
    final InterfaceType? state = _stateNamedHere(node, element, role);
    if (state == null) {
      return null;
    }
    final String concept = name
        .substring(0, name.length - role.suffix.length)
        .replaceFirst(RegExp(r'^_+'), '');
    final String expected = '$concept${rule.stateSuffix}';
    final List<String> written = <String?>[
      state.alias?.element.name,
      state.element.name,
    ].nonNulls.map((String n) => n.replaceFirst(RegExp(r'^_+'), '')).toList();
    return written.contains(expected)
        ? null
        : '$name holds a ${written.first}, so the state is named $expected — '
              "the holder's concept, then '${rule.stateSuffix}'.";
  }

  /// The state type [node] is answerable for, or `null` when it is not
  /// answerable for one — the role does not say which argument is the state,
  /// the base is only implemented, the state is a type parameter or an SDK
  /// type, or [node] holds a state it did not name (see [_namesTheState] and
  /// [_isDoubleOf]).
  static InterfaceType? _stateNamedHere(
    ClassDeclaration node,
    ClassElement element,
    StateHolderRole role,
  ) {
    final int? index = role.stateTypeArgument;
    final InterfaceType? base = _superclassNamed(element, role.base);
    if (index == null || base == null || index >= base.typeArguments.length) {
      return null;
    }
    if (!_namesTheState(node) || _isDoubleOf(element, role)) {
      return null;
    }
    final DartType state = base.typeArguments[index];
    return state is InterfaceType && !state.element.library.isInSdk
        ? state
        : null;
  }

  /// Whether [node]'s own `extends` clause writes the state type argument.
  ///
  /// A class that extends a *concrete* holder inherits the state type already
  /// named for that holder — `class RetryingFooCubit extends FooCubit` holds a
  /// `FooState` and has no type argument to write. Demanding a
  /// `RetryingFooState` there asks for a state class the subclass does not
  /// have and cannot supply, so only the class that writes the argument
  /// answers for the name.
  static bool _namesTheState(ClassDeclaration node) =>
      node.extendsClause?.superclass.typeArguments != null;

  /// Whether [element] is a test double of another holder: it extends the
  /// role's base *and* implements a subtype of that base.
  ///
  /// That shape is a double and nothing else — production code does not
  /// implement the holder it is a sibling of, and the double's state type is
  /// the real holder's, named for the real holder. Implementing the base
  /// alone does not count: a class doing that is a holder in its own right.
  static bool _isDoubleOf(ClassElement element, StateHolderRole role) =>
      element.interfaces.any(
        (InterfaceType t) =>
            t.element.name != role.base &&
            t.element.allSupertypes.any(
              (InterfaceType s) => s.element.name == role.base,
            ),
      );

  StateHolderRole? _roleOf(ClassElement element) {
    for (final StateHolderRole role in rule.roles) {
      if (element.allSupertypes.any(
        (InterfaceType t) => t.element.name == role.base,
      )) {
        return role;
      }
    }
    return null;
  }

  StateHolderRole? _roleNamed(String name) {
    StateHolderRole? best;
    for (final StateHolderRole role in rule.roles) {
      if (name.endsWith(role.suffix) &&
          (best == null || role.suffix.length > best.suffix.length)) {
        best = role;
      }
    }
    return best;
  }

  /// [baseName] with [element]'s type arguments substituted, or `null` when it
  /// is not in [element]'s superclass chain — when [element] only implements
  /// it.
  ///
  /// The chain is walked for names only: a declared `supertype` further up
  /// still speaks in its own type parameters (`HydratedCubit<S>` extends
  /// `Cubit<S>`), so the arguments come from [ClassElement.allSupertypes],
  /// where they are substituted.
  static InterfaceType? _superclassNamed(
    ClassElement element,
    String baseName,
  ) {
    InterfaceElement? current = element.supertype?.element;
    while (current != null && current.name != baseName) {
      current = current.supertype?.element;
    }
    if (current == null) {
      return null;
    }
    return element.allSupertypes
        .where((InterfaceType t) => t.element == current)
        .firstOrNull;
  }
}
