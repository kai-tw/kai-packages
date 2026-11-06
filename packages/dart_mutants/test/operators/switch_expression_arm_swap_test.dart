import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/mutation_visitor.dart';
import 'package:dart_mutants/src/operators/switch_expression_arm_swap.dart';
import 'package:test/test.dart';

List<Mutant> _mutate(String source, {String path = 'lib/foo.dart'}) {
  final ParseStringResult result = parseString(
    content: source,
    throwIfDiagnostics: false,
  );
  final MutationVisitor visitor = SwitchExpressionArmSwap().createVisitor(
    path,
    result.lineInfo,
    source,
  );
  result.unit.accept(visitor);
  return visitor.mutants;
}

void main() {
  test(
    '[partition] two arms propose each borrowing the other\'s result',
    () {
      const String source = '''
String f(int x) => switch (x) {
  1 => 'one',
  2 => 'two',
};
''';
      final List<Mutant> mutants = _mutate(source);
      expect(mutants, hasLength(2));
      final Set<String> mutated = mutants
          .map((Mutant m) => m.applyTo(source))
          .toSet();
      expect(
        mutated,
        containsAll(<String>[
          source.replaceFirst("'one'", "'two'"),
          source.replaceFirst("'two'", "'one'"),
        ]),
      );
    },
  );

  test(
    '[boundary] two arms with one result propose nothing — the swap would '
    'leave the code byte-identical, a survivor no test could catch',
    () {
      expect(
        _mutate('''
String f(int x) => switch (x) {
  1 => 'small',
  2 => 'small',
  _ => 'big',
};
''').map((Mutant m) => m.description),
        everyElement(isNot(contains("'small' replaced with 'small'"))),
      );
    },
  );

  test('[boundary] a single-arm switch expression has no neighbour', () {
    expect(
      _mutate('''
String f(int x) => switch (x) {
  _ => 'only',
};
'''),
      isEmpty,
    );
  });

  test(
    '[boundary] three arms cross-propose only adjacent pairs, not every '
    'pairing',
    () {
      // Arms (1,2) and (2,3) are adjacent; (1,3) is not. 2 pairs * 2
      // mutants each = 4, not the 6 a full combinatorial pairing would give.
      final List<Mutant> mutants = _mutate('''
String f(int x) => switch (x) {
  1 => 'a',
  2 => 'b',
  3 => 'c',
};
''');
      expect(mutants, hasLength(4));
    },
  );

  test('[boundary] a switch statement (not an expression) is untouched', () {
    expect(
      _mutate('''
void f(int x) {
  switch (x) {
    case 1:
      print('one');
    case 2:
      print('two');
  }
}
'''),
      isEmpty,
    );
  });

  test('[partition] a guard clause stays with its own arm, unswapped', () {
    const String source = '''
String f(int x) => switch (x) {
  int n when n > 0 => 'positive',
  int n => 'non-positive',
};
''';
    final Mutant mutant = _mutate(source).first;
    final String mutated = mutant.applyTo(source);
    expect(mutated, contains('int n when n > 0 =>'));
    expect(mutated, contains('int n =>'));
  });

  test(
    '[boundary] a switch expression nested as an arm\'s own value is '
    'visited too, not just the outermost one — the visitor must keep '
    'walking into arm bodies',
    () {
      const String source = '''
String f(int x, int y) => switch (x) {
  1 => switch (y) {
    1 => 'a',
    2 => 'b',
  },
  2 => 'c',
};
''';
      expect(_mutate(source), hasLength(4));
    },
  );
}
