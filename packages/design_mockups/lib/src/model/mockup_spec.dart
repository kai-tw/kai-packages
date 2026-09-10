import 'dart:async';

import 'package:flutter/widgets.dart';

import 'mockup_screen.dart';

/// A named set of screens, rendered together by `render-mockups <slug>`.
@immutable
class MockupSpec {
  const MockupSpec({
    required this.slug,
    required this.screens,
    this.setUp,
    this.tearDown,
  });

  /// Matches the CLI argument and names the output subdirectory.
  final String slug;

  final List<MockupScreen> screens;

  /// Runs once before this spec's screens, for a fixture whose widgets need
  /// something installed first — a service-locator registration, a fake
  /// platform channel, a seeded store.
  ///
  /// A presentation widget takes its data as parameters, so most specs leave
  /// both of these null. A fixture that needs them is either mounting a real
  /// page wired through DI, or mounting something that should have been given
  /// a parameter instead.
  final Future<void> Function()? setUp;

  final FutureOr<void> Function()? tearDown;
}
