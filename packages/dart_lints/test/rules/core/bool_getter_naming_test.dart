import 'package:dart_lints/src/lint_rule_base.dart';
import 'package:dart_lints/src/rules/core/bool_getter_naming.dart';
import 'package:test/test.dart';

import '../naming_fixture.dart';

void main() {
  late NamingFixture fixture;

  setUp(() => fixture = NamingFixture());

  Set<String> reported(String source, {List<String>? prefixes}) =>
      reportedNames(
        fixture.parsed(BoolGetterNaming(prefixes: prefixes), source),
        source,
      );

  group('a boolean getter must be named as a question', () {
    test('[partition] `bool get aborted` is reported', () {
      expect(reported('class C {\n  bool get aborted => true;\n}'), <String>{
        'aborted',
      });
    });

    test('[partition] each default prefix satisfies it', () {
      expect(
        reported(
          'class C {\n'
          '  bool get isEmpty => true;\n'
          '  bool get canPop => true;\n'
          '  bool get hasError => true;\n'
          '}',
        ),
        isEmpty,
      );
    });

    test('[partition] a `Future<bool>` getter counts as boolean', () {
      expect(
        reported('class C {\n  Future<bool> get ready async => true;\n}'),
        <String>{'ready'},
      );
    });

    test('[partition] nullable `bool?` and `Future<bool?>` count too', () {
      expect(
        reported(
          'class C {\n'
          '  bool? get known => null;\n'
          '  Future<bool?> get metered async => null;\n'
          '}',
        ),
        <String>{'known', 'metered'},
      );
    });

    test('[partition] a private getter is judged after its underscore', () {
      expect(
        reported(
          'class C {\n'
          '  bool get _stopped => true;\n'
          '  bool get _isStopped => true;\n'
          '}',
        ),
        <String>{'_stopped'},
      );
    });

    test('[partition] top-level, static and extension getters are checked', () {
      expect(
        reported(
          'bool get ready => true;\n'
          'class C {\n  static bool get loaded => true;\n}\n'
          'extension E on int {\n  bool get positive => this > 0;\n}',
        ),
        <String>{'ready', 'loaded', 'positive'},
      );
    });

    test(
      '[error-guessing] a prefix needs a capital after it: `issued` and '
      '`cancelled` are not questions',
      () {
        expect(
          reported(
            'class C {\n'
            '  bool get issued => true;\n'
            '  bool get cancelled => true;\n'
            '  bool get hash => true;\n'
            '}',
          ),
          <String>{'issued', 'cancelled', 'hash'},
        );
      },
    );

    test('[error-guessing] a bare prefix is not a question', () {
      expect(reported('class C {\n  bool get has => true;\n}'), <String>{
        'has',
      });
    });

    test('[decision] `prefixes` replaces the default list', () {
      expect(
        reported(
          'class C {\n'
          '  bool get shouldRun => true;\n'
          '  bool get hasRun => true;\n'
          '}',
          prefixes: <String>['should'],
        ),
        <String>{'hasRun'},
      );
    });
  });

  group('a getter named as a question must be boolean', () {
    test('[partition] `int get isCount` is reported', () {
      expect(reported('class C {\n  int get isCount => 1;\n}'), <String>{
        'isCount',
      });
    });

    test('[partition] `Future<int>` is not boolean', () {
      expect(
        reported('class C {\n  Future<int> get hasCount async => 1;\n}'),
        <String>{'hasCount'},
      );
    });

    test('[error-guessing] a prefixed `bool` is a different type', () {
      expect(
        reported(
          "import 'other.dart' as o;\n"
          'class C {\n  o.bool get isOther => throw 0;\n}',
        ),
        <String>{'isOther'},
      );
    });

    test('[error-guessing] `Future<bool, int>` is not `Future<bool>`', () {
      expect(
        reported('class C {\n  Future<bool, int> get isOdd => throw 0;\n}'),
        <String>{'isOdd'},
      );
    });

    test('[error-guessing] `Future<List<bool>>` is not boolean', () {
      expect(
        reported('class C {\n  Future<List<bool>> get isAll => throw 0;\n}'),
        <String>{'isAll'},
      );
    });
  });

  group('a method named as a question with no parameters is reported', () {
    test('[partition] `bool isReady()` should be a getter', () {
      expect(reported('class C {\n  bool isReady() => true;\n}'), <String>{
        'isReady',
      });
    });

    test('[partition] an abstract `Future<bool> isAvailable()` too', () {
      expect(
        reported('abstract class C {\n  Future<bool> isAvailable();\n}'),
        <String>{'isAvailable'},
      );
    });

    test('[partition] a top-level function too', () {
      expect(reported('bool _hasFlutter() => true;'), <String>{'_hasFlutter'});
    });

    test('[partition] even without a return type', () {
      expect(reported('class C {\n  canRun() => true;\n}'), <String>{
        'canRun',
      });
    });
  });

  group('left alone', () {
    test('[decision] a method with parameters cannot be a getter', () {
      expect(
        reported(
          'class C {\n'
          '  bool isAtLeast(int other) => true;\n'
          '  bool hasAny({int? count}) => true;\n'
          '}',
        ),
        isEmpty,
      );
    });

    test('[decision] a generic method cannot be a getter', () {
      expect(reported('class C {\n  bool isA<T>() => this is T;\n}'), isEmpty);
    });

    test('[decision] a method not named as a question', () {
      expect(reported('class C {\n  bool validate() => true;\n}'), isEmpty);
    });

    test('[decision] fields, whatever their names', () {
      expect(
        reported(
          'class C {\n'
          '  final bool enabled = true;\n'
          '  final int isCount = 1;\n'
          '}',
        ),
        isEmpty,
      );
    });

    test('[decision] a local function cannot be a getter', () {
      expect(
        reported('void f() {\n  bool isReady() => true;\n  isReady();\n}'),
        isEmpty,
      );
    });

    test('[decision] an `@override` takes its name from elsewhere', () {
      expect(
        reported(
          'class C {\n'
          '  @override\n'
          '  bool get wantKeepAlive => true;\n'
          '  @override\n'
          '  Future<bool> isAvailable() async => true;\n'
          '}',
        ),
        isEmpty,
      );
    });

    test('[decision] a getter without a return type is not classified', () {
      expect(
        reported(
          'class C {\n'
          '  get ready => true;\n'
          '  get isCount => 1;\n'
          '}',
        ),
        isEmpty,
      );
    });

    test('[decision] setters and operators', () {
      expect(
        reported(
          'class C {\n'
          '  set enabled(bool value) {}\n'
          '  set isOn(int value) {}\n'
          '  bool operator ==(Object other) => true;\n'
          '}',
        ),
        isEmpty,
      );
    });
  });

  test('[boundary] the report points at the declared name', () {
    const String source = 'class C {\n  bool get aborted => true;\n}';
    final List<LintViolation> violations = fixture.parsed(
      BoolGetterNaming(),
      source,
    );
    expect(violations.single.line, 2);
    expect(violations.single.column, 12);
    expect(violations.single.ruleName, 'bool_getter_naming');
  });
}
