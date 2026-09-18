import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_lints/src/lint_rule_base.dart';
import 'package:dart_lints/src/rules/core/public_class_names_its_file.dart';
import 'package:test/test.dart';

/// Parses [source] syntactically and runs the rule's visitor over it.
List<LintViolation> _lint(
  String source, {
  String path = 'lib/foo.dart',
  List<String> acronyms = const <String>[],
  List<String> exemptFiles = const <String>[],
  List<String> familyFileSuffixes = const <String>[],
}) {
  final ParseStringResult result = parseString(
    content: source,
    throwIfDiagnostics: false,
  );
  final PublicClassNamesItsFile rule = PublicClassNamesItsFile(
    acronyms: acronyms,
    exemptFiles: exemptFiles,
    familyFileSuffixes: familyFileSuffixes,
  );
  final LintVisitor visitor = rule.createVisitor(path, result.lineInfo, source);
  result.unit.accept(visitor);
  return visitor.violations;
}

void main() {
  group('the file is named by its one public class', () {
    test('[partition] the name matches', () {
      expect(_lint('class Foo {}'), isEmpty);
    });

    test('[boundary] multi-word names snake-case at every word', () {
      expect(
        _lint(
          'class ArchiveSearchUseCase {}',
          path: 'lib/archive_search_use_case.dart',
        ),
        isEmpty,
      );
    });

    test(
      '[boundary] a run of capitals is one word until a lower case follows',
      () {
        expect(
          _lint(
            'class HTTPClientRepository {}',
            path: 'lib/http_client_repository.dart',
          ),
          isEmpty,
        );
      },
    );

    test('[partition] no class answers to the filename', () {
      final List<LintViolation> found = _lint(
        'class Bar {}',
        path: 'lib/foo.dart',
      );
      expect(found, hasLength(1));
      expect(found.single.message, contains('bar.dart'));
    });

    test(
      '[boundary] the drifted-prefix typo this rule exists to catch — reads '
      'correct at every call site, visible only against the filename',
      () {
        expect(
          _lint(
            'class UploaderQueueItemIcon {}',
            path: 'lib/upload_queue_item_icon.dart',
          ),
          hasLength(1),
        );
      },
    );
  });

  group('a second public class needs an owner', () {
    test('[partition] unrelated second class reports', () {
      final List<LintViolation> found = _lint(
        'class Foo {}\nclass Helper {}',
        path: 'lib/foo.dart',
      );
      expect(found, hasLength(1));
      expect(found.single.message, contains("'Helper'"));
    });

    test('[partition] a name-prefixed companion is part of the contract', () {
      expect(
        _lint(
          'class ArchiveSearchUseCase {}\nclass ArchiveSearchUseCaseParam {}',
          path: 'lib/archive_search_use_case.dart',
        ),
        isEmpty,
      );
    });

    test(
      '[boundary] a sealed variant — the language requires same-library',
      () {
        expect(
          _lint(
            'sealed class Shape {}\nclass RoundedShape extends Shape {}',
            path: 'lib/shape.dart',
          ),
          isEmpty,
        );
      },
    );

    test(
      '[boundary] a GRANDCHILD of the primary — a nested sealed hierarchy '
      'Dart forbids splitting, so reporting it would name an impossible fix',
      () {
        expect(
          _lint('''
sealed class AppNotificationEvent {}
sealed class DataImportNotificationEvent extends AppNotificationEvent {}
final class DataImportSucceededNotificationEvent
    extends DataImportNotificationEvent {}
''', path: 'lib/app_notification_event.dart'),
          isEmpty,
        );
      },
    );

    test(
      '[boundary] an unrelated class in that same file is still reported — '
      'the transitive walk widens the exemption, it does not disable it',
      () {
        final List<LintViolation> found = _lint('''
sealed class AppNotificationEvent {}
sealed class DataImportNotificationEvent extends AppNotificationEvent {}
final class QuotaNoticeTarget extends Equatable {}
''', path: 'lib/app_notification_event.dart');
        expect(found, hasLength(1));
        expect(found.single.message, contains('QuotaNoticeTarget'));
      },
    );

    test('[boundary] a supertype cycle terminates instead of hanging', () {
      expect(
        _lint(
          'class Foo {}\nclass A extends B {}\nclass B extends A {}',
          path: 'lib/foo.dart',
        ),
        hasLength(2),
      );
    });

    test('[partition] implements and with count as subtyping too', () {
      expect(
        _lint(
          'class Foo {}\nclass A implements Foo {}\nclass B with Foo {}',
          path: 'lib/foo.dart',
        ),
        isEmpty,
      );
    });

    test(
      '[partition] a private class is unreachable, so it is not a sibling',
      () {
        expect(_lint('class Foo {}\nclass _Helper {}'), isEmpty);
      },
    );

    test(
      '[boundary] each unowned extra reports once, not once for the file',
      () {
        expect(
          _lint(
            'class Foo {}\nclass A {}\nclass B {}',
            path: 'lib/foo.dart',
          ),
          hasLength(2),
        );
      },
    );
  });

  group('acronyms are a house spelling, applied consistently', () {
    test('[partition] without the allowlist, WebView splits', () {
      expect(
        _lint(
          'class HelpCenterWebView {}',
          path: 'lib/help_center_webview.dart',
        ),
        hasLength(1),
      );
    });

    test('[partition] with it, the compressed filename is the correct one', () {
      expect(
        _lint(
          'class HelpCenterWebView {}',
          path: 'lib/help_center_webview.dart',
          acronyms: <String>['WebView'],
        ),
        isEmpty,
      );
    });

    test('[boundary] the allowlist does not leak into unrelated names', () {
      expect(
        _lint(
          'class HelpCenterWebView {}',
          path: 'lib/help_center_web_view.dart',
          acronyms: <String>['WebView'],
        ),
        hasLength(1),
      );
    });
  });

  group('a family file names one family', () {
    test('[partition] an in-file root plus its subtypes', () {
      expect(
        _lint(
          '''
abstract class CatalogException extends AppException {}
class CatalogEntryNotFoundException extends CatalogException {}
class CatalogLockedException extends CatalogException {}
''',
          path: 'lib/catalog_exceptions.dart',
          familyFileSuffixes: <String>['_exceptions'],
        ),
        isEmpty,
      );
    });

    test('[partition] siblings sharing one imported base, no root here', () {
      expect(
        _lint(
          '''
class ReportShareException extends AppException {}
class ReportExportException extends AppException {}
''',
          path: 'lib/report_exceptions.dart',
          familyFileSuffixes: <String>['_exceptions'],
        ),
        isEmpty,
      );
    });

    test('[boundary] two unrelated families in one file still report', () {
      final List<LintViolation> found = _lint(
        '''
class ReportShareException extends AppException {}
class WidgetGoneException extends FlutterError {}
''',
        path: 'lib/report_exceptions.dart',
        familyFileSuffixes: <String>['_exceptions'],
      );
      expect(found, hasLength(1));
      expect(found.single.message, contains('family'));
    });

    test(
      '[boundary] the suffix is opt-in — unconfigured, it is a normal file',
      () {
        expect(
          _lint(
            'class ReportShareException extends AppException {}',
            path: 'lib/report_exceptions.dart',
          ),
          hasLength(1),
        );
      },
    );
  });

  group('a `.design.dart` marker names the class beneath it', () {
    test('[partition] the class beneath the marker matches', () {
      expect(
        _lint('class WelcomeView {}', path: 'lib/welcome_view.design.dart'),
        isEmpty,
      );
    });

    test(
      '[boundary] a stale class left behind by a rename still reports — '
      'the marker adjusts the basename, it does not exempt the file',
      () {
        final List<LintViolation> found = _lint(
          'class OnboardingWelcomeStep {}',
          path: 'lib/welcome_view.design.dart',
        );
        expect(found, hasLength(1));
        expect(found.single.message, contains('welcome_view.dart'));
      },
    );

    test('[boundary] an unrelated second class in it still reports', () {
      final List<LintViolation> found = _lint(
        'class WelcomeView {}\nclass Helper {}',
        path: 'lib/welcome_view.design.dart',
      );
      expect(found, hasLength(1));
      expect(found.single.message, contains("'Helper'"));
    });
  });

  group('files the rule has no claim on', () {
    test('[partition] a part-of fragment is addressed by its library', () {
      expect(
        _lint("part of 'bar.dart';\nclass Anything {}", path: 'lib/foo.dart'),
        isEmpty,
      );
    });

    test('[partition] generated output re-emits its own name', () {
      expect(_lint('class Anything {}', path: 'lib/foo.g.dart'), isEmpty);
      expect(_lint('class Anything {}', path: 'lib/foo.freezed.dart'), isEmpty);
    });

    test('[partition] an explicitly exempt file', () {
      expect(
        _lint(
          'class DefaultFirebaseOptions {}',
          path: 'lib/firebase_options.dart',
          exemptFiles: <String>['firebase_options.dart'],
        ),
        isEmpty,
      );
    });

    test(
      '[boundary] no public class at all — enums and typedefs are out of scope',
      () {
        expect(
          _lint('enum Color { red }\ntypedef Cb = void Function();'),
          isEmpty,
        );
      },
    );
  });
}
