/// The annotation half of `design_mockups`, split out so that a widget in an
/// app's `lib/` can declare its own previews without importing the render
/// harness.
///
/// That split is not tidiness. The harness depends on `flutter_test`, so an
/// app takes it as a **dev** dependency; a `lib/` file importing a dev
/// dependency compiles locally and then fails for anyone consuming the app as
/// a package, and most projects lint against it outright. This package has no
/// dependencies at all, is a plain app dependency, and consists of `const`
/// annotation classes — which are unreferenced in a release build and shake
/// out of it.
library;

export 'src/mockup_preview.dart';
export 'src/mockup_sizes.dart';
