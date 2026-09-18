## 0.6.3

`interface_implementation_naming` no longer checks a direct subtype of a
`sealed` class. It and `sealed_family_naming` were asking the same declarations
for opposite word orders, and no name satisfied both.

A sealed base with no concrete member reads as one of this rule's interfaces,
so its members were asked for `<Base>Impl` or `<Distinguisher><Base>` — the
distinguishing word at an end. `sealed_family_naming` asks the same members for
`<Category><Case><Kind>`, with the case in the middle. Under a base
`ConnectionFailure`, the `ConnectionTimeoutFailure` the family rule asks for is
exactly what this rule rejected, and the `TimeoutConnectionFailure` this rule
accepted is what the family rule rejects. A project enabling both had members
it could not name.

A sealed base is closed, which makes it a family with members rather than an
interface with implementations, so the family rule owns those names and this
one steps back. Only the *direct* subtype steps out, which is the reach of
`sealed_family_naming`: a class further down implements an ordinary interface
of the family and is named here as any other implementation is.

## 0.6.2

`require_cubit_suffix` / `require_notifier_suffix` asked for the state name in
three places where the holder did not choose it and could not change it. All
three reported code whose only available fix was to make it worse.

- **A state written as a `typedef` is now read under the name it is written
  with.** The check compared the resolved element's name, which sees through
  the alias, so a holder declared `extends SharedListCubit<Foo, FooState>` —
  where `FooState` aliases a shared generic state — was told to name its state
  `FooState`, which is what every call site already writes. The alias or its
  target now satisfies it.
- **A test double is exempt, and the exemption is now reachable.** The dartdoc
  claimed a double implementing a holder was left alone, but a Dart double
  must `extends Cubit<S>` to function, which put the base back in its
  superclass chain and re-armed the check. The exemption now recognises the
  real shape: extends the base *and* implements a subtype of it. Narrowing the
  state instead is a compile error — a class cannot implement `StateStreamable`
  at two different states.
- **A subclass of a concrete holder is not asked for a state name.** `class
  RetryingFooCubit extends FooCubit` writes no type argument at all; it holds
  the `FooState` its parent named. The check now runs only where the class's
  own `extends` clause writes the state type.

Production code is unaffected: implementing a holder you are a sibling of, and
inheriting a state you did not parameterise, are not shapes a holder takes.

## 0.6.1

`avoid_vague_type_words` now checks only the **kind word** — the last one — so
a forbidden word earlier in a name passes. `SessionManager` is still reported;
`TaskManagerPage` and `ManagerId` are not.

The rule reads a name as `<category words><kind word>` like the other naming
rules, and only the kind word has to name a kind. Earlier words say *which*
thing, and there a word like `Manager` is often a feature's own name — a
`TaskManager` screen is a `TaskManagerPage`, a `Page`. Reporting it asked for
a rename that made the name worse.

Doc-comment examples in `public_class_names_its_file` are now invented names
rather than ones that read as a particular application's. No behaviour change.

## 0.6.0

**Naming rules.** A type's name should still say, away from its declaration,
which family it belongs to, what kind of thing it is and which one. Seven
rules check the parts of that a machine can decide. All but one are on by
default in their bundles, so **upgrading reports names an existing codebase
already has**; there is no warning level or baseline, so adopt a rule over
existing violations by disabling it in an area until the renames land.

New:

- `sealed_family_naming` (`core`): a direct subtype of a `sealed` class starts
  with the base's category words and ends with its kind word —
  `ConnectionFailure` → `ConnectionTimeoutFailure`. Words are split at case
  changes, an acronym staying one word, and compared whole: a prefix that
  matches only by characters does not count.
- `failure_type_naming` (`core`): a subtype of `Error` ends in `Error`, and a
  class ending in `Error` is one; an `Exception` implementation ends in
  `failureWord` — `Exception` (default) or `Failure`, one per project — and a
  class ending in that word, or in `Exception`, implements `Exception`.
  `exemptSubtypesOf` lists types whose subtypes are named by another scheme.
- `avoid_vague_type_words` (`core`): no `Manager`, `Helper`, `Util` or `Utils`
  in a class, mixin, enum, extension, extension type or typedef name.
  `forbiddenWords` replaces the list; `scopedWords` forbids a word except on a
  class that is, or extends or implements, one of the listed types.
