import 'built_rules.dart';
import 'config/dart_lints_config_exception.dart';
import 'lint_rule_base.dart';
import 'rule_descriptor.dart';
import 'rules/bloc/avoid_emit_after_await.dart';
import 'rules/bloc/avoid_repository_provider.dart';
import 'rules/bloc/prefer_cubit_over_bloc.dart';
import 'rules/bloc/prefer_named_subscription_callbacks.dart';
import 'rules/bloc/state_provides_copy_with.dart';
import 'rules/clean_arch/avoid_freezed_in_domain.dart';
import 'rules/clean_arch/avoid_layer_violation.dart';
import 'rules/clean_arch/avoid_shared_preferences_outside_owner.dart';
import 'rules/clean_arch/avoid_tool_imports_in_lib.dart';
import 'rules/clean_arch/domain_entity_suffix.dart';
import 'rules/clean_arch/domain_exception_extends_app_exception.dart';
import 'rules/clean_arch/domain_pure_dart_imports.dart';
import 'rules/core/avoid_bare_catch.dart';
import 'rules/core/avoid_catching_abstract_exception.dart';
import 'rules/core/avoid_catching_base_exception.dart';
import 'rules/core/avoid_catching_error.dart';
import 'rules/core/avoid_catching_object.dart';
import 'rules/core/avoid_empty_catch.dart';
import 'rules/core/avoid_high_cyclomatic_complexity.dart';
import 'rules/core/avoid_lint_suppression.dart';
import 'rules/core/avoid_multi_document_dartdoc.dart';
import 'rules/core/avoid_production_null_assertion.dart';
import 'rules/core/avoid_record_types.dart';
import 'rules/core/avoid_static_only_class.dart';
import 'rules/core/avoid_then_in_async.dart';
import 'rules/core/avoid_throwing_generic_exception.dart';
import 'rules/core/avoid_top_level_identifiers.dart';
import 'rules/core/avoid_unawaited_catch_error.dart';
import 'rules/core/avoid_unnecessary_rethrow.dart';
import 'rules/core/avoid_vague_type_words.dart';
import 'rules/core/avoid_void_async.dart';
import 'rules/core/avoid_while_true.dart';
import 'rules/core/failure_type_naming.dart';
import 'rules/core/interface_implementation_naming.dart';
import 'rules/core/prefer_positive_condition.dart';
import 'rules/core/public_class_names_its_file.dart';
import 'rules/core/sealed_family_naming.dart';
import 'rules/flutter/avoid_badge_wrapping_button.dart';
import 'rules/flutter/avoid_build_context_in_snack_bar.dart';
import 'rules/flutter/avoid_debug_only_api.dart';
import 'rules/flutter/avoid_hardcoded_color.dart';
import 'rules/flutter/avoid_listenable_mock.dart';
import 'rules/flutter/avoid_media_query_of.dart';
import 'rules/flutter/avoid_redundant_pop_callback.dart';
import 'rules/flutter/avoid_reserved_widget_suffix.dart';
import 'rules/getit/avoid_get_it_dependency_cycle.dart';
import 'rules/getit/restrict_sl_scope.dart';
import 'rules/log_system/avoid_unsafe_log_interpolation.dart';
import 'rules/log_system/log_error_requires_stacktrace.dart';
import 'rules/state_holder/state_holder_naming.dart';
import 'rules/state_holder/state_holder_role.dart';

