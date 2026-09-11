import 'dart:io';

import 'package:path/path.dart' as p;

/// Deletes `dart test`'s own incremental-compilation cache before each
/// mutant's test run.
///
/// Found empirically, not suspected: a mutant on `NtpPacket.kissCode` — an
/// `||` swapped to `&&`, guarding against a hostile NTP reply injecting
/// control characters into a log line — scored **undetected** by a full
/// 24-file run against `clock_anchor`. Applying that exact mutation by hand
/// and running the real suite directly failed two tests. Re-running this
/// package against just that one file scored it correctly. Same test
/// command, same file, same mutation — the only variable was how many other
/// mutants had already been written-tested-reverted against that package
/// beforehand in the same process.
///
/// The reproducible difference: `dart test` (via `package:test`) keeps a
/// persistent kernel under `<package>/.dart_tool/test/incremental_kernel.*`
/// to skip recompiling between runs. That is exactly the wrong cache to hold
/// across this package's own inner loop — mutating one file, testing,
/// reverting, mutating it again, over and over, very fast — because it is
/// designed to skip recompiling when a file *looks* unchanged, and its
/// invalidation was never built against "the same file rewritten to a
/// different small variant within the same second, dozens of times."
///
/// Not narrowed to matching the exact filename (its suffix is a
/// base64-encoded language-version marker, not something worth depending
/// on): the whole `.dart_tool/test/` directory is deleted and left for
/// `dart test` to rebuild, which it already does unprompted on a cache miss.
/// `flutter test` does not appear to populate this directory at all — no
/// `log_system` run reproduced the same class of false negative — but
/// clearing a directory that is not there is a no-op, so this runs
/// unconditionally rather than trying to detect which test command is in
/// use.
///
/// The cost is real: every mutant becomes a cold compile instead of an
/// incremental one. Accepted deliberately — this package's only product is
/// the score, and a fast wrong number is worse than a slow right one.
///
/// The obvious saving on that cost has already been measured, and came back
/// empty. Clearing once per *file* instead is cheaper — 0.2.7 measured
/// between 6% and 16% over `clock_anchor`, the spread being what three
/// per-mutant runs against one per-file run can actually support. Six full
/// runs across four clearing frequencies produced five byte-identical
/// verdict files, all four frequencies among them — which is a **null
/// result**, not a case against per-file: on that corpus per-file was
/// exactly as correct, and cheaper. It settles nothing either way because
/// there was no *verified* positive control: the `NtpPacket.kissCode` mutant
/// above — the only one known to have caught this — scores `detected` today
/// even with the cache never cleared. Whether any other mutant in that
/// corpus was sensitive is precisely what identical verdicts cannot tell
/// apart from the bug being gone.
///
/// So the clearing stays, and not because the measurement vindicated it. It
/// stays because what the runs establish is narrow — the bug does not
/// reproduce on this package, on this SDK, with the one mutant known to have
/// caught it no longer sensitive — and that is not the same as the bug being
/// gone. Note what that argument does **not** rest on: the failure guarded
/// against here is score-*deflating* (a killed mutant read as `undetected`),
/// which 0.2.1 reasons is the self-correcting direction, so this is caution
/// about an unreproduced bug rather than a severe direction.
///
/// Recorded so the next person to notice that saving knows the cheap
/// experiment is spent, and that claiming it needs a corpus holding a mutant
/// the frequencies actually disagree on. The full write-up is in `CHANGELOG.md`
/// under 0.2.7; the one verdict that did vary across those runs is the
/// README's known limitation on run-to-run reproducibility.
class TestCompilationCache {
  const TestCompilationCache(this.workingDirectory);

  /// Where the test command runs. `.dart_tool/test/` is resolved relative to
  /// this, matching [ProcessCommand]'s own default of the current process's
  /// working directory when this is `null`.
  final String? workingDirectory;

  /// Deletes the cache directory if present. Safe before it has ever been
  /// created — a fresh package, or a test command that does not use it — and
  /// safe to call before every single mutant.
  void clear() {
    final Directory dir = Directory(
      p.join(
        workingDirectory ?? Directory.current.path,
        '.dart_tool',
        'test',
      ),
    );
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }
}
