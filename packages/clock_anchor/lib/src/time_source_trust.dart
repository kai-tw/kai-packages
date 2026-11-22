/// How hard it is to lie to a [TimeSource], ordered weakest first.
///
/// The ordering is load-bearing in two decisions and nowhere else: which
/// sample may replace a disagreeing anchor, and which sample may lower the
/// rollback watermark. Both exist because the adversary this package takes
/// seriously — the person holding the device — also controls its network.
///
/// See `TimeSourceTrustRank.isAtLeast` for the comparison; do not compare
/// `index` at a call site.
enum TimeSourceTrust {
  /// Plaintext, unauthenticated, trivially spoofable by whoever runs the
  /// network — SNTP over UDP is the whole category.
  ///
  /// Good enough to correct an honest device whose clock has drifted, which
  /// is the overwhelmingly common case. Worthless against someone who set
  /// the clock deliberately, because blocking port 123 or answering it costs
  /// them nothing. It may therefore never lower the watermark.
  unauthenticated,

  /// Carried inside an authenticated TLS session — an HTTP `Date` response
  /// header from a host whose certificate chain validated.
  ///
  /// Forging it needs a certificate the platform trust store accepts, which
  /// is a different order of effort from spoofing a UDP packet. Coarse: the
  /// header has one-second resolution.
  transportAuthenticated,

  /// A timestamp the remote service itself wrote and handed back — Firestore's
  /// `serverTimestamp`, a Drive file's `modifiedTime`.
  ///
  /// Strongest available here: authenticated in transit *and* not derived
  /// from anything this device said. It costs a round trip to a service the
  /// app is signed in to, so it is not always reachable.
  serverAttested,
}

/// Comparison for [TimeSourceTrust], so no call site reaches for `index`.
extension TimeSourceTrustRank on TimeSourceTrust {
  /// Whether this level is at least as strong as [other].
  bool isAtLeast(TimeSourceTrust other) => index >= other.index;

  /// Whether a sample at this level is allowed to lower the rollback
  /// watermark. Only transport-authenticated sources and above.
  bool get canLowerWatermark =>
      isAtLeast(TimeSourceTrust.transportAuthenticated);
}
