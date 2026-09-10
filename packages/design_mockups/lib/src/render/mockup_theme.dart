import 'package:flutter/material.dart';

/// Puts the harness's font family and fallback chain on **every** text style
/// the theme carries.
///
/// [primaryFamily] null leaves each style's own family alone and only appends
/// the fallback — which is what an app that bundles its brand font wants, since
/// that font is the thing being photographed and only the glyphs it lacks
/// should fall through.
///
/// **Unless the family the theme names is not one the app bundles**, in which
/// case the fallback replaces it rather than sitting behind it.
///
/// This is the subtlest failure in the package and it was found by looking at
/// a render, not by a test. A theme that sets no font still names one: M3
/// typography fills in `Roboto`, which exists on a device and does not exist
/// in a headless test, so `flutter_test` substitutes its own font for it. A
/// fallback is only consulted for a character the primary **lacks**, and that
/// substitute *has* ASCII digits and a handful of CJK characters — so those
/// render as its filled rectangles while every other glyph falls through and
/// renders perfectly. The result is a screen that looks right except for `1`,
/// `4` and `一`, which reads as a corrupt asset rather than a missing font.
///
/// So a family is kept only when the app really shipped it (it appeared in
/// `FontManifest.json`, which [bundledFamilies] carries). Anything else is a
/// platform name standing in for a face that is not here, and appending to it
/// is appending to nothing.
///
/// `TextTheme.apply` reaches the body and display styles but **not** the
/// component themes that carry their own `TextStyle`. An `AppBar` title pulls
/// from `appBarTheme.titleTextStyle`, so a theme fixed only through
/// `textTheme` renders the whole app bar in the test font — solid boxes, at
/// the top of every single render. The component themes below are the ones
/// that own a text style and are reachable in a design mockup.
ThemeData applyMockupFonts(
  ThemeData base, {
  String? primaryFamily,
  required List<String> fallbackFamilies,
  Set<String> bundledFamilies = const <String>{},
}) {
  // `bodyMedium` stands for the theme: `ThemeData.fontFamily` and the
  // typography default both reach every style, so whatever the theme names is
  // here.
  final String? themeFamily = base.textTheme.bodyMedium?.fontFamily;
  final bool keepThemeFamily =
      themeFamily != null && bundledFamilies.contains(themeFamily);
  final String? family =
      primaryFamily ?? (keepThemeFamily ? null : fallbackFamilies.firstOrNull);
  // The primary is dropped from the chain behind it: a family listed as its
  // own fallback says nothing, and the rest of the chain is what actually
  // covers the glyphs it lacks.
  final List<String> fallback = fallbackFamilies
      .where((String name) => name != family)
      .toList();

  TextStyle? styled(TextStyle? style) => style?.copyWith(
    fontFamily: family ?? style.fontFamily,
    fontFamilyFallback: fallback,
  );

  TextTheme applied(TextTheme theme) =>
      theme.apply(fontFamily: family, fontFamilyFallback: fallback);

  final TextTheme textTheme = applied(base.textTheme);

  return base.copyWith(
    textTheme: textTheme,
    primaryTextTheme: applied(base.primaryTextTheme),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: styled(
        base.appBarTheme.titleTextStyle ?? textTheme.titleLarge,
      ),
      toolbarTextStyle: styled(
        base.appBarTheme.toolbarTextStyle ?? textTheme.bodyMedium,
      ),
    ),
    bottomNavigationBarTheme: base.bottomNavigationBarTheme.copyWith(
      selectedLabelStyle: styled(
        base.bottomNavigationBarTheme.selectedLabelStyle,
      ),
      unselectedLabelStyle: styled(
        base.bottomNavigationBarTheme.unselectedLabelStyle,
      ),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: styled(base.dialogTheme.titleTextStyle),
      contentTextStyle: styled(base.dialogTheme.contentTextStyle),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      contentTextStyle: styled(base.snackBarTheme.contentTextStyle),
    ),
    tooltipTheme: base.tooltipTheme.copyWith(
      textStyle: styled(base.tooltipTheme.textStyle),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: styled(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: styled(base.listTileTheme.subtitleTextStyle),
      leadingAndTrailingTextStyle: styled(
        base.listTileTheme.leadingAndTrailingTextStyle,
      ),
    ),
    // The M3 successor to `bottomNavigationBarTheme` above, and the one an M3
    // app actually sets. Its label style resolves per widget state, hence the
    // rebuild rather than a copy.
    navigationBarTheme: base.navigationBarTheme.copyWith(
      labelTextStyle: _styledResolved(
        base.navigationBarTheme.labelTextStyle,
        styled,
      ),
    ),
    navigationRailTheme: base.navigationRailTheme.copyWith(
      selectedLabelTextStyle: styled(
        base.navigationRailTheme.selectedLabelTextStyle,
      ),
      unselectedLabelTextStyle: styled(
        base.navigationRailTheme.unselectedLabelTextStyle,
      ),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelStyle: styled(base.tabBarTheme.labelStyle),
      unselectedLabelStyle: styled(base.tabBarTheme.unselectedLabelStyle),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: styled(base.chipTheme.labelStyle),
      secondaryLabelStyle: styled(base.chipTheme.secondaryLabelStyle),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      labelStyle: styled(base.inputDecorationTheme.labelStyle),
      floatingLabelStyle: styled(base.inputDecorationTheme.floatingLabelStyle),
      helperStyle: styled(base.inputDecorationTheme.helperStyle),
      hintStyle: styled(base.inputDecorationTheme.hintStyle),
      errorStyle: styled(base.inputDecorationTheme.errorStyle),
      prefixStyle: styled(base.inputDecorationTheme.prefixStyle),
      suffixStyle: styled(base.inputDecorationTheme.suffixStyle),
      counterStyle: styled(base.inputDecorationTheme.counterStyle),
    ),
    textButtonTheme: TextButtonThemeData(
      style: _styledButton(base.textButtonTheme.style, styled),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: _styledButton(base.filledButtonTheme.style, styled),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: _styledButton(base.elevatedButtonTheme.style, styled),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _styledButton(base.outlinedButtonTheme.style, styled),
    ),
  );
}

/// A `WidgetStateProperty<TextStyle?>` with [styled] applied to whatever it
/// resolves to, for the component themes that vary their label by state.
WidgetStateProperty<TextStyle?>? _styledResolved(
  WidgetStateProperty<TextStyle?>? property,
  TextStyle? Function(TextStyle?) styled,
) {
  if (property == null) {
    return null;
  }
  return WidgetStateProperty.resolveWith(
    (Set<WidgetState> states) => styled(property.resolve(states)),
  );
}

/// Null when the button theme sets no text style of its own, so the button
/// keeps inheriting the (already fixed) `textTheme` rather than being pinned
/// to a rebuilt style that says the same thing.
ButtonStyle? _styledButton(
  ButtonStyle? style,
  TextStyle? Function(TextStyle?) styled,
) {
  final WidgetStateProperty<TextStyle?>? textStyle = style?.textStyle;
  if (style == null || textStyle == null) {
    return style;
  }
  return style.copyWith(textStyle: _styledResolved(textStyle, styled));
}
