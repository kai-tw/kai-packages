import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../lint_rule_base.dart';
import 'name_words.dart';
import 'scoped_word.dart';

/// Forbids words that name no kind in a type's name — `Manager`, `Helper`,
/// `Util` by default.
///
/// A type's last word says what kind of thing it is. These words say only
/// that it does something, somewhere, so a `ReaderManager` could be a
/// repository, a controller or a cache, and tends to become all three. The
/// check is by whole word (see [NameWords]): `HelperText` is reported,
/// `Helpers` and `Utility` are not unless listed.
///
/// Some words are vague only for most types. [scopedWords] forbids a word
/// except on a class that extends or implements one of the listed types — a
/// project that reserves `Service` for its background services lists
/// `{word: Service, unlessExtends: [BackgroundService]}`.
///
/// Classes, mixins, enums, extensions, extension types and typedefs are
/// checked; only a class can satisfy `unlessExtends`. A configured
/// [forbiddenWords] replaces the default.
///
/// **Bad:**
/// ```dart
/// class SessionManager {}
/// extension DateUtil on DateTime {}
/// ```
///
/// **Good:**
/// ```dart
/// class SessionRepository {}
/// extension DateFormatting on DateTime {}
/// ```
class AvoidVagueTypeWords extends ResolvedLintRule {
  AvoidVagueTypeWords({
    List<String>? forbiddenWords,
    List<Map<String, Object?>>? scopedWords,
  }) : words = <ScopedWord>[
         for (final String word in forbiddenWords ?? _defaultWords)
           ScopedWord(word: word),
         ...?scopedWords?.map(ScopedWord.fromMap),
       ];

  static const List<String> _defaultWords = <String>[
    'Manager',
    'Helper',
    'Util',
    'Utils',
  ];

  final List<ScopedWord> words;

  @override
  String get name => 'avoid_vague_type_words';

  @override
  String get description =>
      'Type names must not contain '
      '${words.map((ScopedWord w) => w.word).join(' / ')}: words that name no '
      'kind.';

  @override
  ResolvedLintVisitor createResolvedVisitor(
    String filePath,
    ResolvedUnitResult resolvedUnit,
  ) => _Visitor(filePath, resolvedUnit, words);
}

class _Visitor extends ResolvedLintVisitor {
  _Visitor(super.filePath, super.resolvedUnit, this.words);

  final List<ScopedWord> words;

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _check(node.name, node.declaredFragment?.element);
    super.visitClassDeclaration(node);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    _check(node.name, null);
    super.visitClassTypeAlias(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _check(node.name, null);
    super.visitMixinDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    _check(node.name, null);
    super.visitEnumDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final Token? name = node.name;
    if (name != null) {
      _check(name, null);
    }
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    _check(node.name, null);
    super.visitExtensionTypeDeclaration(node);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    _check(node.name, null);
    super.visitGenericTypeAlias(node);
  }

  /// [element] is the declared class, when the declaration is one.
  void _check(Token name, InterfaceElement? element) {
    final NameWords nameWords = NameWords(name.lexeme);
    for (final ScopedWord scoped in words) {
      if (!nameWords.contains(scoped.word) || _excused(scoped, element)) {
        continue;
      }
      report(
        ruleName: 'avoid_vague_type_words',
        message:
            "${name.lexeme} contains '${scoped.word}', which names no kind of "
            'thing here. Name what the type is — a repository, a controller, '
            'a formatter — so its last word says it.',
        offset: name.offset,
      );
      return;
    }
  }

  static bool _excused(ScopedWord scoped, InterfaceElement? element) =>
      element != null &&
      <InterfaceType>[
        element.thisType,
        ...element.allSupertypes,
      ].any((InterfaceType t) => scoped.unlessExtends.contains(t.element.name));
}
