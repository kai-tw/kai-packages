import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../../lint_rule_base.dart';

/// Warns when a library's public classes do not answer to its filename.
///
/// One principle, and both halves follow from it: **a file is named by the one
/// public class it declares.** A second, unrelated public class means the
/// filename names only half of what is inside, so neither can be found by the
/// name it is used under; a name that does not match means the file cannot be
/// found from the class at all. Grep-by-symbol is how a codebase this size is
/// navigated, and it degrades silently — nobody notices the file they failed to
/// find.
///
/// It also catches the typo class of defect for free: a class whose name has
/// drifted from its own feature (`UploaderQueueItemIcon` in
/// `upload_queue_item_icon.dart`) reads as correct at every call
/// site and is only visible against the filename.
///
/// A `.design.dart` marker suffix names the class beneath it, not itself:
/// `welcome_view.design.dart` must still answer to `WelcomeView`. The suffix
/// is a house convention flagging a file another role owns and this one
/// should not casually edit — the class inside is exactly as real as any
/// other, so this is a basename adjustment, not an exemption: a second
/// unrelated class in a `.design.dart` file, or a class whose name does not
/// match, still reports.
///
/// Not flagged — a companion type has an owner, which is the thing the rule is
/// actually protecting:
/// - A class whose name **starts with** the primary's (`ArchiveSearchUseCase` +
///   `ArchiveSearchUseCaseParam`): it is a part of the primary's contract and is
///   read at the primary's call site.
/// - A **subtype** of the primary declared in the same library. Dart *requires*
///   this for a `sealed` hierarchy, so the alternative is not a stricter
///   codebase, it is `part` files.
/// - Anything under `familyFileSuffixes` — a file that deliberately holds a
///   family rather than a class (`bookmark_exceptions.dart`). It is not
///   unchecked: every public class in it must descend from **one** base, so a
///   family file holding two unrelated families still reports.
///
/// Private classes are ignored throughout: they cannot be referenced from
/// another library, so no one can fail to find them.
///
/// Enums, mixins and extensions are out of scope. They are declared alongside
/// the class they serve far more often than they head a file, and folding them
/// in would make the common case the exception.
class PublicClassNamesItsFile extends LintRule {
  PublicClassNamesItsFile({
    List<String>? acronyms,
    List<String>? exemptFiles,
    List<String>? familyFileSuffixes,
  }) : acronyms = acronyms ?? const <String>[],
       exemptFiles = exemptFiles ?? const <String>[],
       familyFileSuffixes = familyFileSuffixes ?? const <String>[];

  /// Camel-case tokens kept whole when deriving the expected filename, so
  /// `WebView` yields `webview` rather than `web_view`. Which spelling a
  /// project uses is a house choice; that it is used consistently is the rule.
  final List<String> acronyms;

  /// Path suffixes skipped entirely — a generator's output that re-emits its
  /// own name on every run.
  final List<String> exemptFiles;

  /// Basename suffixes that mark a file as holding a family (`_exceptions`).
  final List<String> familyFileSuffixes;

  @override
  String get name => 'public_class_names_its_file';

  @override
  String get description =>
      'A file is named by the one public class it declares.';

  @override
  LintVisitor createVisitor(
    String filePath,
    LineInfo lineInfo,
    String source,
  ) => _Visitor(
    filePath,
    lineInfo,
    source,
    acronyms,
    exemptFiles,
    familyFileSuffixes,
  );
}

class _Visitor extends LintVisitor {
  _Visitor(
    super.filePath,
    super.lineInfo,
    super.source,
    this.acronyms,
    this.exemptFiles,
    this.familyFileSuffixes,
  );

  final List<String> acronyms;
  final List<String> exemptFiles;
  final List<String> familyFileSuffixes;

  static const String _ruleName = 'public_class_names_its_file';

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final List<ClassDeclaration>? classes = _publicClasses(node);
    if (classes == null) {
      return;
    }

    final String base = _baseName();
    if (_handleFamilyFile(base, classes)) {
      return;
    }

    final ClassDeclaration? primary = _findPrimary(base, classes);
    if (primary == null) {
      return;
    }

