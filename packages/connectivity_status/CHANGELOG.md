## 0.3.0

**BREAKING**: `ConnectivityStatusPlatform.isActiveNetworkMetered` is now a
getter. It takes no arguments and answers a yes-or-no question, so it reads
as a property. A platform implementation overrides
`Future<bool?> get isActiveNetworkMetered` instead of the method, and a caller
drops the parentheses. The platform channel method keeps its name, so the
native side is unchanged.

## 0.2.0

**BREAKING** — `ConnectivityRepository.instance` and `.resetInstance()` are
gone, replaced by a plain factory constructor: `ConnectivityRepository()`
builds a fully-wired repository backed by the real platform adapters, and
this package takes no further view on whether the result is a singleton.
A device has exactly one real network state, but nothing about that
requires the *package* to enforce a single shared object — that's a DI
decision, and DI decisions belong to the app. Migrate:

```dart
// before
final repo = ConnectivityRepository.instance;

// after — build once, pass it down (or register the constructor with
// get_it / Riverpod exactly as you would any other dependency)
final repo = ConnectivityRepository();
```

**BREAKING** — `GetConnectivityUseCase.shared()` and
`ObserveConnectivityUseCase.shared()` are gone with it — there is no more
package-owned instance for them to wrap. Construct the repository once and
pass it to the plain constructors instead:

```dart
// before
final getConnectivity = GetConnectivityUseCase.shared();

// after
final connectivity = ConnectivityRepository();
final getConnectivity = GetConnectivityUseCase(connectivity);
```

**New: `ConnectivityRepository.exceptions`.** A `Stream<ConnectivityException>`
of every non-fatal fault this package catches internally. Each already has
a safe fallback in effect by the time it's emitted; this exists purely so a
consumer can log or react to it however it already does for its own errors
(this package has no logging dependency of its own — see 0.1.1). Never
emitted for an expected platform absence (desktop / web registering no
metered handler); that isn't a failure.

`ConnectivityException` is `sealed` and `implements Exception` — not
`extends Error`, since this is an expected, already-recovered-from
condition, not a programmer bug that should propagate to a zone handler.
Four concrete causes, each carrying the raw caught `exception` and
`stackTrace`:

- `ConnectivitySeedException` — the construction-time seed probe faulted.
- `ConnectivityStreamException` — the adapter's `observeConnectivity`
  stream itself emitted an error.
- `ConnectivityMeteredProbeException` — the native metered-probe channel
  faulted.
- `ConnectivityMeteredProbeTimeoutException` — the native metered-probe
  channel outran its timeout.

Being `sealed` makes a consumer's `switch` over these four an exhaustiveness
contract enforced at compile time, not a guess from a free-text message.

## 0.1.1

Dropped the `log_system` dependency. It was used only for diagnostic logging
around three already-handled fallback paths (a construction-time seed
fault, a stream error, a metered-probe fault/timeout) — each already
degrades to a safe fallback value on its own; the log calls were pure
observability, nothing in the control flow depended on them.

This wasn't just a dependency trim: `log_system` is a workspace `path:`
dependency, and an external consumer pulling `connectivity_status` via a
`git:` dependency has no way to pin it to anything but the exact commit
`log_system`'s own copy resolves to internally — no tag or branch works,
only a raw SHA. A network-status package has no good reason to carry that
constraint (or `log_system`'s own transitive `firebase_crashlytics` /
`firebase_core` weight) at all, so it's gone rather than worked around.

**Deployment floor drops to iOS 13.0** (was 15.0) — that floor existed only
because `log_system` pulled in Firebase, which requires iOS 15 via Swift
Package Manager. 13.0 is Flutter's own current floor; `connectivity_plus`
itself needs only 12.0.

Not a breaking change to this package's own public API — `LogSystem` was
never part of it, only an internal implementation detail of
`ConnectivityRepositoryImpl` and `ConnectivityMeteredDataSourceImpl`.

## 0.1.0

Initial extraction, from NovelGlide's connectivity system.

- `ConnectivityStatus` — the three-value network state (`offline` /
  `cellular` / `unmetered`) plus `isOnline`.
- `ConnectivityRepository` — one-shot `getStatus()` and a live
  `ValueStream` via `observeStatus()`, seeded synchronously so `.value`
  never throws.
- `ConnectivityRepository.instance` — the *only* way to get a repository.
  Built once, on first access, from the real `connectivity_plus` adapter and
  this package's own federated metered-probe plugin. There is no separate
  "build me a fresh one" constructor — a device has exactly one real network
  state, so every consumer, DI framework or none, reads the same shared
  instance. `@visibleForTesting ConnectivityRepository.resetInstance()`
  drops the cache — a test seam, same shape as `log_system`'s
  `LogSystem.reset()`.
- `GetConnectivityUseCase` / `ObserveConnectivityUseCase` — plain classes
  with a `call()` method, no shared `UseCase` base. Each also has a
  `.shared()` factory wrapping `ConnectivityRepository.instance`, for the
  zero-config path.
- Nothing behind the contract is exported: not `ConnectivityRepositoryImpl`,
  not the `ConnectivityDataSource` / `ConnectivityMeteredDataSource` adapters
  it's built from. A consumer's only name to spell is
  `ConnectivityRepository` itself, so it can't accidentally couple to the
  implementation instead of the contract.

Two deliberate shape choices, both about keeping the implementation out of
a consumer's way:

- Not a top-level function — `.instance` is a static member on
  `ConnectivityRepository` itself, so it stays discoverable from the type
  instead of adding a name to the package's flat namespace.
- Unlike `preference_store`'s `PreferenceRepository<T>`, this package hands
  back one finished assembly instead of leaving every consumer to re-derive
  it. `PreferenceRepository<T>` is a template — each domain (reader
  settings, TTS, …) instantiates it into its own shape, so there is no one
  correct wiring a package could hand back. `ConnectivityRepository` has no
  such variance: every consumer wants the exact same real data source and
  metered probe behind it.

Differences from the code it was extracted from:

- `AppDownloadPolicyUseCase` (NovelGlide's "download over Wi-Fi only"
  product policy) stayed behind — this package owns network-state plumbing,
  not one app's policy over it. `setupConnectivityDependencies()`
  (NovelGlide's GetIt registration) also stayed behind, but the assembly it
  did — building the real repository from the real adapters — is now
  `ConnectivityRepository.instance`, so NovelGlide's own wiring shrinks to
  one line registering that value, and CherishCRM's Riverpod provider can
  read it directly.
- The two use cases dropped their `extends UseCase<Return, Parameter>`
  inheritance from NovelGlide's app-local base class, so this package does
  not force a consumer into that convention.
- The metered probe's platform channel is renamed from
  `com.kai_wu.novelglide/connectivity_metered` to
  `net.kaiwu.connectivity_status/metered` — a shared package's channel name
  must not carry one consuming app's identity, and `net.kaiwu` (not
  `com.kai_wu`) is the current org identifier, matching CherishCRM's
  Android namespace and iOS bundle identifier.
- The native Swift/Kotlin, previously loose files manually registered from
  each app's `AppDelegate` / `MainActivity`, is now a proper federated
  plugin. `GeneratedPluginRegistrant` wires it automatically; no consumer
  needs a native registration call of its own.
