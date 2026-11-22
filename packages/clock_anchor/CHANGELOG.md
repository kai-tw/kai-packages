# Changelog

## 0.2.0

**BREAKING**: two boolean getters are renamed so each reads as a yes-or-no
question.

- `StampRepairDecision.needsRepair` → `isRepairNeeded`
- `TimeSourceTrust.mayLowerWatermark` → `canLowerWatermark`

Behaviour is unchanged; rename at the call site.

## 0.1.0

First release.

The problem it exists for: `hybrid_logical_clock` makes ordering independent of
the wall clock, but three decisions around it are not — `HlcDto.toDomain()`'s
24-hour future ceiling is measured against the reader's own clock, signature
expiry is a real instant, and record age is a real duration. A device whose
clock is wrong decides all three wrongly, and the failure is silent in both
directions: two days fast and every peer rejects its writes, two days slow and
it rejects every peer's.

- **`ClockAnchorService`** — pins a remote time to a monotonic tick reading and
  derives every later answer from elapsed ticks, so the device clock is not a
  term in the expression. Adoption rules cover sample width, trust ordering and
  precision; readings are graded `unknown` / `deviceOnly` / `staleAnchor` /
  `anchored`.
- **`AnchoredClock`** — a `package:clock` `Clock`, which is the whole
  integration surface: `withClock` and no call site changes.
- **Sources** — `CallbackTimeSource` (a service the app already talks to),
  `HttpDateTimeSource` (a TLS `Date` header, with a hand-written parser for all
  three RFC 9110 forms), and `NtpTimeSource` in a separate library so `dart:io`
  stays out of the core. The SNTP client checks mode, leap indicator, stratum,
  a random nonce echo, and handles the 2036 era rollover.
- **`ClockIntegrity`** — rollback detection over a persisted watermark that
  never feeds a timestamp and can be pulled back down by a trusted anchor.
- **`StampRepairPolicy`** — finds stamps written while the clock was wrong,
  and refuses to act on an untrustworthy reading.

142 tests, including `test/hlc_integration_test.dart`, which runs against the
real `hybrid_logical_clock` rather than a stand-in: the claim being made is
about the two packages together.

Line coverage 100% (396/396); mutation score 96.7% (264/273, `dart_mutants`).

The nine survivors, individually verified rather than summarised — several by
directly applying the mutation and confirming the real suite still passes,
not just by reasoning about the code:

- **1**, `ClockAnchorService._trySample`'s trailing `return null;` — a true
  equivalent mutant: the function's return type is `Future<TimeSample?>`, so
  control falling off the end of an `async` function with a nullable return
  type already completes with `null`, identical to the explicit statement.
- **2**, `HttpDateTimeSource._parseRfc850`'s `if (shortYear < 0) { return
  null; }` — a true equivalent mutant, and provably so: `shortYear` comes from
  the `_rfc850` regex's year group, which is `(\d{2})` — exactly two ASCII
  digits, mandatory, not optional. `int.tryParse` on a string matching `\d{2}`
  can only ever produce a value in `[0, 99]`; `shortYear < 0` cannot be true
  for any input the regex accepts, so this branch is dead by construction, not
  merely hard to reach.
- **2**, `StampRepairPolicy.plan`'s `if (!now.isTrustworthy) { return <T>[];
  }` — a true equivalent mutant: `inspect()`, called on every element of the
  loop this guard would otherwise skip, has the identical check at its own
  top and returns `StampRepairDecision.defer()`, whose `needsRepair` is
  `false` (`action == StampRepairAction.repair` fails for `.defer`). With the
  outer guard removed, every record is still inspected, still yields
  `needsRepair == false`, and `plan` still returns `<T>[]` — the same value,
  by a different route.
- **3**, `NtpUdpExchange`'s teardown — `exchange()`'s `socket.close()`,
  `_firstReply`'s `if (event != RawSocketEvent.read) { return; }` guard, and
  `_firstReply`'s `await subscription.cancel();` — verified by applying each
  deletion in isolation and running `test/ntp_udp_exchange_test.dart` for
  real (all three still pass, not inferred): the Dart VM's own
  `_RawDatagramSocket` wires its `StreamController` with `onCancel: close`
  (`socket_patch.dart`), so cancelling the exchange's one subscription closes
  the socket as a side effect, and `exchange()`'s own explicit `close()` does
  the same independently — each of the two is redundant with the other, so
  deleting either alone leaves the other still closing the socket, and no
  test can tell the difference. The event guard is the same shape one level
  in: any event other than `.read` reaches `socket.receive()`, which returns
  `null` when nothing is buffered, and the very next line already returns
  early on a `null` datagram.

None of the nine is "hard to test and therefore accepted" — every one is a
provable equivalence (dead code by the language's own fall-through rule, by
what the regex can produce, or by a second, independently-sufficient path to
the same effect), checked against source rather than assumed from the shape
of the description `dart_mutants` prints.

⚠️ A tenth mutant in this same family — `NtpPacket.kissCode`'s `if (byte <
0x41 || byte > 0x5A)` swapped to `&&` — was *reported* undetected by a full,
24-file `dart_mutants` run across this package, but is not listed above
because it is not real: applying that exact mutation by hand and running
`test/ntp_packet_test.dart` directly **fails two tests** (a byte outside
`A`-`Z` no longer empties the kiss code — exactly the control-character
injection this check exists to stop). Re-running `dart_mutants` against that
one file in isolation scored it correctly (`41/41` detected). Cause was
`.dart_tool/test/incremental_kernel.*` — `dart test`'s own
incremental-compilation cache — not staying invalidated across the very fast,
very similar rewrites a mutation run does to one file in quick succession
across a large batch. **Fixed at the tool level in this same PR**
(`dart_mutants`' `TestCompilationCache`) — re-running the exact 24-file batch
that produced the false negative now scores `ntp_packet.dart` `41/41`, and
every other number in this entry unchanged.
