import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/mutation_visitor.dart';
import 'package:dart_mutants/src/operators/ternary_swap.dart';
import 'package:test/test.dart';

/// Parses [source] syntactically and runs [TernarySwap] over it.
List<Mutant> _mutate(String source, {String path = 'lib/foo.dart'}) {
  final ParseStringResult result = parseString(
    content: source,
    throwIfDiagnostics: false,
  );
  final MutationVisitor visitor = TernarySwap().createVisitor(
    path,
    result.lineInfo,
    source,
  );
  result.unit.accept(visitor);
  return visitor.mutants;
}

void main() {
  test('[partition] a plain ternary proposes its branches swapped', () {
    final List<Mutant> mutants = _mutate('int f(bool a) => a ? 1 : 2;');
    expect(mutants, hasLength(1));
    final Mutant m = mutants.single;
    expect(
      m.applyTo('int f(bool a) => a ? 1 : 2;'),
      'int f(bool a) => a ? 2 : 1;',
    );
    expect(m.operatorName, 'ternary_swap');
  });

  test(
    '[boundary] a ternary whose two branches read the same proposes '
    'nothing — swapped, the code would be byte-identical',
    () {
      expect(_mutate('int f(bool a) => a ? 1 : 1;'), isEmpty);
    },
  );

  test('[boundary] a non-ternary conditional expression is untouched', () {
    expect(_mutate('bool f(bool a, bool b) => a && b;'), isEmpty);
  });

  test('[boundary] nested ternaries each propose their own swap', () {
    final List<Mutant> mutants = _mutate(
      'int f(bool a, bool b) => a ? (b ? 1 : 2) : 3;',
    );
    expect(mutants, hasLength(2));
  });

  test(
    '[partition] the applied mutant is a legal standalone edit, not just a '
    'string that looks right',
    () {
      const String source = "String f(bool a) => a ? 'yes' : 'no';";
      final Mutant mutant = _mutate(source).single;
      final String mutated = mutant.applyTo(source);
      expect(mutated, "String f(bool a) => a ? 'no' : 'yes';");
      // Re-parsing the mutated source should also find exactly one ternary,
      // proving the edit did not corrupt the surrounding syntax.
      expect(_mutate(mutated), hasLength(1));
    },
  );
}