    _reportUnownedClasses(node, classes, primary, base);
  }

  List<ClassDeclaration>? _publicClasses(CompilationUnit node) {
    if (_isExempt(node)) {
      return null;
    }
    final List<ClassDeclaration> classes = node.declarations
        .whereType<ClassDeclaration>()
        .where((ClassDeclaration c) => !c.name.lexeme.startsWith('_'))
        .toList();
    if (classes.isEmpty) {
      return null;
    }
    return classes;
  }

  bool _handleFamilyFile(String base, List<ClassDeclaration> classes) {
    if (!familyFileSuffixes.any(base.endsWith)) {
      return false;
    }
    _checkFamily(classes);
    return true;
  }

  ClassDeclaration? _findPrimary(
    String base,
    List<ClassDeclaration> classes,
  ) {
    final ClassDeclaration? primary = classes
        .where((ClassDeclaration c) => _snake(c.name.lexeme) == base)
        .firstOrNull;
    if (primary == null) {
      final ClassDeclaration first = classes.first;
      report(
        ruleName: _ruleName,
        message:
            "No public class names '$base.dart'. Rename the file to "
            "'${_snake(first.name.lexeme)}.dart', or rename "
            "'${first.name.lexeme}' to match the file — a class that cannot "
            'be found from its own name is found by nobody.',
        offset: first.name.offset,
      );
      return null;
    }
    return primary;
  }

  void _reportUnownedClasses(
    CompilationUnit node,
    List<ClassDeclaration> classes,
    ClassDeclaration primary,
    String base,
  ) {
    // Every class declared here, private ones included: a descent chain may
    // pass through an intermediate the file does not export.
    final Map<String, ClassDeclaration> declaredHere =
        <String, ClassDeclaration>{
          for (final ClassDeclaration c
              in node.declarations.whereType<ClassDeclaration>())
            c.name.lexeme: c,
        };

    final String owner = primary.name.lexeme;
    for (final ClassDeclaration c in classes) {
      if (identical(c, primary)) {
        continue;
      }
      final String other = c.name.lexeme;
      if (other.startsWith(owner) || _descendsFrom(c, owner, declaredHere)) {
        continue;
      }
      report(
        ruleName: _ruleName,
        message:
            "'$other' shares '$base.dart' with '$owner' but is neither part "
            'of its contract nor a subtype of it. Move it to '
            "'${_snake(other)}.dart' — the filename names only '$owner', so "
            "'$other' is reachable only by whoever already knows it is here.",
        offset: c.name.offset,
      );
    }
  }

  /// A family file holds one family: every public class must descend from the
  /// same base, whether that base is declared here (`CatalogException` and its
  /// subtypes) or imported (five siblings that all extend `AppException`).
  void _checkFamily(List<ClassDeclaration> classes) {
    final Set<String> declaredHere = classes
        .map((ClassDeclaration c) => c.name.lexeme)
        .toSet();
    final Map<String, ClassDeclaration> roots = <String, ClassDeclaration>{};
    for (final ClassDeclaration c in classes) {
      final String? superName = c.extendsClause?.superclass.name.lexeme;
      if (superName == null || declaredHere.contains(superName)) {
        continue;
      }
      roots.putIfAbsent(superName, () => c);
    }
    if (roots.length < 2) {
      return;
    }
    final List<String> names = roots.keys.toList()..sort();
    for (final String extra in names.skip(1)) {
      final ClassDeclaration c = roots[extra]!;
      report(
        ruleName: _ruleName,
        message:
            "'${c.name.lexeme}' descends from '$extra', but this file already "
            "holds the '${names.first}' family. A family file names one "
            'family; split the second one out.',
        offset: c.name.offset,
      );
    }
  }

  bool _isExempt(CompilationUnit node) {
    if (exemptFiles.any(filePath.endsWith)) {
      return true;
    }
    if (filePath.endsWith('.freezed.dart') ||
        filePath.endsWith('.g.dart') ||
        filePath.contains('/generated/')) {
      return true;
    }
    // A `part of` file is a fragment of a library named elsewhere; its own
    // filename was never the class's address.
    return node.directives.any((Directive d) => d is PartOfDirective);
  }

  /// Whether [c] reaches [owner] through any chain of supertypes declared in
  /// this same file.
  ///
  /// The walk has to be transitive, not one hop. A `sealed` hierarchy nests —
  /// `AppNotificationEvent` ← `DataImportNotificationEvent` ←
  /// `DataImportSucceededNotificationEvent` — and Dart requires **every**
  /// descendant to sit in the base's library, not just the direct children.
  /// A one-hop check therefore reports grandchildren as unowned siblings and
  /// tells the reader to move a class the compiler will not let them move.
  bool _descendsFrom(
    ClassDeclaration c,
    String owner,
    Map<String, ClassDeclaration> declaredHere,
  ) {
    final Set<String> visited = <String>{};
    final List<String> frontier = _supertypeNames(c);
    while (frontier.isNotEmpty) {
      final String name = frontier.removeLast();
      if (name == owner) {
        return true;
      }
      if (!visited.add(name)) {
        continue;
      }
      final ClassDeclaration? parent = declaredHere[name];
      if (parent != null) {
        frontier.addAll(_supertypeNames(parent));
      }
    }
    return false;
  }

  List<String> _supertypeNames(ClassDeclaration c) {
    final ExtendsClause? extendsClause = c.extendsClause;
    return <String>[
      if (extendsClause != null) extendsClause.superclass.name.lexeme,
      ...?c.implementsClause?.interfaces.map((NamedType t) => t.name.lexeme),
      ...?c.withClause?.mixinTypes.map((NamedType t) => t.name.lexeme),
    ];
  }

  String _baseName() {
    final int slash = filePath.lastIndexOf('/');
    final String file = slash < 0 ? filePath : filePath.substring(slash + 1);
    const String designSuffix = '.design.dart';
    if (file.endsWith(designSuffix)) {
      return file.substring(0, file.length - designSuffix.length);
    }
    return file.endsWith('.dart')
        ? file.substring(0, file.length - '.dart'.length)
        : file;
  }

  /// `HelpCenterWebView` -> `help_center_webview` when `WebView` is an
  /// acronym, `help_center_web_view` when it is not.
  String _snake(String name) {
    String working = name;
    for (final String acronym in acronyms) {
      if (acronym.isEmpty) {
        continue;
      }
      final String folded =
          acronym[0].toUpperCase() + acronym.substring(1).toLowerCase();
      working = working.replaceAll(acronym, folded);
    }
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < working.length; i++) {
      final String ch = working[i];
      final bool upper = ch.toUpperCase() == ch && ch.toLowerCase() != ch;
      if (upper && i > 0 && _boundaryBefore(working, i)) {
        out.write('_');
      }
      out.write(ch.toLowerCase());
    }
    return out.toString();
  }

  /// A word starts here when the previous character is not upper case, or when
  /// this is the last capital of a run that a lower-case letter follows
  /// (`HTTPClient` -> `http_client`).
  bool _boundaryBefore(String s, int i) {
    final String prev = s[i - 1];
    final bool prevUpper =
        prev.toUpperCase() == prev && prev.toLowerCase() != prev;
    if (!prevUpper) {
      return prev != '_';
    }
    if (i + 1 >= s.length) {
      return false;
    }
    final String next = s[i + 1];
    return next.toLowerCase() == next && next.toUpperCase() != next;
  }
}