- `interface_implementation_naming` (`core`, **opt-in**): an implementation of
  one of the package's own interfaces is named as the required `style` option
  says: `impl` (`<Interface>Impl`), `tech_prefix`
  (`<Technology><Interface>`) or `impl_or_prefix`, which accepts either — for
  a project that names a lone implementation `<Interface>Impl` and gives each
  of several a distinguishing word. `impl_or_prefix` deliberately does not
  count the implementations: two classes cannot share the `<Interface>Impl`
  name, so a second implementation must distinguish itself anyway, and
  counting would turn the first one red for a change in another file. An
  interface is a class declared `interface`, or abstract with no concrete
  instance member; `extends` counts as well as `implements`.
- `require_notifier_suffix` (new `riverpod` bundle): a `Notifier`,
  `AsyncNotifier` or `StreamNotifier` ends in that word, and a class ending in
  one is that type. The longest suffix a name ends in decides. Riverpod's
  generated notifiers extend a generated base and are not checked.
- `domain_entity_suffix` (`clean_arch`): a public class in a feature's
  `domain/entities/` ends in `Entity`. Enums are not checked;
  `entityDirectory`, `suffix` and `forbiddenWords` are options.

Changed:

- `require_cubit_suffix` now checks both directions — a `Cubit` or `Bloc`
  carries the suffix, and a class with the suffix is one — and that the state
  type, where it is a type of the project, is named for the holder:
  `ReaderSettingsCubit` holds a `ReaderSettingsState`. A class that only
  implements a cubit (a test double) is not held to the state name.
  `stateHolders` configures the roles and `stateSuffix` the state word;
  `stateHolderBase` / `requiredSuffix` still work, as one role.
- `avoid_reserved_widget_suffix` also reserves `Bloc`, `Notifier` and
  `Provider` by default. A bare `Widget` suffix stays allowed.

**A project can bring its own rules, and the `novelglide` bundle is gone.**
`DartLintsCli` is the whole command as a class, so a project writes a five-line
`tool/lint.dart`, passes its own `RuleDescriptor`s, and runs
`dart run tool/lint.dart` with the same arguments and the same
`dart_lints.yaml`. From there its rules are rules like any other: enabled by
bundle or by name, options declared and validated, names checked for typos.
Dart links what it compiles, so this hand-in is the only way a rule outside
this package can reach a run — there is no plugin loading to offer instead.

**Breaking:** the four `novelglide_*` rules and their bundle are removed. They
encode one application's conventions, which is exactly what a project now
keeps for itself; that application takes the rule files from this package's
0.5.3 tag into its own `tool/`. A project rule may not take a built-in rule's
name, which throws rather than shadowing it.

**Opt-in rules.** `RuleDescriptor.optIn` keeps a rule out of what its bundle
enables, for a rule with no defensible default: in the bundle's list, its
required option would stop every project using the bundle until each chose.

## 0.5.3

`avoid_high_cyclomatic_complexity` gains an opt-in `exemptFlatDispatch`
option (default `false`): a unit whose entire body — after any branch-free
leading local declarations — is exactly one exhaustive switch or try/catch,
with a branch-free scrutinee (or try body / `finally` block) and every arm
free of its own branch points, is never reported, however many arms it
has. Narrower and weaker-grounded than the `??` field-defaulting exemption
below: that one holds because `copyWith`'s branches are the same idiom
repeated, perfectly correlated. A flat dispatch's arms are usually
genuinely different behaviours instead — `icon => switch (this) { A =>
iconA, B => iconB, ... }` maps 8 enum values to 8 different icons, and a
wrong icon for `B` is an independent bug from a wrong icon for `A`. It
holds anyway, on two narrower grounds: Dart has no multi-type `catch`, so
an exhaustive catch-chain's arm count is a language-shape floor with no
lower-complexity equivalent to reach for; and a pure one-arm-per-value
mapping is exercised in full by one parametrized test over every enum
value, at the authoring cost of one. Deliberately does **not** tolerate a
leading guard (`if (cond) return;` before the dispatch) — split the guard
into its own method and let the flat dispatch be the whole of what
remains, rather than teaching this rule to tell a harmless guard apart
from a harmful one. Off by default: not exempting is the safe default
until validated project-by-project.

Adds `OptionKind.boolean` to the option-kind vocabulary
(`rule_descriptor.dart` / `dart_lints_config_loader.dart`) — the first
rule option of this shape; every other current option is a string, string
list, map list, or integer.

