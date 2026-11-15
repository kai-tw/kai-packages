# log_system

Structured logging with a **redacted** crash-reporting egress.

Extracted from NovelGlide, where it had grown the parts that only show up once
an app has shipped: per-severity routing, a release-only egress gate, and a
redactor that stops an exception's `toString()` carrying user data into a crash
report.

## The whole API

```dart
LogSystem.init();                                   // once, at startup

LogSystem.debug('cache miss');
LogSystem.info('sync: round finished');
LogSystem.warning('sync: retrying', error: e, stackTrace: s);
LogSystem.error('sync: round failed', error: e, stackTrace: s);
LogSystem.fatal('db: unreadable', error: e, stackTrace: s);
```

Plus one seam an app may implement — a `LogSink`, its own destination, which
is also how its own tests see that a fault was logged. See
[Registering your own destination](#registering-your-own-destination).

The repository, the data sources and the redactor stay unexported: they are the
reason this package exists rather than a snippet, but a caller who has to
assemble them is a caller who can assemble them *wrong* — and getting the
crash-reporter egress wrong is the failure it was extracted to prevent.
Configuration is flags, not objects.

A `LogSink` is not an exception to that. It is a destination rather than a
collaborator in the graph, and what it receives has **already** crossed the
redaction boundary. Observing the egress and being able to widen it are
different powers, and only the second was ever what got withheld.

**Mutation testing.** `debug`, `info`, `warning` and `event` are marked
`@pragma('dart_mutants:diagnostic')`, so with `dart_mutants` 0.13.0 or later a
mutant that only touches one of those calls is listed and not scored: no test
that asserts a log string is needed. `error` and `fatal` are not marked, because
they report an error record to the crash reporter. A failure that is already
handled and needs no one's attention should be logged below `error`.

**Logging before `init` is a silent no-op.** Unit tests that construct
production types directly never stand up the app's wiring, and a log line must
not be why one of them throws. Do not "fix" this by asserting initialisation.

Calling `init` again **replaces** the wiring, which is a deliberate departure
from what `init` usually implies: an integration harness passes
`reportCrashes: false` to keep a test build off the real crash reporter, and
throwing on the second call would take that away.

### Flags

| flag | default | what it decides |
|---|---|---|
| `reportCrashes` | `true` | off wires no crash reporter at all. Every level then stays device-local. |
| `customKeys` | `{}` | stamped on the crash reporter as-is. **Bypasses redaction**, so only provably non-identifying values belong here — a commit sha, a release channel. |
| `deferredCustomKeys` | `null` | for a key needing a platform round-trip. Lands a moment after launch, so a crash in the first frames may miss it. |

### No Firebase at all

`init` needs `Firebase.initializeApp()` to have run, because setting the
collection flag means touching `FirebaseCrashlytics`. When it has not — an
integration harness booting the real graph against no backend — `init` detects
it (`Firebase.apps` is a registry read, safe before initialisation), wires the
console alone, and says so through the console.

Nothing for the app to branch on, and nothing to pass.

Neither obvious alternative works. **Throwing** would let a logging library
stop an app from starting, and would break the harness this case exists for.
**Asserting** is the same thing wearing a debug badge — it aborts the rest of
`init`, so the harness gets an exception *and* no logging. **Silence** would let
an app that simply forgot `initializeApp()` get no crash reporting and no
complaint.

⚠️ `init(reportCrashes: false)` is a different case: Firebase *is* there, and is
being told to stay quiet.

### The console never reaches a release build

`logger`'s default `DevelopmentFilter` wraps its whole decision in
`assert(() { … }())` — "In release mode ALL logs are omitted", in its own words
— so every level is dropped with asserts off, not just `debug`. There is no
flag for this and there was never anything for one to do.

Worth stating rather than assuming, because the sibling hazard looks identical
and is real: `FlutterError.presentError` in release goes to
`debugPrintStack(label: exception.toString())` → `print`, and `debugPrint` is
**not** assert-gated. Raw exceptions do reach logcat / oslog — that way, never
this one. See the framework-fatal section below.

## Severity routing

| level | console | crash reporter | host sink |
|---|---|---|---|
| `debug` | yes, and never in release | never | yes |
| `info` | yes | breadcrumb | yes |
| `warning` | yes | breadcrumb — never a fault entry | yes |
| `error` / `fatal` | yes | `recordError`, non-fatal / fatal | yes |
| `event` | yes | never | yes |

A breadcrumb is not a fault entry — it surfaces only alongside a later crash.
`info` and `warning` both produce one, and there is no flag to turn that off.
There was: `forwardInfo` gated `info` and not `warning`, which carries the
identical hazard, so switching it off looked like protection and was half of
one. **The message crosses verbatim at every level that reaches the reporter**,
and that is an authoring-time discipline — a lint that forbids interpolating
non-primitives into a log message — not something a runtime flag can fix.

`info` takes no error object on purpose: it describes an expected condition. An
exception worth keeping makes it a `warning` or an `error`.

## Redaction

Everything crossing to the crash reporter is reduced first, and no caller can
opt out. An exception arrives as a surrogate carrying its runtime type name
plus, for a few allow-listed types, one closed-vocabulary structural field:

| type | kept | dropped |
|---|---|---|
| `PlatformException` | `code`, when it looks like an opaque token | `message`, `details` |
| `SocketException` / `FileSystemException` / `OSError` | `errno` | `address`, `path`, `message` |
| everything else | type name only | everything |

The redactor never calls `toString()` on the untrusted original — it reads
`runtimeType` and typed getters only, so a hostile `toString()` can neither
leak through nor throw. The surrogate's own `toString()` **leads with the type
name** so the reporter's non-fatal grouping still separates distinct error
types instead of collapsing them into one issue (flutterfire #3310).

The arms cover `dart:io` and `package:flutter` only — types every consumer
already has. An arm for another package's exception would make that package a
dependency of everyone, so an app that wants a distinction preserved should
translate at its own boundary into a domain type whose **name** carries it:
`CloudOfflineException` reads better in a crash report than
`SocketException errno=61` anyway.

## Registering your own destination

```dart
final class FakeLogSink implements LogSink {
  final List<LogEntry> entries = <LogEntry>[];

  @override
  void emit(LogEntry entry) => entries.add(entry);
}
```

Four lines, and this package ships none of them on purpose: a test double
belongs to the suite that asserts on it. Shipping one would put its shape —
what it records, how a matcher reads it — in this package's public API, where
changing it becomes a breaking change for every consumer.

**In production**, pass it to `init` and it is wired *alongside* the console
and the crash reporter, never instead of them. An app routing logging into a
backend of its own does not thereby give up crash reporting.

```dart
LogSystem.init(sink: MyBackendSink());
```

**In a test**, build a sink-only instance and register it:

```dart
setUp(() => LogSystem.register(LogSystem.withSink(sink)));
tearDown(LogSystem.reset);
```

`withSink` forwards to the sink alone — no console, no reporter. It exists
because `init` is the wrong thing to call from a `setUp` whatever it is passed:
it reads the Firebase registry, reassigns `PlatformDispatcher.instance.onError`
process-wide, and logs a warning of its own. The `tearDown` is not optional —
without it one test's sink goes on recording into every later test in the same
process.

### A sink sees every level, and sees them redacted

Every level, including the two the crash reporter never receives. `debug` and
`event` are exactly the ones an app could not otherwise observe anywhere, and
a sink that inherited the reporter's column would show an app only the half of
its logging that was never in question. What reaches a sink is bounded by
redaction instead of by level.

`LogEntry.redactedError` is a `String?`, and it is what the crash reporter
would receive: a type name plus at most one closed-vocabulary structural field.
The raw object never arrives. A sink handed the original would be a way around
the redaction boundary — reintroduced by the very feature meant to make logging
observable — so the door is shut here rather than left to each host's
discretion.

The cost is real and it is the intended incentive. A test asserting *which*
failure was logged can only tell apart what the redactor can tell apart: the
exception's type and its `diagnosticCode`. A test that cannot distinguish two
failures is describing a pair of exceptions the crash reporter cannot
distinguish either — **split the type**, rather than wanting this field
widened.

`message`, `stackTrace` and an event's `parameters` pass through as-is, exactly
as they do to the reporter. The message discipline in the routing section
applies here for the same reason.

**A sink that throws does not break the call site.** The throw is captured into
the same discarded future a failing internal sink rejects, so it surfaces to a
zone handler rather than propagating out of `LogSystem.error(...)`. A sink is
app code this package does not control, and a log line must never be why the
line after it does not run.

## The two uncaught-error handlers

`init` installs both — `FlutterError.onError` and
`PlatformDispatcher.instance.onError` — so nothing is copied into an app's
bootstrap. Pass `installErrorHandlers: false` if the app installs its own, and
note that this means `init` **reassigns two global handlers**.

They live here because leaving them to each app is how two of them ended up
disagreeing about which uncaught errors count as crashes. Four judgements are
baked in:

**Release only, for `FlutterError.onError`.** In debug it already defaults to
`FlutterError.presentError`, so overriding it there reimplements the default —
and presenting *and* logging prints the same error twice while the reporter is
disabled. Installing it release-only also keeps `presentError` out of release
structurally: there `dumpErrorToConsole` takes the
`debugPrintStack(label: exception.toString())` branch, and `debugPrint` is not
assert-gated, so it would put the raw exception on logcat / oslog.

**`details.silent` decides fatal.** The framework sets it at the throw site —
"errors that could be triggered by environmental conditions (as opposed to
logic errors)"; the HTTP library sets it so a 404 on flaky wifi does not read
like a bug — and honours it in `dumpErrorToConsole`. FlutterFire's
`recordFlutterError` never looks at it, so its documented pattern files every
one of them as a crash. `fatal: true` feeds crash-free users, the number a
release is judged by.

**The async handler is never fatal.** It has no `silent` to consult and it
returns `true` — the app saying it has handled the error and will keep running.
Filing that as a crash contradicts the line above it.

**`details.exception` is passed, not `details`**, which is what drops `context`
and `informationCollector`: both are `DiagnosticsNode`s that can carry
widget-tree property values, such as a `Text` widget's content in an overflow
assertion.
