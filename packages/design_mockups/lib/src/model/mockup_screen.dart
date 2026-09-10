import 'package:design_mockups_annotations/design_mockups_annotations.dart';
import 'package:flutter/widgets.dart';

import 'mockup_state.dart';

/// One screen of a spec, across the states and bands it declares.
@immutable
class MockupScreen {
  const MockupScreen({
    required this.name,
    required this.states,
    this.sizes = const <String>{MockupSizes.compact},
    this.textScale = 1.0,
  });

  /// Every state shares one builder, which switches on `MockupVariant.state`.
  /// The shorthand for a screen whose states differ only in the data one
  /// function already knows how to produce.
  MockupScreen.shared({
    required this.name,
    required MockupStateBuilder build,
    List<String> states = const <String>['default'],
    this.sizes = const <String>{MockupSizes.compact},
    this.textScale = 1.0,
  }) : states = <MockupState>[
         for (final String state in states)
           MockupState(name: state, build: build),
       ];

  /// Appears verbatim in the filename. Snake_case, no spaces.
  final String name;

  final List<MockupState> states;

  /// The bands this screen **restructures** at. A screen that only reflows
  /// lists `compact` and the one band that proves it — five near-identical
  /// PNGs are noise that hides the ones that differ.
  final Set<String> sizes;

  /// Register a second screen entry at 1.5 rather than adding a state: text
  /// scale changes the *layout*, not the condition being shown, and keeping it
  /// in the screen name is what makes "this one is the large-text check"
  /// readable from the filename alone.
  final double textScale;
}
