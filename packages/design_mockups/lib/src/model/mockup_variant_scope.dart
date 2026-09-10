import 'package:flutter/widgets.dart';

import 'mockup_variant.dart';

/// Carries the variant down to the widget being photographed. The runner
/// installs it; `MockupVariant.of` reads it.
class MockupVariantScope extends InheritedWidget {
  const MockupVariantScope({
    required this.variant,
    required super.child,
    super.key,
  });

  final MockupVariant variant;

  @override
  bool updateShouldNotify(MockupVariantScope oldWidget) =>
      oldWidget.variant != variant;
}
