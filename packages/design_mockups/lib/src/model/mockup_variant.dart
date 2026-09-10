import 'package:flutter/widgets.dart';

import 'mockup_variant_scope.dart';
import 'mockup_viewport.dart';

/// Which band, which state, which brightness, which locale this one PNG is
/// for.
///
/// Reached through [MockupVariant.of] rather than passed as a second builder
/// parameter, because the overwhelming majority of builders do not want it: a
/// presentation widget takes its data as parameters and the theme carries the
/// brightness. Handing every builder an argument that one in twenty reads puts
/// an unused name in nineteen signatures, and `WidgetBuilder` is the type
/// Flutter already uses for exactly this. The one builder that genuinely has
/// to branch asks.
@immutable
class MockupVariant {
  const MockupVariant({
    required this.viewport,
    required this.state,
    required this.brightness,
    required this.locale,
    required this.textScale,
  });

  /// The variant being rendered.
  ///
  /// Throws outside a render rather than returning null: a builder that asks
  /// for the variant cannot do anything sensible without one, and a null here
  /// would surface far away as a missing state.
  static MockupVariant of(BuildContext context) {
    final MockupVariantScope? scope = context
        .dependOnInheritedWidgetOfExactType<MockupVariantScope>();
    if (scope == null) {
      throw FlutterError(
        'MockupVariant.of() was called outside a design-mockup render. It is '
        'available only below the harness, in a MockupState.build callback.',
      );
    }
    return scope.variant;
  }

  final MockupViewport viewport;

  /// The band id — the same string the screen listed in `sizes`.
  String get sizeId => viewport.id;

  /// The state name declared by the screen.
  final String state;

  final Brightness brightness;
  final Locale locale;

  /// The platform text scale this render is taken at.
  final double textScale;
}
