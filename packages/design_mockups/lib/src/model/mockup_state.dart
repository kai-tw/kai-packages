import 'package:flutter/widgets.dart';

/// Builds the widget to photograph. Plain `WidgetBuilder`: what varies between
/// states is the data the builder closes over, not its signature.
typedef MockupStateBuilder = WidgetBuilder;

/// One screen, under one condition, ready to mount.
///
/// [build] returns the **real insertion point** — the page as the app builds
/// it, chrome included — not a fragment in a borrowed `Scaffold`. A fixture
/// that wraps a body widget in its own scaffolding photographs something the
/// user never sees.
@immutable
class MockupState {
  const MockupState({required this.name, required this.build});

  /// Appears verbatim in the filename, so it has to read as a condition:
  /// `default`, `empty`, `loading`, `error`, `offline`, `no-screen-lock`.
  final String name;

  final MockupStateBuilder build;
}
