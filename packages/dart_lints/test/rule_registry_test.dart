import 'package:dart_lints/src/built_rules.dart';
import 'package:dart_lints/src/config/dart_lints_config_exception.dart';
import 'package:dart_lints/src/rule_registry.dart';
import 'package:test/test.dart';

void main() {
  group('a rule with a required option', () {
    final RuleRegistry registry = RuleRegistry();

    test(
      '[boundary] enabling it without the option throws a config error '
      'naming the rule and the option, not a raw TypeError',
      () {
        expect(
          () => registry.build(
            <String>{'avoid_high_cyclomatic_complexity'},
            (String ruleName) => <String, Object?>{},
          ),
          throwsA(
            isA<DartLintsConfigException>().having(
              (DartLintsConfigException e) => e.message,
              'message',
              allOf(
                contains('avoid_high_cyclomatic_complexity'),
                contains('maxComplexity'),
              ),
            ),
          ),
        );
      },
    );

    test('[partition] supplying it builds the rule with no error', () {
      final BuiltRules built = registry.build(
        <String>{'avoid_high_cyclomatic_complexity'},
        (String ruleName) => <String, Object?>{'maxComplexity': 6},
      );
      expect(built.syntax, hasLength(1));
    });

    test(
      '[boundary] a rule with no required options is unaffected by an '
      'empty options map',
      () {
        final BuiltRules built = registry.build(
          <String>{'avoid_bare_catch'},
          (String ruleName) => <String, Object?>{},
        );
        expect(built.syntax, hasLength(1));
      },
    );
  });

  group('an opt-in rule', () {
    final RuleRegistry registry = RuleRegistry();

    test('[decision] is registered, but enabling its bundle leaves it off', () {
      expect(registry.byName('interface_implementation_naming'), isNotNull);
      expect(
        registry.bundleRules('core'),
        isNot(contains('interface_implementation_naming')),
      );
      expect(registry.bundleRules('core'), contains('sealed_family_naming'));
    });

    test('[boundary] enabled by name without its style, it is a config '
        'error naming the option', () {
      expect(
        () => registry.build(
          <String>{'interface_implementation_naming'},
          (String ruleName) => <String, Object?>{},
        ),
        throwsA(
          isA<DartLintsConfigException>().having(
            (DartLintsConfigException e) => e.message,
            'message',
            contains('style'),
          ),
        ),
      );
    });
  });

  group('the state-holder naming rules', () {
    final RuleRegistry registry = RuleRegistry();

    test('[partition] one per framework bundle', () {
      expect(registry.bundleRules('bloc'), contains('require_cubit_suffix'));
      expect(registry.bundleRules('riverpod'), <String>{
        'require_notifier_suffix',
      });
    });

    test('[state] require_cubit_suffix still accepts its original options', () {
      final BuiltRules built = registry.build(
        <String>{'require_cubit_suffix'},
        (String ruleName) => <String, Object?>{
          'stateHolderBase': 'ViewModel',
          'requiredSuffix': 'ViewModel',
        },
      );
      expect(built.resolved.single.description, contains('ViewModel'));
    });
  });
}
