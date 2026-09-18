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
/// `FooAsyncNotifier` claims `AsyncNotifier`, not `Notifier`. The state type is
/// checked only on a class that extends the base, not one that merely
/// implements it, so a test double implementing a cubit is left alone.
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
      final String? problem = _problem(node.name.lexeme, element);
      if (problem != null) {
        report(ruleName: rule.name, message: problem, offset: node.name.offset);
      }
    }
    super.visitClassDeclaration(node);
  }

  String? _problem(String name, ClassElement element) {
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
    return _stateProblem(name, element, byType);
  }

  String? _stateProblem(
    String name,
    ClassElement element,
    StateHolderRole role,
  ) {
    final int? index = role.stateTypeArgument;
    final InterfaceType? base = _superclassNamed(element, role.base);
    if (index == null || base == null || index >= base.typeArguments.length) {
      return null;
    }
    final DartType state = base.typeArguments[index];
    if (state is! InterfaceType || state.element.library.isInSdk) {
      return null;
    }
    final String concept = name
        .substring(0, name.length - role.suffix.length)
        .replaceFirst(RegExp(r'^_+'), '');
    final String expected = '$concept${rule.stateSuffix}';
    final String actual = (state.element.name ?? '').replaceFirst(
      RegExp(r'^_+'),
      '',
    );
    return actual == expected
        ? null
        : '$name holds a $actual, so the state is named $expected — the '
              "holder's concept, then '${rule.stateSuffix}'.";
  }

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
