# dart_lints

Custom Dart lint rules, configured per repository.

Every rule lives in this package. A project decides — in one YAML file — which
areas of its tree exist, which rules govern each, and what those rules should be
told about its conventions. Adding or removing a rule in a project is a line of
configuration, not a change here.

```bash
dart run dart_lints                    # every area declared in dart_lints.yaml
dart run dart_lints --area=test        # one area
dart run dart_lints lib --fix          # a path, applying auto-fixes
dart run dart_lints --skip-analyze     # custom rules only
```

## Configuration

`dart_lints.yaml`, at the repository root. Every glob resolves relative to that
file's directory.

```yaml
analyzer:
  command: dart            # dart | flutter | none
  args: [--fatal-infos]    # see "Why args is its own key" below
  paths: []                # empty = the areas' paths

exclude:
  - "**/*.freezed.dart"
  - "**/*.g.dart"

# Dart files that belong to no area. Anything else uncovered is an error.
coverageIgnore: []

bundles: [core, flutter, clean_arch, bloc, getit, log_system]
enable: []                 # individual rules outside the enabled bundles

areas:
  production:
    paths: ["lib/**"]
  test:
    paths: ["test/**", "integration_test/**"]
    disable: [avoid_record_types]
    # enable / options / analyzer may also be overridden per area

options:
  avoid_layer_violation:
    featureRoots: [lib/features, lib/modules]
    layers: [domain, data, presentation]
```

### Bundles

A bundle names **the framework family a rule's detection looks up** — not the
concern it enforces. That is what lets one rule set serve an application and a
pure-Dart library without either inheriting the other's assumptions.

| Bundle | Rules | Looks up |
|---|---|---|
| `core` | 24 (one opt-in) | nothing but Dart |
| `flutter` | 8 | Flutter / Material types |
| `clean_arch` | 7 | a layered directory layout |
| `bloc` | 6 | `Cubit` / `Bloc` |
| `riverpod` | 1 | `Notifier` / `AsyncNotifier` / `StreamNotifier` |
| `getit` | 2 | a service locator |
| `log_system` | 2 | the `log_system` package |

A Riverpod project enables `riverpod` and neither `bloc` nor `getit`: those
rules resolve types it does not have, so they are dead weight rather than
silent gaps.

**A project's own rules** live in the project, not here: see *Rules a project
owns* below.

**Opt-in rules** sit in a bundle but are not switched on by it; only `enable:`
turns one on. A rule is opt-in when it needs a choice only the project can
make, which it declares as a required option — in the bundle's list it would
stop every project using the bundle until each made that choice.

### Naming rules

These enforce what a type's name claims: its family, its kind and its
category. A name is read as `<category words><kind word>`, split at case
changes, with an acronym kept as one word (`HTTPClientError` is `HTTP`,
`Client`, `Error`).

| Rule | Bundle | Checks |
|---|---|---|
| `sealed_family_naming` | `core` | a direct subtype of a `sealed` class starts with its category words and ends with its kind: `ConnectionFailure` → `ConnectionTimeoutFailure` |
| `failure_type_naming` | `core` | an `Error` subtype ends in `Error` and a class ending in `Error` is one; an `Exception` implementation ends in `failureWord` (`Exception`, the default, or `Failure`) and a class ending in it, or in `Exception`, is one. `exemptSubtypesOf` lists types whose subtypes are named by another scheme |
| `avoid_vague_type_words` | `core` | a type name must not *end* in `Manager`, `Helper`, `Util`, `Utils` — the last word has to name a kind, so `TaskManagerPage` is fine (`forbiddenWords` replaces the list); `scopedWords` forbids a word except on subtypes of listed types, e.g. `{word: Service, unlessExtends: [BackgroundService]}` |
| `interface_implementation_naming` | `core`, **opt-in** | an implementation of one of the package's own interfaces is named in the project's `style`, which is required: `impl` (`<Interface>Impl`), `tech_prefix` (`<Technology><Interface>`) or `impl_or_prefix` (either). A direct subtype of a `sealed` base is left to `sealed_family_naming`, which names it `<Category><Case><Kind>` |
| `avoid_reserved_widget_suffix` | `flutter` | a public widget does not end in `State`, `Cubit`, `Bloc`, `Notifier`, `Provider` or bare `Sheet`. A bare `Widget` is allowed; a project that forbids it lists it |
| `require_cubit_suffix` | `bloc` | a `Cubit` / `Bloc` ends in `Cubit` / `Bloc`, a class with either suffix is one, and its state type is `<Concept>State` (`stateSuffix`) — asked only of the class that writes the state type argument and is not a test double, and satisfied by a `typedef` under the name it is written with. `stateHolders` configures the roles |
| `require_notifier_suffix` | `riverpod` | the same for `Notifier`, `AsyncNotifier` and `StreamNotifier`, without the state-type check. A code-generated notifier reaches a `$`-prefixed generated base instead of `Notifier`, so no role matches it and it is not checked at all — name included, whether it is written `Todos` or `TodosNotifier` |
| `domain_entity_suffix` | `clean_arch` | a public class in `<feature>/domain/entities/` ends in `Entity`; enums are not checked. `entityDirectory`, `suffix` and `forbiddenWords` (say `[Data]`) are the project's |

⚠️ These are on by default in their bundles, so upgrading reports what an
existing codebase already has. Nothing here has a warning level or a baseline:
to adopt a rule over existing violations, disable it — in one area, or for the
whole project — until the renames land, and enable it again.

⚠️ `avoid_shared_preferences_outside_owner` reports **every**
`shared_preferences` import until its `ownerPaths` is set, so a repository
enabling `clean_arch` configures that option or disables the rule in an area.
The silent alternative — unconfigured means allow everything — would let the
rule pass while inert.

