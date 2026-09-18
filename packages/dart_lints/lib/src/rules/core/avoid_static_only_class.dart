import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../../lint_rule_base.dart';

/// Warns when every member of a class is `static`.
///
/// The stock `avoid_classes_with_only_static_members` has a gap that lets
/// the most common shape of this antipattern straight through: **any
/// constructor exempts the class**, so `class X { X._(); static void a() {}
/// }` — a private constructor added specifically to block instantiation —
/// is read as "this class has a constructor" rather than "this class holds
/// no instance state at all." This rule closes that gap: it looks at every
/// member that is not itself a constructor and reports if there is at least
/// one such member and every one of them is `static`.
///
/// **A bare `abstract` class with no constructor at all is exempt**, not
/// caught. `abstract final class ColumnKeys { static const id = 'id';
/// }` is Effective Dart's own idiom for a non-instantiable namespace — the
/// language already refuses `ColumnKeys()`, so there is no workaround to
/// close. The gap this rule closes is specifically the *redundant*
/// workaround: a constructor written to block instantiation on a class that
/// either could have been `abstract` instead, or already is and gained a
/// constructor anyway. An `abstract` class that also declares one — even a
/// private `X._()` — is still reported: the constructor does nothing there
/// but confirm the class was never going to be a real unit of behavior.
///
/// **A class that participates in a type hierarchy is also exempt**, however
/// static its own declared members look. `extends` and `with` bring instance
/// members this syntactic visitor cannot see — freezed's `with _$X` supplies
/// `==`, `copyWith` and `toJson`, so a freezed data type carrying one static
/// pre-decode validator reads as all-static from the AST alone. A class that
/// something in the same file extends is the other direction: a hierarchy
/// root, whose constructor exists for its subclasses' `super()` calls rather
/// than to block instantiation. Dart requires every subtype of a `sealed`
/// class to live in that class's library, so scanning the file settles the
/// sealed case exhaustively rather than heuristically — and a `sealed` class
/// cannot take the bare-`abstract` exemption above, because `abstract sealed
/// class` is a compile error ("a 'sealed' class can't be marked 'abstract'
/// because it's already implicitly abstract").
///
/// **The fix for what remains is not a private constructor** — that only
/// stops instantiation, it does not give the members anywhere better to
/// live. Move each member onto the type it actually describes, or fold a
/// closed set of them into an `enum`. A class that exists solely to give
/// `static` members a namespace is not a unit of behavior or state; it is a
/// filing cabinet wearing a class declaration.
///
/// **Interacts with `avoid_top_level_identifiers`.** That rule's own
/// prescribed fix for a top-level function is "namespace it as a static
/// method on a class with a private constructor" — precisely the shape this
/// rule forbids. Enabling both in the same project is coherent (a pure
/// function's real home is an extension method, or the entity it operates
/// on, or an enum for a closed set of related constants) but only if every
/// top-level declaration the other rule catches actually has one of those
/// homes available. Audit both together before enabling them side by side.
///
/// **Bad — private constructor blocks instantiation, changes nothing else:**
/// ```dart
/// class LocaleUtils {
///   LocaleUtils._();
///   static String normalize(String tag) => tag.toLowerCase();
/// }
/// ```
///
/// **Bad — already `abstract`, so the constructor is pure redundancy:**
/// ```dart
/// abstract final class DebounceKeys {
///   DebounceKeys._();
///   static const search = 'search';
/// }
/// ```
///
/// **Fine as-is — bare `abstract`, nothing left to close:**
/// ```dart
/// abstract final class DebounceKeys {
///   static const search = 'search';
///   static const sync = 'sync';
/// }
/// ```
///
/// **Good — the behavior moves onto what it describes:**
/// ```dart
/// extension LocaleNormalization on String {
///   String get normalizedLocale => toLowerCase();
/// }
/// ```
class AvoidStaticOnlyClass extends LintRule {
  AvoidStaticOnlyClass({List<String>? exemptFiles})
    : exemptFiles = exemptFiles ?? const <String>[];

  /// Files a generator owns end to end, so there is nothing to restructure.
  ///
  /// `firebase_options.dart` is the worked example: `DefaultFirebaseOptions`
  /// is a static-only class the flutterfire CLI writes and rewrites, and the
  /// next `flutterfire configure` undoes any hand edit.
  final List<String> exemptFiles;

