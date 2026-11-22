/// Reads the active network's OS-level metered capability.
///
/// Returns `true` when the active link is metered (cellular, a metered Wi-Fi
/// hotspot, or a VPN whose underlying transport is cellular), `false` when it
/// is unmetered, and `null` when the running platform exposes no metered
/// signal at all (desktop / web register no native handler) — in which case
/// the repository falls back to its connection-type heuristic.
///
/// Unexpected platform failures are deliberately NOT absorbed here: they
/// propagate so the repository (the caller) owns the error-isolation
/// decision.
///
/// Lives as its own seam — separate from `ConnectivityDataSource`, which
/// wraps `connectivity_plus` — so the repository can be tested against a
/// plain mock instead of a real platform channel.
///
/// Internal to this package, same as `ConnectivityRepositoryImpl` — not
/// exported. No consumer depends on this directly; they depend on
/// `ConnectivityRepository`, which is the seam this package actually
/// commits to.
abstract class ConnectivityMeteredDataSource {
  Future<bool?> get isActiveNetworkMetered;
}
