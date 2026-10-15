import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/runner/mutant_filter.dart';
import 'package:test/test.dart';

Mutant _mutant(int line, int offset, [String op = 'relational']) => Mutant(
  filePath: 'lib/a.dart',
  offset: offset,
  length: 1,
  line: line,
  column: 1,
  original: '<',
  replacement: '<=',
  operatorName: op,
  description: '< → <=',
);

void main() {
  final List<Mutant> mutants = <Mutant>[
    _mutant(1, 0),
    _mutant(2, 10),
    _mutant(2, 12),
    _mutant(2, 14, 'negation'),
    _mutant(3, 20),
    _mutant(5, 30),
  ];

  group('narrowMutants', () {
    test('[partition] with nothing given, keeps every mutant', () {
      expect(narrowMutants(mutants), mutants);
    });

    test('[partition] keeps only the mutants on the lines given', () {
      expect(
        narrowMutants(mutants, lines: <int>{2, 5}).map((Mutant m) => m.line),
        <int>[2, 2, 2, 5],
      );
    });

    test('[boundary] keeps at most --per-line on each line, in their '
        'original order', () {
      final List<Mutant> kept = narrowMutants(mutants, perLine: 1);

      expect(kept.map((Mutant m) => m.line), <int>[1, 2, 3, 5]);
    });

    test('[state] a line keeps the same mutants however they arrive — a '
        'resumed run must name the ones the journal recorded', () {
      final Mutant first = narrowMutants(mutants, perLine: 1)[1];
      final Mutant reversed = narrowMutants(
        mutants.reversed.toList(),
        perLine: 1,
      ).singleWhere((Mutant m) => m.line == 2);

      expect(reversed.offset, first.offset);
    });

    test('[partition] lines and per-line apply together', () {
      expect(
        narrowMutants(
          mutants,
          lines: <int>{2, 3},
          perLine: 2,
        ).map((Mutant m) => m.line),
        <int>[2, 2, 3],
      );
    });
  });
}