  @override
  String get name => 'avoid_static_only_class';

  @override
  String get description =>
      'Avoid a class whose members are all static. Move each member onto '
      'the type it describes, or fold a closed set into an enum — a private '
      'constructor does not turn a namespace into a unit.';

  @override
  LintVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(filePath, lineInfo, source, exemptFiles);
}

class _Visitor extends LintVisitor {
  _Visitor(super.filePath, super.lineInfo, super.source, this.exemptFiles);

  final List<String> exemptFiles;

  /// Every name some class in this file `extends`.
  ///
  /// Collected once per unit so a hierarchy root can recognise itself: the
  /// root is reported before its subclasses are visited, so asking "does
  /// anything extend me?" needs the whole file already in hand.
  Set<String> _extendedInUnit = const <String>{};

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final Set<String> extended = <String>{};
    for (final ClassDeclaration c
        in node.declarations.whereType<ClassDeclaration>()) {
      final ExtendsClause? extendsClause = c.extendsClause;
      if (extendsClause != null) {
        extended.add(extendsClause.superclass.name.lexeme);
      }
    }
    _extendedInUnit = extended;
    super.visitCompilationUnit(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    if (exemptFiles.any(filePath.endsWith)) {
      super.visitClassDeclaration(node);
      return;
    }

    final _MemberSummary members = _summarizeMembers(node.members);

    // A bare `abstract` class with no constructor is already uninstantiable
    // by the language itself — Effective Dart's own recommended shape for a
    // namespace, and there is no redundant workaround left to flag. One that
    // ALSO declares a constructor still reports: the constructor is doing
    // nothing there, which is the tell that the class was never a unit.
    final bool isUnclosableWithoutWorkaround =
        node.abstractKeyword != null && !members.hasConstructor;

    if (members.hasMember &&
        members.allStatic &&
        !isUnclosableWithoutWorkaround &&
        !_participatesInHierarchy(node)) {
      report(
        ruleName: 'avoid_static_only_class',
        message:
            "'${node.name.lexeme}' has no member that is not static. Move "
            'each member onto the type it describes, or fold a closed set '
            'into an enum — a private constructor does not turn a '
            'namespace into a unit.',
        offset: node.name.offset,
      );
    }

    super.visitClassDeclaration(node);
  }

  /// Whether [members] contains at least one member that is not a
  /// constructor ([hasMember]), at least one constructor ([hasConstructor]),
  /// and every non-constructor member is `static` ([allStatic]) — the three
  /// facts the antipattern check needs from a class's member list.
  _MemberSummary _summarizeMembers(List<ClassMember> members) {
    bool hasMember = false;
    bool hasConstructor = false;
    bool allStatic = true;
    for (final ClassMember member in members) {
      if (member is ConstructorDeclaration) {
        hasConstructor = true;
        continue;
      }
      hasMember = true;
      final bool isStatic = switch (member) {
        FieldDeclaration(:final bool isStatic) => isStatic,
        MethodDeclaration(:final bool isStatic) => isStatic,
        _ => true,
      };
      if (!isStatic) {
        allStatic = false;
        break;
      }
    }
    return _MemberSummary(
      hasMember: hasMember,
      hasConstructor: hasConstructor,
      allStatic: allStatic,
    );
  }

  /// A class wired into a type hierarchy is not a filing cabinet. `extends`
  /// and `with` carry instance members this syntactic visitor cannot see
  /// (freezed's `with _$X` is the common case); being extended by something
  /// in this file makes [node] a base, whose constructor serves `super()`
  /// calls rather than blocking instantiation.
  bool _participatesInHierarchy(ClassDeclaration node) =>
      node.extendsClause != null ||
      node.withClause != null ||
      _extendedInUnit.contains(node.name.lexeme);
}

/// The three facts a class's member list is scanned for: whether it has any
/// non-constructor member, whether it has a constructor, and whether every
/// non-constructor member is `static`.
class _MemberSummary {
  const _MemberSummary({
    required this.hasMember,
    required this.hasConstructor,
    required this.allStatic,
  });

  final bool hasMember;
  final bool hasConstructor;
  final bool allStatic;
}
