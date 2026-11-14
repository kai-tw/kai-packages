import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/mutation_operator.dart';
import 'package:dart_mutants/src/mutation_visitor.dart';
import 'package:dart_mutants/src/operators.dart';
import 'package:test/test.dart';

/// Every candidate mutant the full default operator set proposes for
/// [source], keyed by the operator that proposed it, before any compile
/// check: this is about what the pool can *see*, which is the property that
/// was missing.
Map<String, int> _mutantsByOperator(String source) {
  final ParseStringResult result = parseString(
    content: source,
    throwIfDiagnostics: false,
  );
  final Map<String, int> byOperator = <String, int>{};
  for (final MutationOperator operator in defaultOperators()) {
    final MutationVisitor visitor = operator.createVisitor(
      'lib/probe.dart',
      result.lineInfo,
      source,
    );
    result.unit.accept(visitor);
    if (visitor.mutants.isNotEmpty) {
      byOperator[operator.name] = visitor.mutants.length;
    }
  }
  return byOperator;
}

Set<String> _operatorsFor(String source) =>
    _mutantsByOperator(source).keys.toSet();

void main() {
  group('operator names are unique and stable', () {
    test('[boundary] no two operators share a name', () {
      final List<String> names = defaultOperators()
          .map((MutationOperator o) => o.name)
          .toList();
      expect(names.toSet(), hasLength(names.length));
    });

    test('[partition] every operator has a non-empty description', () {
      for (final MutationOperator operator in defaultOperators()) {
        expect(
          operator.description,
          isNotEmpty,
          reason: '${operator.name} has no description',
        );
      }
    });

    test('[partition] a mutant is attributed to the operator that made it', () {
      final ParseStringResult result = parseString(
        content: 'bool f(bool a, bool b) => a && b;',
        throwIfDiagnostics: false,
      );
      for (final MutationOperator operator in defaultOperators()) {
        final MutationVisitor visitor = operator.createVisitor(
          'lib/probe.dart',
          result.lineInfo,
          'bool f(bool a, bool b) => a && b;',
        );
        result.unit.accept(visitor);
        for (final Mutant mutant in visitor.mutants) {
          expect(mutant.operatorName, operator.name);
        }
      }
    });
  });

  group(
    'the constructs the pool used to be blind to now produce mutants',
    () {
      // This group is the regression guard for the gap that motivated the
      // deletion/negation operators. Each construct below was measured at
      // ZERO mutants under the four-operator pool — not because the code was
      // uninteresting, but because every operator in that pool asked "which
      // way did this expression go?" and none asked "did this line's effect
      // happen at all?". A Flutter `build()` is made largely of these.
      //
      // Asserting `isNotEmpty` rather than an exact count on purpose: the
      // property that matters is that the construct is *reachable* by some
      // operator, and pinning counts here would make this file churn every
      // time an operator's own reduced set is tuned.

      test('[partition] a bare guard — the setState case', () {
        expect(
          _operatorsFor('''
class W {
  void f() {
    if (mounted) {
      setState();
    }
  }
}
'''),
          containsAll(<String>['statement_deletion', 'condition_negation']),
        );
      });

      test('[partition] plain statements in a method body', () {
        expect(
          _operatorsFor('void f() { first(); second(); }'),
          contains('statement_deletion'),
        );
      });

      test('[partition] a compound condition', () {
        expect(
          _operatorsFor('bool f(bool a, bool b, bool c) => a && b || c;'),
          contains('logical_operator_replacement'),
        );
      });

      test('[partition] arithmetic', () {
        expect(
          _operatorsFor('int f(List<int> xs) => xs.length - 1;'),
          contains('arithmetic_operator_replacement'),
        );
      });
    },
  );

  group('the original four still cover what they always did', () {
    test('[partition] the ternary', () {
      expect(
        _operatorsFor("String f(bool a) => a ? 'x' : 'y';"),
        contains('ternary_swap'),
      );
    });

    test('[partition] null-coalescing', () {
      expect(
        _operatorsFor('String f(String? a) => a ?? "d";'),
        contains('null_coalescing_deletion'),
      );
    });

    test('[partition] a relational comparison', () {
      expect(
        _operatorsFor('bool f(int a, int b) => a <= b;'),
        contains('relational_operator_replacement'),
      );
    });

    test('[partition] a switch expression', () {
      expect(
        _operatorsFor('''
String f(Object x) => switch (x) {
  int() => 'int',
  _ => 'other',
};
'''),
        contains('switch_expression_arm_swap'),
      );
    });
  });

  test(
    '[boundary] a file with nothing mutable still yields nothing — the '
    'zero-mutant case has to stay reachable, or a caller cannot tell '
    '"no mutants" from "not scanned"',
    () {
      expect(
        _mutantsByOperator('String shout(String s) => s.toUpperCase();'),
        isEmpty,
      );
    },
  );
}