/// Every rule this package ships, grouped into bundles.
///
/// A bundle names the framework family a rule's detection looks up — not the
/// concern it enforces. `core` needs nothing but Dart; `bloc` resolves
/// `Cubit` / `BlocBase`; `getit` resolves a service locator. A project enables
/// the bundles matching its stack, which is what lets one rule set serve an app
/// and a pure-Dart library without either inheriting the other's assumptions.
///
/// Bundles are strings, not an enum. The config speaks strings and this class
/// takes strings; an enum in between would be a second enumeration of one value
/// set, kept in step by hand.
class RuleRegistry {
  /// [extraRules] are a project's own, added to the ones this package ships.
  ///
  /// Dart cannot load code a compiled binary did not link, so a project that
  /// owns rules runs its own entry point (see [DartLintsCli]) and hands them
  /// in here. From that point they are rules like any other: enabled by
  /// bundle or by name, their options validated against what they declare,
  /// their names checked for typos.
  ///
  /// A name already taken by a built-in rule throws, rather than shadowing
  /// it: two rules answering to one name is the config saying one thing and
  /// meaning another.
  RuleRegistry({List<RuleDescriptor> extraRules = const <RuleDescriptor>[]})
    : all = <RuleDescriptor>[..._builtIn, ...extraRules] {
    final Set<String> builtInNames = _builtIn
        .map((RuleDescriptor d) => d.name)
        .toSet();
    for (final RuleDescriptor extra in extraRules) {
      if (builtInNames.contains(extra.name)) {
        throw DartLintsConfigException(
          'rule "${extra.name}" is already a rule of dart_lints — a project '
          'rule needs a name of its own',
        );
      }
    }
  }