## 0.5.2

`avoid_high_cyclomatic_complexity` stops counting `??` when both sides are
simple access — a bare name, `this.field`, or one level of property access
off either, with no call and no further chaining. `field ?? this.field`,
repeated once per field, is a data class's entire `copyWith` body; unlike N
genuinely different conditions, those branches are not independent
evidence a test suite has to earn one at a time — a call with every field
provided covers every site's "use the new value" side at once, and a bare
`copyWith()` covers every site's "keep the old value" side at once. There
is no extract-method escape either: moving `field ?? this.field` into its
own one-line helper per field relocates the same total count, it does not
reduce it. Verified against 20 real `copyWith` methods: 14 now measure
within a reasonable ceiling; the remaining 6 still exceed it, correctly —
each has 10+ fields using the `T? Function()?` "clear-to-null" thunk
pattern (`field != null ? field() : this.field`), which is a ternary, not
a `??`, so this exemption never touches it. That third state (explicitly
clearing a field, as opposed to not providing it) is real, field-specific
behaviour a plain `??` cannot even express, and keeps its own branch point
exactly as before.

The moment either side is a call or two levels of property access deep
(`title.hashCode`, `this.title.abs()`), this is no longer "keep the field
unchanged" and counting reverts to normal — this is a narrow, structural
exemption for one specific idiom, not a general loosening of `??`.

## 0.5.1

0.5.0 broke `dart run dart_lints` entirely — not just the new rule — for
any consumer resolving analyzer <10. `avoid_high_cyclomatic_complexity`'s
`visitConstructorDeclaration` read `ConstructorDeclaration.typeName`,
which doesn't exist before analyzer 10; `dart_lints`'s own `pubspec.yaml`
allows `analyzer: ">=9.0.0 <11.0.0"`, so this was never actually
compatible with the floor of its own declared range, not an edge case
outside it. The failure was a compile error in the whole tool (exit 255),
not a silently-disabled rule — loud in the right direction, but it still
took the entire lint run down for that consumer, not just this one rule.

Fixed by reading `returnType` instead — deprecated in favor of `typeName`
on the analyzer versions that have both, but it is the only name that
resolves across the whole `>=9.0.0 <11.0.0` range, and non-nullable on
every version in it, so the fix is simpler than the code it replaces, not
just older. Verified directly against both analyzer 9.0.0's and 10.2.0's
own AST source (not assumed): every other analyzer API this rule uses —
the pattern-matching classes (`GuardedPattern`, `SwitchExpressionCase`,
`CaseClause`, `WildcardPattern`, `IfElement`, `ForElement`) and the three
`isNullAware` getters — already existed identically across the whole
range: `typeName` was the only rename between 9 and 10.

## 0.5.0

New rule: `avoid_high_cyclomatic_complexity`. Counts independent paths
through a function, method, constructor, or closure — `if`/`for`/`while`/
`do`/`catch`/switch `case`/`&&`/`||`/`??`/`?:`/null-aware access, plus a
pattern-match guard (`case ... when ...`) as one more on top of the branch
it guards — and reports when the total exceeds a configured
`maxComplexity`. This is the structural half of Savoia & Evans's CRAP
metric (`CC² × (1 − cov)³ + CC`): at 100% coverage the coverage term
vanishes and CRAP degenerates to plain CC, which is exactly what this rule
computes. The other half — per-function coverage — needs a format this
rule does not consume, so it stays out of scope until a coverage strategy
is chosen.

Every function-shaped node is its own unit, closures included: a branchy
callback passed to `.map` or a `builder:` is measured on its own, not
folded into whatever method happens to pass it along, so it cannot hide
there and cannot inflate a simple method's count either. `maxComplexity`
has no default — it is a required option, because the usual numbers (4-8)
assume 100% coverage, which a Flutter UI layer often cannot reach, and
`dart_lints.yaml`'s per-`areas` `optionOverrides` can already carry
different values per layer without any change to this rule. This is the
first rule with a genuinely required option, which surfaced a real gap:
omitting it used to reach the rule's constructor as a bare `null` and fail
as a raw `TypeError` instead of a config error naming the rule and the
option — the exact silent-failure shape `RuleDescriptor.options` exists to
prevent for a wrong-typed value, just not for an absent one.
`RuleDescriptor` now has `requiredOptions`, checked in `RuleRegistry.build`
against the fully area-resolved option view, so a project that enables
this rule without setting `maxComplexity` gets a clear
`DartLintsConfigException` instead.

