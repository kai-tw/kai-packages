import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_lints/src/lint_rule_base.dart';
import 'package:dart_lints/src/rules/core/prefer_positive_condition.dart';
import 'package:test/test.dart';

/// Parses [source] syntactically and runs the rule's visitor over it.
List<LintViolation> _lint(String source) {
  final ParseStringResult result = parseString(
    content: source,
    throwIfDiagnostics: false,
  );
  final PreferPositiveCondition rule = PreferPositiveCondition();
  final LintVisitor visitor = rule.createVisitor(
    'lib/foo.dart',
    result.lineInfo,
    source,
  );
  result.unit.accept(visitor);
  return visitor.violations;
}

String _inMethod(String body) =>
    'class C {\n  void m(int a, int b) {\n'
    '    $body\n  }\n}';

void main() {
  group('a two-armed negation is flagged', () {
    test('[boundary] `!=` in a ternary — the shape the rule exists for', () {
      expect(_lint(_inMethod('final int x = a != b ? 1 : 2;')), hasLength(1));
    });

    test('[partition] `!` in a ternary', () {
      expect(
        _lint(_inMethod('final int x = !a.isEven ? 1 : 2;')),
        hasLength(1),
      );
    });

    test('[partition] `is!` in a ternary', () {
      expect(
        _lint(_inMethod('final Object o = a is! String ? 1 : 2;')),
        hasLength(1),
      );
    });

    test('[partition] `if` with an `else` block', () {
      expect(
        _lint(
          _inMethod(
            'if (a != b) {\n      m(1, 2);\n    } else {\n'
            '      m(2, 1);\n    }',
          ),
        ),
        hasLength(1),
      );
    });

    test(
      '[error-guessing] parentheses around the condition do not hide it',
      () {
        expect(
          _lint(_inMethod('final int x = (a != b) ? 1 : 2;')),
          hasLength(1),
        );
      },
    );

    test('[error-guessing] each of two negated branches is its own report', () {
      expect(
        _lint(
          _inMethod(
            'final int x = a != b ? 1 : 2;\n'
            '    final int y = !a.isEven ? 1 : 2;',
          ),
        ),
        hasLength(2),
      );
    });
  });

  group('one arm, or a null check, is not this shape', () {
    test('[boundary] an early-return guard has no second arm', () {
      expect(_lint(_inMethod('if (a != b) {\n      return;\n    }')), isEmpty);
    });

    test('[boundary] `!= null` is the preferred spelling, in a ternary', () {
      expect(
        _lint(
          'class C {\n  void m(String? s) {\n'
          '    final int x = s != null ? 1 : 2;\n  }\n}',
        ),
        isEmpty,
      );
    });

    test('[partition] `!= null` in an `if`/`else`', () {
      expect(
        _lint(
          'class C {\n  void m(String? s) {\n    if (s != null) {\n'
          '      print(s);\n    } else {\n      print(1);\n    }\n  }\n}',
        ),
        isEmpty,
      );
    });

    test('[partition] `null !=` on the left is the same check', () {
      expect(
        _lint(
          'class C {\n  void m(String? s) {\n'
          '    final int x = null != s ? 1 : 2;\n  }\n}',
        ),
        isEmpty,
      );
    });

    test('[partition] an `else if` chain is a sequence, not a pair', () {
      expect(
        _lint(
          _inMethod(
            'if (a != b) {\n      m(1, 2);\n    } else if (a > b) {'
            '\n      m(2, 1);\n    }',
          ),
        ),
        isEmpty,
      );
    });

    test('[partition] a positive condition with both arms', () {
      expect(_lint(_inMethod('final int x = a == b ? 1 : 2;')), isEmpty);
    });

    test('[error-guessing] `isNotEmpty` is not a syntactic negation', () {
      expect(
        _lint(
          'class C {\n  void m(List<int> xs) {\n'
          '    final int x = xs.isNotEmpty ? 1 : 2;\n  }\n}',
        ),
        isEmpty,
      );
    });

    test(
      '[error-guessing] a negation nested inside `&&` is not the top level',
      () {
        expect(
          _lint(_inMethod('final int x = a > b && !a.isEven ? 1 : 2;')),
          isEmpty,
        );
      },
    );
  });
}
