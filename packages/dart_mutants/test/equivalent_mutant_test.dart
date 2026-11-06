import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/mutation_operator.dart';
import 'package:dart_mutants/src/mutation_visitor.dart';
import 'package:dart_mutants/src/operators.dart';
import 'package:test/test.dart';

List<Mutant> _proposed(String source) {
  final ParseStringResult result = parseString(
    content: source,
    throwIfDiagnostics: false,
  );
  final List<Mutant> mutants = <Mutant>[];
  for (final MutationOperator operator in defaultOperators()) {
    final MutationVisitor visitor = operator.createVisitor(
      'lib/probe.dart',
      result.lineInfo,
      source,
    );
    result.unit.accept(visitor);
    mutants.addAll(visitor.mutants);
  }
  return mutants;
}

void main() {
  test('[B3] a swap that leaves the code byte-identical is not proposed', () {
    final List<Mutant> mutants = _proposed(
      'int f(bool c) => c ? 1 : 1;\n'
      'int g(int x) => switch (x) { 0 => 7, _ => 7 };\n',
    );

    for (final Mutant m in mutants) {
      expect(m.replacement, isNot(m.original), reason: m.operatorName);
    }
    expect(
      mutants.where((Mutant m) => m.operatorName == 'ternary_swap'),
      isEmpty,
    );
  });

  test('[B3] a swap that changes the code is still proposed', () {
    final List<Mutant> mutants = _proposed('int f(bool c) => c ? 1 : 2;\n');

    expect(
      mutants.where((Mutant m) => m.operatorName == 'ternary_swap'),
      isNotEmpty,
    );
  });
}
