import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/runner/mutant_result.dart';
import 'package:dart_mutants/src/runner/mutant_verdict.dart';
import 'package:test/test.dart';

Mutant _mutant() => const Mutant(
  filePath: 'lib/src/foo.dart',
  offset: 40,
  length: 2,
  line: 5,
  column: 3,
  original: '&&',
  replacement: '||',
  operatorName: 'logical_operator_replacement',
  description: "'&&' -> '||'",
);

void main() {
  test(
    '[partition] toJson carries the mutant\'s own fields, not the whole '
    'object',
    () {
      final MutantResult result = MutantResult(
        mutant: _mutant(),
        verdict: MutantVerdict.undetected,
      );

      expect(result.toJson(), <String, Object?>{
        'filePath': 'lib/src/foo.dart',
        'line': 5,
        'column': 3,
        'operatorName': 'logical_operator_replacement',
        'description': "'&&' -> '||'",
        'verdict': 'undetected',
      });
    },
  );

  test(
    '[partition] an uncovered mutant says so, and only then — the key is '
    'absent rather than false everywhere else',
    () {
      expect(
        MutantResult(
          mutant: _mutant(),
          verdict: MutantVerdict.undetected,
          uncovered: true,
        ).toJson()['uncovered'],
        isTrue,
      );
      expect(
        MutantResult(
          mutant: _mutant(),
          verdict: MutantVerdict.undetected,
        ).toJson().containsKey('uncovered'),
        isFalse,
      );
    },
  );

  test(
    '[partition] a mutant that ran carries the budget it ran against; one '
    'that did not has no key at all',
    () {
      expect(
        MutantResult(
          mutant: _mutant(),
          verdict: MutantVerdict.timeout,
          timeout: const Duration(milliseconds: 31500),
        ).toJson()['timeoutSeconds'],
        31.5,
      );
      expect(
        MutantResult(
          mutant: _mutant(),
          verdict: MutantVerdict.invalid,
        ).toJson().containsKey('timeoutSeconds'),
        isFalse,
      );
    },
  );

  test(
    '[boundary] the verdict serialises as its enum name, not its index — '
    'index would silently renumber if the enum\'s declaration order ever '
    'changed',
    () {
      for (final MutantVerdict verdict in MutantVerdict.values) {
        final MutantResult result = MutantResult(
          mutant: _mutant(),
          verdict: verdict,
        );
        expect(result.toJson()['verdict'], verdict.name);
      }
    },
  );
}