Also new: `OptionKind.integer`, since no existing rule took a numeric
option — `maxComplexity` is the first.

## 0.4.6

`public_class_names_its_file` treated a `.design.dart` marker suffix as part
of the basename to match, so `welcome_view.design.dart` was compared against
the class name `welcome_view.design` — no class ever matches that, so every
`.design.dart` file reported "no public class names this file" regardless of
what was actually inside.

Fixed by stripping `.design.dart` as a unit before falling back to plain
`.dart`, so `welcome_view.design.dart` is now compared against `WelcomeView`
as intended. This is a basename adjustment, not an exemption — a stale class
left behind by a rename, or an unrelated second class, still reports inside
a `.design.dart` file exactly as it would in any other. Only the `.design`
marker is special-cased; a file like `foo.bar.dart` still loses only the
trailing `.dart`.

## 0.4.5

`avoid_layer_violation` never actually fired in any project that requires
`package:` imports — which is most of them. It compared the raw import URI
against a `lib/features/<feature>/<layer>/` path pattern, but no import URI
ever contains a literal `lib/`: a relative import omits the whole prefix, and
`package:` replaces it with the package name
(`package:myapp/features/x/domain/y.dart`, never
`package:myapp/lib/features/x/domain/y.dart`). Every cross-layer `package:`
import read as a no-op, silently — the rule reported nothing to say it had
never actually engaged, so it looked like a clean pass on codebases that had
never once been checked.

Fixed by giving `AvoidLayerViolation` a `packageName` so it can tell a self
`package:<name>/...` import (subject to the layer rules) from a dependency's
(never subject to them) and resolve the self case back to a `lib/`-relative
path before comparing. Relative imports are now resolved against the
importing file's own directory the same way. `DartLintsConfigLoader` reads
`packageName` from the project's own `pubspec.yaml` automatically, so an
existing `dart_lints.yaml` needs no changes to pick this up — `enable:
[avoid_layer_violation]` or the `clean_arch` bundle alone is enough for the
rule to start finding real violations it was always supposed to catch.
`options.avoid_layer_violation.packageName` still overrides the default,
for a pub workspace member whose own name differs from the config root.

## 0.4.4

`avoid_top_level_identifiers`'s own suggested fix was telling authors to
commit the exact antipattern `avoid_static_only_class` forbids: "namespace it
as a static method on a class with a private constructor" is precisely the
shape the other rule reports. Enabling both together meant fixing one
violation could immediately trip the other. The violation messages and class
doc now lead with an extension method, a member on the type it operates on,
or an enum for a closed set — the private-constructor class is a last resort,
and only onto a class that already exists for other reasons. No rule logic
changed, only the guidance text.

## 0.4.3

Dogfooding fixes: this package's own source tripped `public_class_names_its_file`
in 9 places, surfaced once `dart run dart_lints` started running over
`packages/*/lib/**` in CI. No rule logic changed — every fix is either a file
rename or a file split, same as the fix this rule already prescribes to any
other package's code.

- **File splits** — a companion type moved out to its own file, leaving the
  primary alone with the name that already matched:
  - `LintRunResult` (`lint_runner.dart`) → `src/lint_run_result.dart`.
  - `BuiltRules` (`rule_registry.dart`) → `src/built_rules.dart`.
  - `ReservedSuffix` (`avoid_reserved_widget_suffix.dart`) →
    `src/rules/flutter/reserved_suffix.dart`.
  - `ProcessRunner` / `SystemProcessRunner` (`stock_analyzer_runner.dart`) →
    `src/process_runner.dart` — an interface and its one implementation,
    split from the class that consumes both via constructor injection.
- **File renames**, class name unchanged — the file drifted from an
  already-correct class name, not the other way around:
  - `rules/bloc/state_provides_copywith.dart` →
    `state_provides_copy_with.dart`.
  - `rules/flutter/avoid_buildcontext_in_snackbar.dart` →
    `avoid_build_context_in_snack_bar.dart`.
  - `rules/getit/avoid_getit_dependency_cycle.dart` →
    `avoid_get_it_dependency_cycle.dart`.
  - `rules/novelglide/novelglide_prefer_loadingstatecode_over_bool.dart` →
    `novelglide_prefer_loading_state_code_over_bool.dart`.