  static final List<RuleDescriptor> _builtIn = <RuleDescriptor>[
    RuleDescriptor(
      name: 'avoid_bare_catch',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidBareCatch(),
    ),
    RuleDescriptor(
      name: 'avoid_catching_abstract_exception',
      bundle: 'core',
      options: <String, OptionKind>{
        'sanctionedBases': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => AvoidCatchingAbstractException(
        sanctionedBases: o['sanctionedBases'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_catching_base_exception',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidCatchingBaseException(),
    ),
    RuleDescriptor(
      name: 'avoid_catching_error',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidCatchingError(),
    ),
    RuleDescriptor(
      name: 'avoid_catching_object',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidCatchingObject(),
    ),
    RuleDescriptor(
      name: 'avoid_empty_catch',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidEmptyCatch(),
    ),
    RuleDescriptor(
      name: 'avoid_high_cyclomatic_complexity',
      bundle: 'core',
      options: <String, OptionKind>{
        'maxComplexity': OptionKind.integer,
        'exemptFlatDispatch': OptionKind.boolean,
      },
      requiredOptions: <String>{'maxComplexity'},
      create: (Map<String, Object?> o) => AvoidHighCyclomaticComplexity(
        maxComplexity: o['maxComplexity'] as int,
        exemptFlatDispatch: o['exemptFlatDispatch'] as bool? ?? false,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_lint_suppression',
      bundle: 'core',
      options: <String, OptionKind>{
        'generatedFiles': OptionKind.stringList,
        'sanctionedSuppressions': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => AvoidLintSuppression(
        generatedFiles: o['generatedFiles'] as List<String>?,
        sanctionedSuppressions: o['sanctionedSuppressions'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_multi_document_dartdoc',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidMultiDocumentDartdoc(),
    ),
    RuleDescriptor(
      name: 'avoid_production_null_assertion',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidProductionNullAssertion(),
    ),
    RuleDescriptor(
      name: 'avoid_record_types',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidRecordTypes(),
    ),
    RuleDescriptor(
      name: 'avoid_static_only_class',
      bundle: 'core',
      options: <String, OptionKind>{'exemptFiles': OptionKind.stringList},
      create: (Map<String, Object?> o) =>
          AvoidStaticOnlyClass(exemptFiles: o['exemptFiles'] as List<String>?),
    ),
    RuleDescriptor(
      name: 'avoid_then_in_async',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidThenInAsync(),
    ),
    RuleDescriptor(
      name: 'avoid_throwing_generic_exception',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidThrowingGenericException(),
    ),
    RuleDescriptor(
      name: 'avoid_top_level_identifiers',
      bundle: 'core',
      options: <String, OptionKind>{
        'scope': OptionKind.string,
        'exemptFiles': OptionKind.stringList,
        'exemptAnnotations': OptionKind.stringList,
        'exemptTypeSuffixes': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => AvoidTopLevelIdentifiers(
        scope: o['scope'] as String?,
        exemptFiles: o['exemptFiles'] as List<String>?,
        exemptAnnotations: o['exemptAnnotations'] as List<String>?,
        exemptTypeSuffixes: o['exemptTypeSuffixes'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_unawaited_catch_error',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidUnawaitedCatchError(),
    ),
    RuleDescriptor(
      name: 'avoid_unnecessary_rethrow',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidUnnecessaryRethrow(),
    ),
    RuleDescriptor(
      name: 'avoid_void_async',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidVoidAsync(),
    ),
    RuleDescriptor(
      name: 'avoid_vague_type_words',
      bundle: 'core',
      options: <String, OptionKind>{
        'forbiddenWords': OptionKind.stringList,
        'scopedWords': OptionKind.mapList,
      },
      create: (Map<String, Object?> o) => AvoidVagueTypeWords(
        forbiddenWords: o['forbiddenWords'] as List<String>?,
        scopedWords: o['scopedWords'] as List<Map<String, Object?>>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_while_true',
      bundle: 'core',
      create: (Map<String, Object?> o) => AvoidWhileTrue(),
    ),
    RuleDescriptor(
      name: 'failure_type_naming',
      bundle: 'core',
      options: <String, OptionKind>{
        'failureWord': OptionKind.string,
        'exemptSubtypesOf': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => FailureTypeNaming(
        failureWord: o['failureWord'] as String?,
        exemptSubtypesOf: o['exemptSubtypesOf'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'interface_implementation_naming',
      bundle: 'core',
      optIn: true,
      options: <String, OptionKind>{'style': OptionKind.string},
      requiredOptions: <String>{'style'},
      create: (Map<String, Object?> o) =>
          InterfaceImplementationNaming(style: o['style'] as String),
    ),
    RuleDescriptor(
      name: 'prefer_positive_condition',
      bundle: 'core',
      create: (Map<String, Object?> o) => PreferPositiveCondition(),
    ),
    RuleDescriptor(
      name: 'public_class_names_its_file',
      bundle: 'core',
      options: <String, OptionKind>{
        'acronyms': OptionKind.stringList,
        'exemptFiles': OptionKind.stringList,
        'familyFileSuffixes': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => PublicClassNamesItsFile(
        acronyms: o['acronyms'] as List<String>?,
        exemptFiles: o['exemptFiles'] as List<String>?,
        familyFileSuffixes: o['familyFileSuffixes'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'sealed_family_naming',
      bundle: 'core',
      create: (Map<String, Object?> o) => SealedFamilyNaming(),
    ),
    RuleDescriptor(
      name: 'avoid_badge_wrapping_button',
      bundle: 'flutter',
      create: (Map<String, Object?> o) => AvoidBadgeWrappingButton(),
    ),
    RuleDescriptor(
      name: 'avoid_buildcontext_in_snackbar',
      bundle: 'flutter',
      create: (Map<String, Object?> o) => AvoidBuildContextInSnackBar(),
    ),
    RuleDescriptor(
      name: 'avoid_debug_only_api',
      bundle: 'flutter',
      create: (Map<String, Object?> o) => AvoidDebugOnlyApi(),
    ),
    RuleDescriptor(
      name: 'avoid_hardcoded_color',
      bundle: 'flutter',
      options: <String, OptionKind>{'pathMarkers': OptionKind.stringList},
      create: (Map<String, Object?> o) =>
          AvoidHardcodedColor(pathMarkers: o['pathMarkers'] as List<String>?),
    ),
    RuleDescriptor(
      name: 'avoid_listenable_mock',
      bundle: 'flutter',
      options: <String, OptionKind>{
        'mockBase': OptionKind.string,
        'listenableTypes': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => AvoidListenableMock(
        mockBase: o['mockBase'] as String?,
        listenableTypes: o['listenableTypes'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_media_query_of',
      bundle: 'flutter',
      create: (Map<String, Object?> o) => AvoidMediaQueryOf(),
    ),
    RuleDescriptor(
      name: 'avoid_redundant_pop_callback',
      bundle: 'flutter',
      options: <String, OptionKind>{'popExpressions': OptionKind.stringList},
      create: (Map<String, Object?> o) => AvoidRedundantPopCallback(
        popExpressions: o['popExpressions'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_reserved_widget_suffix',
      bundle: 'flutter',
      options: <String, OptionKind>{
        'reservedSuffixes': OptionKind.mapList,
        'widgetSupertypes': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => AvoidReservedWidgetSuffix(
        reservedSuffixes: o['reservedSuffixes'] as List<Map<String, Object?>>?,
        widgetSupertypes: o['widgetSupertypes'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_freezed_in_domain',
      bundle: 'clean_arch',
      options: <String, OptionKind>{
        'featureRoots': OptionKind.stringList,
        'layers': OptionKind.stringList,
        'requiredBase': OptionKind.string,
      },
      create: (Map<String, Object?> o) => AvoidFreezedInDomain(
        featureRoots: o['featureRoots'] as List<String>?,
        layers: o['layers'] as List<String>?,
        requiredBase: o['requiredBase'] as String?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_layer_violation',
      bundle: 'clean_arch',
      options: <String, OptionKind>{
        'featureRoots': OptionKind.stringList,
        'layers': OptionKind.stringList,
        'exemptFiles': OptionKind.stringList,
        'packageName': OptionKind.string,
      },
      create: (Map<String, Object?> o) => AvoidLayerViolation(
        featureRoots: o['featureRoots'] as List<String>?,
        layers: o['layers'] as List<String>?,
        exemptFiles: o['exemptFiles'] as List<String>?,
        packageName: o['packageName'] as String?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_shared_preferences_outside_owner',
      bundle: 'clean_arch',
      options: <String, OptionKind>{'ownerPaths': OptionKind.stringList},
      create: (Map<String, Object?> o) => AvoidSharedPreferencesOutsideOwner(
        ownerPaths: o['ownerPaths'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_tool_imports_in_lib',
      bundle: 'clean_arch',
      options: <String, OptionKind>{
        'sourceRoot': OptionKind.string,
        'forbiddenRoot': OptionKind.string,
      },
      create: (Map<String, Object?> o) => AvoidToolImportsInLib(
        sourceRoot: o['sourceRoot'] as String?,
        forbiddenRoot: o['forbiddenRoot'] as String?,
      ),
    ),
    RuleDescriptor(
      name: 'domain_entity_suffix',
      bundle: 'clean_arch',
      options: <String, OptionKind>{
        'featureRoots': OptionKind.stringList,
        'layers': OptionKind.stringList,
        'domainLayer': OptionKind.string,
        'entityDirectory': OptionKind.string,
        'suffix': OptionKind.string,
        'forbiddenWords': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => DomainEntitySuffix(
        featureRoots: o['featureRoots'] as List<String>?,
        layers: o['layers'] as List<String>?,
        domainLayer: o['domainLayer'] as String?,
        entityDirectory: o['entityDirectory'] as String?,
        suffix: o['suffix'] as String?,
        forbiddenWords: o['forbiddenWords'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'domain_exception_extends_app_exception',
      bundle: 'clean_arch',
      options: <String, OptionKind>{
        'featureRoots': OptionKind.stringList,
        'layers': OptionKind.stringList,
        'baseClasses': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => DomainExceptionExtendsAppException(
        featureRoots: o['featureRoots'] as List<String>?,
        layers: o['layers'] as List<String>?,
        baseClasses: o['baseClasses'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'domain_pure_dart_imports',
      bundle: 'clean_arch',
      options: <String, OptionKind>{
        'featureRoots': OptionKind.stringList,
        'layers': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => DomainPureDartImports(
        featureRoots: o['featureRoots'] as List<String>?,
        layers: o['layers'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_emit_after_await',
      bundle: 'bloc',
      options: <String, OptionKind>{'stateHolderBase': OptionKind.string},
      create: (Map<String, Object?> o) =>
          AvoidEmitAfterAwait(stateHolderBase: o['stateHolderBase'] as String?),
    ),
    RuleDescriptor(
      name: 'avoid_repository_provider',
      bundle: 'bloc',
      options: <String, OptionKind>{
        'forbiddenProviders': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => AvoidRepositoryProvider(
        forbiddenProviders: o['forbiddenProviders'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'prefer_cubit_over_bloc',
      bundle: 'bloc',
      options: <String, OptionKind>{
        'discouragedBase': OptionKind.string,
        'preferredBase': OptionKind.string,
      },
      create: (Map<String, Object?> o) => PreferCubitOverBloc(
        discouragedBase: o['discouragedBase'] as String?,
        preferredBase: o['preferredBase'] as String?,
      ),
    ),
    RuleDescriptor(
      name: 'prefer_named_subscription_callbacks',
      bundle: 'bloc',
      options: <String, OptionKind>{'stateHolderBase': OptionKind.string},
      create: (Map<String, Object?> o) => PreferNamedSubscriptionCallbacks(
        stateHolderBase: o['stateHolderBase'] as String?,
      ),
    ),
    RuleDescriptor(
      name: 'require_cubit_suffix',
      bundle: 'bloc',
      options: <String, OptionKind>{
        'stateHolderBase': OptionKind.string,
        'requiredSuffix': OptionKind.string,
        'stateHolders': OptionKind.mapList,
        'stateSuffix': OptionKind.string,
      },
      create: (Map<String, Object?> o) => StateHolderNaming(
        name: 'require_cubit_suffix',
        roles: _roles(
          o,
          defaults: const <StateHolderRole>[
            StateHolderRole(
              base: 'Cubit',
              suffix: 'Cubit',
              stateTypeArgument: 0,
            ),
            StateHolderRole(base: 'Bloc', suffix: 'Bloc', stateTypeArgument: 1),
          ],
        ),
        stateSuffix: o['stateSuffix'] as String?,
      ),
    ),
    RuleDescriptor(
      name: 'require_notifier_suffix',
      bundle: 'riverpod',
      options: <String, OptionKind>{
        'stateHolders': OptionKind.mapList,
        'stateSuffix': OptionKind.string,
      },
      create: (Map<String, Object?> o) => StateHolderNaming(
        name: 'require_notifier_suffix',
        roles: _roles(
          o,
          defaults: const <StateHolderRole>[
            StateHolderRole(base: 'Notifier', suffix: 'Notifier'),
            StateHolderRole(base: 'AsyncNotifier', suffix: 'AsyncNotifier'),
            StateHolderRole(base: 'StreamNotifier', suffix: 'StreamNotifier'),
          ],
        ),
        stateSuffix: o['stateSuffix'] as String?,
      ),
    ),
    RuleDescriptor(
      name: 'state_provides_copywith',
      bundle: 'bloc',
      options: <String, OptionKind>{
        'stateBase': OptionKind.string,
        'stateSuffix': OptionKind.string,
        'domainSegment': OptionKind.string,
      },
      create: (Map<String, Object?> o) => StateProvidesCopyWith(
        stateBase: o['stateBase'] as String?,
        stateSuffix: o['stateSuffix'] as String?,
        domainSegment: o['domainSegment'] as String?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_getit_dependency_cycle',
      bundle: 'getit',
      options: <String, OptionKind>{'accessor': OptionKind.string},
      create: (Map<String, Object?> o) =>
          AvoidGetItDependencyCycle(accessor: o['accessor'] as String?),
    ),
    RuleDescriptor(
      name: 'restrict_sl_scope',
      bundle: 'getit',
      options: <String, OptionKind>{
        'accessor': OptionKind.string,
        'allowedSupertypes': OptionKind.stringList,
        'setupFiles': OptionKind.stringList,
        'providerTypes': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => RestrictSlScope(
        accessor: o['accessor'] as String?,
        allowedSupertypes: o['allowedSupertypes'] as List<String>?,
        setupFiles: o['setupFiles'] as List<String>?,
        providerTypes: o['providerTypes'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'avoid_unsafe_log_interpolation',
      bundle: 'log_system',
      options: <String, OptionKind>{
        'logger': OptionKind.string,
        'breadcrumbLevels': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => AvoidUnsafeLogInterpolation(
        logger: o['logger'] as String?,
        breadcrumbLevels: o['breadcrumbLevels'] as List<String>?,
      ),
    ),
    RuleDescriptor(
      name: 'log_error_requires_stacktrace',
      bundle: 'log_system',
      options: <String, OptionKind>{
        'logger': OptionKind.string,
        'levels': OptionKind.stringList,
      },
      create: (Map<String, Object?> o) => LogErrorRequiresStacktrace(
        logger: o['logger'] as String?,
        levels: o['levels'] as List<String>?,
      ),
    ),
  ];

  /// The state-holder roles a naming rule checks: `stateHolders` when set;
  /// otherwise the single base named by `require_cubit_suffix`'s older
  /// `stateHolderBase` / `requiredSuffix` options, when either is set;
  /// otherwise [defaults].
  static List<StateHolderRole> _roles(
    Map<String, Object?> options, {
    required List<StateHolderRole> defaults,
  }) {
    final List<Map<String, Object?>>? configured =
        options['stateHolders'] as List<Map<String, Object?>>?;
    if (configured != null) {
      return configured.map(StateHolderRole.fromMap).toList();
    }
    final String? base = options['stateHolderBase'] as String?;
    final String? suffix = options['requiredSuffix'] as String?;
    if (base == null && suffix == null) {
      return defaults;
    }
    return <StateHolderRole>[
      StateHolderRole(
        base: base ?? 'Cubit',
        suffix: suffix ?? 'Cubit',
        stateTypeArgument: 0,
      ),
    ];
  }

  /// Every rule this run knows: the built-in ones, then the project's.
  final List<RuleDescriptor> all;

  Set<String> get ruleNames => all.map((RuleDescriptor d) => d.name).toSet();

  Set<String> get bundleNames =>
      all.map((RuleDescriptor d) => d.bundle).toSet();

  /// The rules enabling [bundle] turns on — every rule in it but the
  /// [RuleDescriptor.optIn] ones.
  Set<String> bundleRules(String bundle) => all
      .where((RuleDescriptor d) => d.bundle == bundle && !d.optIn)
      .map((RuleDescriptor d) => d.name)
      .toSet();

  RuleDescriptor? byName(String name) =>
      all.where((RuleDescriptor d) => d.name == name).firstOrNull;

  /// Builds the rules in [names], each with the options [optionsFor] supplies,
  /// split by the pass that runs them.
  BuiltRules build(
    Set<String> names,
    Map<String, Object?> Function(String ruleName) optionsFor,
  ) {
    final List<LintRule> syntax = <LintRule>[];
    final List<ResolvedLintRule> resolved = <ResolvedLintRule>[];
    final List<ProjectLintRule> project = <ProjectLintRule>[];

    for (final RuleDescriptor descriptor in all) {
      if (!names.contains(descriptor.name)) {
        continue;
      }
      final Map<String, Object?> resolvedOptions = optionsFor(descriptor.name);
      for (final String required in descriptor.requiredOptions) {
        if (!resolvedOptions.containsKey(required)) {
          throw DartLintsConfigException(
            'rule "${descriptor.name}" requires option "$required"',
          );
        }
      }
      final Object rule = descriptor.create(resolvedOptions);
      switch (rule) {
        case final LintRule r:
          syntax.add(r);
        case final ResolvedLintRule r:
          resolved.add(r);
        case final ProjectLintRule r:
          project.add(r);
      }
    }

    return BuiltRules(syntax: syntax, resolved: resolved, project: project);
  }
}
