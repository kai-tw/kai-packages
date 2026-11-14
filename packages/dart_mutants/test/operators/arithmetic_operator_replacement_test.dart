import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/mutation_visitor.dart';
import 'package:dart_mutants/src/operators/arithmetic_operator_replacement.dart';
import 'package:test/test.dart';

List<Mutant> _mutate(String source, {String path = 'lib/foo.dart'}) {
  final ParseStringResult result = parseString(
    content: source,
    throwIfDiagnostics: false,
  );
  final MutationVisitor visitor = ArithmeticOperatorReplacement().createVisitor(
    path,
    result.lineInfo,
    source,
  );
  result.unit.accept(visitor);
  return visitor.mutants;
}

void main() {
  test('[partition] + and - swap with each other', () {
    const String source = 'int f(int a, int b) => a + b;';
    expect(
      _mutate(source).single.applyTo(source),
      'int f(int a, int b) => a - b;',
    );
    const String minus = 'int f(int a, int b) => a - b;';
    expect(
      _mutate(minus).single.applyTo(minus),
      'int f(int a, int b) => a + b;',
    );
  });

  test('[partition] * and / swap with each other', () {
    const String source = 'num f(num a, num b) => a * b;';
    expect(
      _mutate(source).single.applyTo(source),
      'num f(num a, num b) => a / b;',
    );
  });

  test('[boundary] exactly one replacement per operator, not the full set', () {
    // The reduced set is deliberate — see the class doc. `+` proposes only
    // `-`, never `*` or `/`.
    expect(_mutate('int f(int a, int b) => a + b;'), hasLength(1));
  });

  test('[boundary] the off-by-one shape is what this is for', () {
    const String source = 'int f(List<int> xs) => xs.length - 1;';
    expect(
      _mutate(source).single.applyTo(source),
      'int f(List<int> xs) => xs.length + 1;',
    );
  });

  test('[boundary] unary minus is not a binary expression', () {
    // `-a` is a PrefixExpression; mutating it to `+a` is not valid Dart.
    expect(_mutate('int f(int a) => -a;'), isEmpty);
  });

  test('[boundary] ~/ and % are not offered', () {
    expect(_mutate('int f(int a, int b) => a ~/ b;'), isEmpty);
    expect(_mutate('int f(int a, int b) => a % b;'), isEmpty);
  });

  test(
    '[boundary] string concatenation is proposed and left to the compile '
    'check — the AST cannot tell it from numeric +',
    () {
      const String source = "String f() => 'a' + 'b';";
      expect(
        _mutate(source).single.applyTo(source),
        "String f() => 'a' - 'b';",
      );
    },
  );

  test(
    '[boundary] a nested binary expression is visited too, not just the '
    'outermost one — the visitor must keep walking into its operands',
    () {
      const String source = 'int f(int a, int b, int c) => a + (b - c);';
      expect(_mutate(source), hasLength(2));
    },
  );
}