- **New `exemptFiles` entry: `lint_rule_base.dart`.** This file is the rule
  SDK's own vocabulary — `SourceEdit`, `LintFix`, `LintViolation`, `LintRule`,
  `LintVisitor`, `ResolvedLintRule`, `ProjectUnit`, `ProjectLintRule`,
  `ResolvedLintVisitor` — nine types with no shared prefix and no subtype
  relation to fold under the rule's existing exemptions. Splitting it into
  nine one-class files would scatter a vocabulary a rule author reads
  together to satisfy a check whose actual purpose — a class findable from
  its filename — this file was never failing at in practice; the exemption
  says so explicitly rather than forcing the split anyway.

None of this is a public API break: every renamed or split file was already
`lib/src/`-internal, reached only through the `package:dart_lints/dart_lints.dart`
barrel, which now re-exports `built_rules.dart`, `lint_run_result.dart` and
`process_runner.dart` alongside the files it already exported.

## 0.4.2

- Fix `avoid_static_only_class`: a class that participates in a type hierarchy
  is no longer reported, however static its own declared members look. The
  rule was reading three genuine units of behavior as filing cabinets.

  `extends` and `with` bring instance members a syntactic visitor cannot see.
  Freezed is the common case — `abstract class X with _$X` receives `==`,
  `copyWith` and `toJson` through the mixin, so a freezed data type carrying a
  single static pre-decode validator read as all-static from the AST alone.
  The same held for a widget subclass whose only declared members are the
  static helpers its initializer list needs, `super(...)` running before any
  instance method exists to call.

  The third shape had no escape at all. The rule's prescribed exemption is
  bare `abstract`, and a `sealed` class cannot take it: `abstract sealed
  class` is a compile error ("a 'sealed' class can't be marked 'abstract'
  because it's already implicitly abstract"). A sealed root holding a static
  factory over its own family was therefore reported with no shape available
  to satisfy the message. Being extended by something in the same file now
  exempts a class as a hierarchy root — its constructor serves its subclasses'
  `super()` calls rather than blocking instantiation — and because Dart
  requires every subtype of a `sealed` class to live in that class's library,
  scanning the file settles the sealed case exhaustively rather than
  heuristically.

  The exemption stays narrow. A `sealed` or `abstract` class that nothing in
  its file extends is a root with no hierarchy under it, still a namespace and
  still reported; so is a subclass whose own members are all static, because
  being *in* a hierarchy is not the same as being the root of one. Found by a
  consumer auditing 36 hits, of which these 8 were false positives.

## 0.4.1

- Fix `public_class_names_its_file`: the subtype exemption now walks the
  supertype chain **transitively** within the file, instead of checking one
  hop. A `sealed` hierarchy nests — `AppNotificationEvent` ←
  `BookImportNotificationEvent` ← `BookImportSucceededNotificationEvent` — and
  Dart requires *every* descendant to live in the base's library, not just the
  direct children. The one-hop check reported those grandchildren as unowned
  siblings and told the reader to move a class the compiler refuses to let them
  move: acting on the message produced
  `invalid_use_of_type_outside_library`. Found by a consumer hitting exactly
  that compile error.

  The walk widens the exemption without disabling it — an unrelated class in
  the same file (one that reaches `Equatable` rather than the primary) is still
  reported, and a supertype cycle terminates rather than hanging.

## 0.4.0

- New `public_class_names_its_file` in the `core` bundle: one principle —
  **a file is named by the one public class it declares** — from which both
  halves follow. A second, unrelated public class means the filename names
  only part of what is inside, so neither class can be found by the name it
  is used under; a name that does not match means the file cannot be reached
  from the class at all. Grep-by-symbol is how a codebase of this size is
  navigated, and it degrades silently: nobody notices the file they failed to
  find.

  It also catches a typo class for free. `DownloaderManagerTaskListItemIcon`
  declared in `download_manager_task_list_item_icon.dart` reads as correct at
  every call site — the drift from its own feature name is visible only
  against the filename.

  Four exemptions, because the target is an unowned sibling, not co-location
  as such. A class whose name **starts with** the primary's is part of its
  contract (`ReaderGotoUseCase` + `ReaderGotoUseCaseParam`). A **subtype** of
  the primary is exempt because Dart *requires* a `sealed` hierarchy to share
  a library — the alternative is not a stricter codebase, it is `part` files.
  `acronyms` settles the house spelling of a compound token (`WebView` →
  `webview` rather than `web_view`); the rule does not decide which spelling
  is right, only that one is used. `familyFileSuffixes` marks files that
  deliberately hold a family rather than a class (`bookmark_exceptions.dart`)
  — still checked, in that a family file may hold only **one** family: two
  unrelated bases in it still report.

  Measured against NovelGlide's `lib/`: 1248 files declare a public class,
  1200 already comply, and 48 report — 9 filenames that no class answers to
  and 39 unowned siblings. Enums, mixins and extensions are out of scope;
  they accompany the class they serve far more often than they head a file,
  and folding them in would make the common case the exception.

- New `avoid_static_only_class` in the `core` bundle: reports a class where
  every non-constructor member is `static`. The stock
  `avoid_classes_with_only_static_members` lets the most common shape of the
  antipattern through, because **any** constructor exempts the class — so
  `class X { X._(); static void a() {} }`, a private constructor added
  specifically to block instantiation, reads to it as "has a constructor"
  rather than "holds no instance state at all".

  A bare `abstract` class with no constructor is exempt: the language already
  refuses to instantiate it, so there is no redundant workaround to close.
  One that declares a constructor anyway is still reported.

  Note it interacts with `avoid_top_level_identifiers`, whose prescribed fix
  is the shape this rule forbids. Running both is coherent only if the fix
  taken is the real one — an extension method, the entity the member
  describes, or an enum for a closed set — rather than a namespace class.

Both rules land in `core`, so a project already enabling that bundle turns
them on the moment it bumps this pin. Neither is auto-fixable; both name the
move in the violation message.

## 0.3.0

- New `avoid_multi_document_dartdoc` in the `core` bundle: flags a dartdoc
  block (a run of consecutive `///` lines) that contains a markdown heading
  (`##` or deeper).

  A heading inside a dartdoc is the author's own admission that the block
  carries more than one document. The fix is not to shorten it — it is to
  split each section onto the declaration it actually constrains: a class's
  contract stays on the class, one method's behavior goes on that method, a
  field's reason for existing goes on the field, and — for a method with
  several independent optional parameters — Dart supports a doc comment on
  each individual parameter, which IDE signature help then surfaces exactly
  at the call site.

  This is a narrow, high-precision smoke detector, not a length check. A
  length threshold was tried first (measured against NovelGlide's `lib/`:
  4494 comment blocks, 22870 lines) and rejected — some genuinely
  single-purpose contracts run long by nature, and a length rule cannot tell
  those apart from a real multi-document block. The heading signal is far
  rarer (17 of the 4494 blocks, all true positives on inspection) but much
  more deliberate: an author reaches for `##` specifically to separate
  sections. Lower recall, high precision.

  Enabling `core` in a project already running it turns this on immediately,
  with no separate opt-in — this repo's own `log_system` package had three
  hits once the rule went live here, all real: `LogSystem`'s class doc and
  `init`'s doc each had a `##`-headed section explaining one specific
  concern, and `LoggableException`'s class doc had one explaining a single
  field. All three are split onto the declaration they actually describe in
  this same release, so the rule ships with this repo already clean under it.

## 0.2.1

- `avoid_catching_abstract_exception` gains a `sanctionedBases` option: abstract
  exception types this configuration accepts, by name.

  Some libraries export only the abstract base and keep the concrete subclass in
  an unexported `src/` — `sqflite`'s `DatabaseException` is one — which leaves a
  consumer nothing narrower to name. Until now the only way through was to
  disable the rule for the file, which also excused every other abstract catch
  in it. Naming the type instead keeps the rest of the file governed.

  Pair it with an area whose paths name the one boundary that needs it. Set
  globally it excuses the type across the whole tree, which is a much weaker
  claim than "this file has no alternative":

  ```yaml
  areas:
    database_boundary:
      paths: ["lib/core/database/app_database.dart"]
      options:
        avoid_catching_abstract_exception:
          sanctionedBases: [DatabaseException]
  ```

  The rule also gains its first tests, covering the option and the two things
  it must not do: sanctioning one base leaves its siblings reported, and a
  typo in the list changes nothing in either direction.

- `avoid_hardcoded_color` no longer reports a `Color` built from a value the
  code did not write down — `Color(row.colour)`, `Color(int.parse(hex, radix:
  16))`, `Color.fromARGB(alpha, 0, 0, 0)`. Only a colour stated in the source is
  hardcoded, which is what the rule is named after and what every example in its
  own documentation shows.

  The rule matched on the constructor rather than on its arguments, so it also
  caught the one shape that has no fix: a colour the user picked and the app
  stored. `Theme.of(context).colorScheme.*` is not an alternative to reading a
  value out of a database, and a consuming project could only silence it by
  exempting the file — which then silences the real violations there too.

  An argument list built out of literals but computed (`Color(base + 1)`) counts
  as not-written-down. The rule cannot evaluate arithmetic, and the lenient
  direction is the right one: the miss is a colour someone obscured on purpose,
  while a false report names a fix that does not exist.

  Expect the count to fall in any project that stores colours. `Colors.X` and
  `.withOpacity()` are unaffected.

- The rule gains a test. It had none, and the fixture has to be a **resolved**
  unit — parsed, `Color(0xff112233)` is indistinguishable from a function call,
  so a parse-only fixture reports nothing and passes whatever the rule does.

## 0.2.0

- **Breaking.** `novelglide_avoid_shared_preferences_outside_preference` is
  replaced by `avoid_shared_preferences_outside_owner` in the `clean_arch`
  bundle, with the allowed paths moved from a hardcoded regex into an
  `ownerPaths` option.

  The rule was general all along — one owner for the key-value store, everyone
  else takes a typed repository — but its four owner paths were compiled in
  (`features/preference/`, `features/migration/processes/`,
  `core/setup_dependencies.dart`, `lib/main.dart`) and its registry entry
  ignored the options map entirely. A second app whose preference layer sits at
  `core/preferences/` could not use it: enabling it would report the new owner
  as the violation. The `novelglide_` prefix said "this encodes one
  application", and for the paths that was true; for the idea it never was.

  Migrating: rename the rule in `dart_lints.yaml`, move it out of the
  `novelglide` bundle list, and name your owner paths. NovelGlide's four
  hardcoded paths spell out as:

  ```yaml
  bundles: [core, flutter, clean_arch, bloc, getit, log_system, novelglide]

  options:
    avoid_shared_preferences_outside_owner:
      ownerPaths:
        - features/preference/
        - features/migration/processes/
        - core/setup_dependencies.dart
        - lib/main.dart
  ```

  Those four are the old rule's own list, and they still hold: at NovelGlide's
  `main` (`5b6c472a`) every Dart file importing the package sits under one of
  them — `core/setup_dependencies.dart`, four files in
  `features/migration/processes/`, and `features/preference/setup_dependencies.dart`.
  `lib/main.dart` no longer imports it at all, and is listed only for fidelity
  to what the rule used to allow.

  ⚠️ **This reaches every repository that enables `clean_arch`, not only the one
  that used the old rule.** `ownerPaths` defaults to empty, and empty means no
  file is an owner — so every `shared_preferences` import is reported until the
  option is set. That follows `avoid_hardcoded_color`'s reading of the same
  choice: a default that quietly excused the unconfigured case would let an
  enabled rule report success while doing nothing, which is the one failure a
  linter cannot report about itself. A repository with no preference layer to
  name disables the rule in its area rather than configuring it.

  `clean_arch` is the bundle because that is where the other import-against-
  directory rules already live (`domain_pure_dart_imports`,
  `avoid_layer_violation`, `avoid_tool_imports_in_lib`) — the detection looks up
  a layout, not a Flutter type.

## 0.1.1

- Widen the `analyzer` lower bound to `>=9.0.0` (was `>=10.0.0`).

  `riverpod_generator` skips the 10/11 line entirely — `<=4.0.3` wants
  `analyzer ^9`, `4.0.4-dev.1`+ wants `^12`, `4.0.6`+ wants `^13` — so a `>=10`
  floor made this package uninstallable in any Riverpod app. The floor was never
  this package's own requirement: it came from a comment citing `dart_style`,
  which is not a dependency here, so a consuming app's lockfile number had been
  written down as if it bound the package.

  Verified at 9.0.0: 131 tests, plus an end-to-end run whose resolved-AST rules
  resolved supertype chains and reported correctly.

## 0.1.0

- Initial release. 44 rules in seven bundles (`core`, `flutter`, `clean_arch`,
  `bloc`, `getit`, `log_system`, `novelglide`), selected and parameterised per
  repository through a root `dart_lints.yaml`.
