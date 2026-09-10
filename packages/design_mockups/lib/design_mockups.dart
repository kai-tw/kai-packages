/// A headless design-mockup renderer: it mounts an app's **real** widgets and
/// photographs them across breakpoint × state × theme × locale, writing PNGs
/// under `build/design-mockups/<slug>/` with no simulator and no device.
///
/// **What a render is for.** Not to check that a picture matches a spec — the
/// widgets under it *are* the shipped ones, so there is nothing to match. What
/// it catches is what no table can: whether the tokens read well *together*,
/// where a layout breaks at a band boundary, what a long CJK line does at text
/// scale 1.5, and whether dark mode survived.
///
/// Two things it is honest about:
///
/// - **It renders one frame.** An animation is photographed wherever it has
///   got to; anything whose problem is motion needs a device.
/// - **Glyph shapes are approximate unless the app bundles its own fonts.**
///   Line counts, overflow, wrapping and every layout decision are real, which
///   is what this phase is for; the exact face may be the harness's fallback
///   rather than the device's.
///
/// **Never import this from `lib/`.** It depends on `flutter_test`, so a
/// `lib/` import would drag test scaffolding into the app's release
/// compilation root. It belongs in `dev_dependencies`, imported from `tool/`
/// and `test/`. A widget that wants to declare its own previews imports
/// `package:design_mockups_annotations/design_mockups_annotations.dart`
/// instead — that package exists precisely so `lib/` never has to reach for
/// this one.
library;

export 'package:design_mockups_annotations/design_mockups_annotations.dart';

export 'src/config/mockup_harness_config.dart';
export 'src/fonts/host_font_candidates.dart';
export 'src/fonts/mockup_font_face.dart';
export 'src/fonts/mockup_font_family.dart';
export 'src/fonts/mockup_font_report.dart';
export 'src/fonts/mockup_fonts.dart';
export 'src/model/mockup_screen.dart';
export 'src/model/mockup_spec.dart';
export 'src/model/mockup_state.dart';
export 'src/model/mockup_variant.dart';
export 'src/model/mockup_variant_scope.dart';
export 'src/model/mockup_viewport.dart';
export 'src/render/mockup_settle.dart';
export 'src/render/mockup_theme.dart';
export 'src/render/render_engine.dart';
export 'src/runner/mockup_filters.dart';
export 'src/runner/mockup_runner.dart';