### Rules a project owns

A rule that only one application can possibly want belongs in that
application, not here. Dart links what it compiles, so such a rule cannot be
loaded into this package's binary at run time — the project runs **its own
entry point** instead, and hands its rules in:

```dart
// tool/lint.dart, in the project
import 'package:dart_lints/dart_lints.dart';

import 'lint_rules/analytics_param_namespace.dart';

Future<void> main(List<String> args) => DartLintsCli(
  name: 'tool/lint.dart',
  extraRules: <RuleDescriptor>[
    RuleDescriptor(
      name: 'analytics_param_namespace',
      bundle: 'app',
      create: (Map<String, Object?> options) => AnalyticsParamNamespace(),
    ),
  ],
).run(args);
```

```yaml
bundles: [core, flutter, app]   # `app` is the project's own
```

Run it as `dart run tool/lint.dart`, with the same arguments and the same
`dart_lints.yaml`. From there a project rule is a rule like any other: enabled
by bundle or by name, its options declared and validated, its name checked for
typos, `--fix` applied if it offers one. Implement `LintRule`,
`ResolvedLintRule` or `ProjectLintRule` — the same three this package's own
rules implement.

A project rule may not take the name of a built-in one: two rules answering to
one name would make the config say one thing and mean another, so it throws.

### Validation fails closed

A configuration fault stops the run with exit 2 before anything is analyzed.
There is no warning level, because a mistyped rule name that merely warned would
leave the rule disabled while the run still reported success — the one failure a
linter cannot detect about itself.

Checked: every rule, bundle and area name against the registry; every option key
against the rule that accepts it; every option value against the type that key
declares; and **every Dart file against the areas** — a file that no area claims
and `coverageIgnore` does not list is an error, not a silent skip.

That last check is per **file**, not per directory. A directory-level check
passes on `packages/*/lib/**` while `packages/x/bin/main.dart` matches nothing
and goes unlinted, which is exactly the shape that escapes notice.

Files git ignores are not scanned. In-repo worktrees are common enough that the
naive walk finds thousands of checked-out copies no area could sensibly claim —
on one repository, 5535 Dart files versus 2217 real ones.

### Why `args` is its own key

Linter diagnostics are INFO severity. Without `--fatal-infos`, `dart analyze`
prints every lint and still exits 0 — the rules become decoration. Keeping the
flags separate from the command is what stops that guarantee disappearing when a
project's analyzer step is edited.

`paths` is separate for the mirror-image reason: a project may want its custom
rules over a directory whose stock-analyzer errors it has not triaged yet, and
collapsing the two keys would force it to choose.

Left empty, the stock analyzer receives **the areas' own roots** — not the
repository root. That distinction is not cosmetic: a Flutter project's `build/`
holds hundreds of generated files that no `analysis_options.yaml` excludes by
default, and pointing the analyzer at the root reports every one of them.
Measured on one project, 912 of its 995 findings came from `build/` and 5 from
`lib/`. Set `paths` explicitly only to *narrow* further.

## The analyzer version pin

`analyzer: ">=10.0.0 <11.0.0"`. **Three independent constraints hold it there.**
Lifting one does not lift the pin:

1. **This package.** analyzer 12.0.0 removed `ClassDeclaration.name` and
   `.members`, which several rules use directly.
2. **A consuming app's codegen stack.** `build`, `freezed`, `json_serializable`,
   `source_gen` and `build_runner` all declare `analyzer <11.0.0`.
3. **`dart_style` 3.1.7** declares `analyzer >=10.0.0 <12.0.0`.

The rules that use the removed APIs have tests, so lifting the pin fails loudly
rather than silently changing behaviour.

One consequence worth knowing: a pinned older analyzer cannot parse syntax added
later. Rather than skip such a file quietly, the runner lists every file it could
not resolve and exits non-zero — an unlinted file otherwise reports no violations
and reads exactly like a clean one.

## Developing a rule

Local iteration does not need a tag:

```yaml
dev_dependencies:
  dart_lints:
    git: { url: …/kai-packages.git, path: packages/dart_lints, ref: dart_lints-v0.1.0 }

dependency_overrides:
  dart_lints: { path: ../kai-packages/packages/dart_lints }
```

Verified working: pub accepts a path override onto a workspace member from
outside that workspace. Drop the override and bump `ref` when the change lands.

Run `dart format` after `--fix`; save your open files first, since fixes are
written from the buffer the offsets were computed against.

## Adopting it

**Order matters when a repository already has a lint package.** Coverage
validation is fail-closed and per file, so an old `packages/<x>_lints/` still on
disk is dozens of Dart files that the new configuration does not claim — placing
`dart_lints.yaml` before deleting the old package fails immediately. Delete
first, or give the old tree a transitional area.

**Expect the violation count to rise, and read it carefully.** Rules whose scope
was hardcoded now take it from configuration, which usually means they cover
more than before. On one repository `avoid_hardcoded_color` went from 14 to 25 —
and 25 was exactly the number its own design documentation had recorded as
outstanding debt. Those 11 were never examined by the rule; they are not a
regression the migration introduced. Separate the two before triaging:

- **New coverage** — code this rule never looked at. Real findings.
- **Behaviour change** — the same code judged differently. Rare, and worth
  understanding before fixing.

**Some exemptions are the configuration's job, not the rule's.** Rules no longer
carry their own "is this a test file?" predicates: a second definition of that,
living beside the one a project already declares as an area, is free to drift
with nothing to catch the disagreement. Disable a rule in the area where it does
not apply.

Prefer disabling for a reason you can state. An exemption that exists because a
tool cannot express something is a different kind of debt from one that exists
because you decided — and only the second stays true a year later.
