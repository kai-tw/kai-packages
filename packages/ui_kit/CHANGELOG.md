## 4.1.0

- `CommonErrorWidget` takes `dense`, passed straight to
  `CommonInfoWidget.dense`. An error inside a card or a section of a page
  could only be the full-screen placeholder before, so apps built their own
  small error layout for those spots. Defaults to `false`: existing callers
  render exactly as before.
- `CommonErrorSliverWidget` stays full-screen and doesn't take `dense`: it
  fills the rest of the viewport, which a small inline error shouldn't do.
  Put a dense `CommonErrorWidget` in a `SliverToBoxAdapter` instead.

## 4.0.0

- **BREAKING** — `CommonBadge.size` is renamed `CommonBadge.minSize`.

  3.1.0 shipped it a day earlier under a name that promised something
  Material does not do. `largeSize` reaches Material as the `minSize` of an
  intrinsic stadium, so a label bigger than the value wins: a default 24dp
  `Icon` renders a 24dp badge however small a `size` is asked for. The 3.1.0
  test asserted `18.0` and passed on a badge drawing 24px, and the dartdoc
  called it a diameter.

  **The fix is the name, not the behaviour.** Making it a fixed size would
  mean clamping the label, and growing to fit is the right thing for the
  labels a badge usually carries — `'99+'` has to fit. What was wrong was a
  parameter called `size` that could be exceeded. `minSize` is honest on both
  arms: the dot has no content, so its floor is always met exactly.

  **Adopters:** rename the argument. Nothing else changes — same behaviour,
  same defaults, same two Material dimensions selected by `type`. If you were
  relying on the value being the rendered size, give the label its own size
  too (`Icon(size: …)`), or measure with `tester.getSize`; there is a test in
  this package pinning both directions.

## 3.1.0

`CommonBadge` gains tone, size and a standalone form; `CommonNavTile` finally
forwards a badge label. All additive — no existing call changes.

Every item below came out of one feature (CherishCRM's record-sync conflict
marker), and each one had already forced a workaround at the call site, which
is the evidence that the widget was short of a parameter rather than that the
caller wanted something exotic.

- **`backgroundColor` / `foregroundColor`.** The fill was `colorScheme.error`
  and nothing else. Not every "there is something here" is an error: a mark
  that asks the user a question, or that reports a plain fact about the row,
  reads as a fault in red. It could not be corrected from outside either,
  because the colour comes from `Badge`'s own defaults rather than from
  anything in the ambient theme a call site controls.

- **`foregroundColor` resolves through `BadgeTheme`.** The ink is
  `foregroundColor ?? badgeTheme.textColor ?? colorScheme.onError`, mirroring
  Material's own three rungs. Skipping the middle one — which this change did
  at first — makes a `Text` label follow an ambient `BadgeTheme` while an
  `Icon` label falls to `onError`, so the two kinds of label diverge under
  exactly the configuration callers were told to use before 3.1.0.

- **`foregroundColor` reaches an `Icon` label.** `label` is typed `Widget?`,
  so an icon has always been a legal label — but Material's `Badge` puts its
  text colour on a `DefaultTextStyle` only and installs no `IconTheme`, so an
  icon label was drawn in whatever icon colour the surrounding tree carried,
  usually a dark `onSurface` on a saturated fill. Nothing warns; the glyph is
  just close to invisible, and each caller re-discovers the cause and passes a
  `color:` on the icon by hand. `CommonBadge` now merges an `IconTheme` around
  the label so the parameter means the same thing for both kinds.

- **`size`.** Material's defaults are 6.0 for the dot and 16.0 for a labelled
  badge, neither reachable through this widget. A 6dp dot on a 40dp avatar
  reads as a speck. Which Material dimension `size` sets follows from `type`,
  so the single parameter cannot be ambiguous: `smallSize` for `minimal`,
  `largeSize` for `normal`.

  ⚠️ **For a labelled badge it is a MINIMUM, not a diameter.** Material passes
  `largeSize` as the `minSize` of an intrinsic stadium, so a label bigger than
  `size` wins: a default 24dp `Icon` renders a 24dp badge however small a
  `size` is asked for. Size the label too, or measure the result. The dot has
  no content, so `smallSize` is exact. There is a test pinning this, because
  the first draft of the dartdoc called it a diameter and was wrong.

- **`padding`.** With `EdgeInsets.zero` and a square label, the badge's
  `StadiumBorder` renders as a circle rather than an oval — which is what an
  icon label almost always wants. Ignored when there is no label.

  Before these two, the only way to size a badge was to wrap the call site in
  a `BadgeTheme`, which works but means reaching around the widget to
  configure the widget.

- **`CommonBadge.standalone`.** The overlay form covers a corner of whatever
  it hangs on. That is free on an avatar and destructive on an icon that is
  itself information — a status glyph, a type indicator — where the caller
  needs the mark beside the thing rather than over it. Previously the only
  route was to abandon `CommonBadge` and use Material's `Badge` directly,
  losing everything above.

  ⚠️ **`child` is now `Widget?`, so the default constructor's `required
  child:` accepts null too.** `.standalone` is the readable spelling for the
  common case, not a wall around the other one — and the childless *default*
  constructor is in fact the only way to get a standalone **dot**, since
  `.standalone` fixes `type` to `normal` and therefore always carries a label
  or the `!` fallback. Adopters subclassing `CommonBadge` or reading `.child`
  off an instance would see the widened type; nothing in this repo does.

- **`CommonNavTile.iconBadgeLabel`.** The tile accepted an `iconBadgeType` but
  never forwarded a label to the `CommonBadge` it built, so `normal` could
  only ever render the fallback `Text('!')`. A caller wanting a count or its
  own glyph had to abandon `iconBadgeType` and wrap `leading` by hand — which
  is what the first caller that hit this did, before noticing why.

## 3.0.1

`src/form_components/datetime_picker_field.dart` split into three files, none
of which matched the class it was originally named after:

- `date_time_picker_controller.dart` — `DateTimePickerController`, on its own
  since it shares no supertype with the widgets that were filed alongside it.
- `date_time_picker_field_template.dart` — `DateTimePickerFieldTemplate` plus
  its two concrete subtypes, `DateTimePickerField` and `DatePickerField`. The
  file is named after the template, not either concrete widget, precisely
  because both are its subtypes and neither is the other's.

Not a breaking change — all four names still reach consumers through the
`package:ui_kit/ui_kit.dart` barrel, which now exports the two new files
instead of the one they replace.

## 3.0.0
- **BREAKING** — `CommonStepIndicator` drops the `label` parameter and the
  `Text` it rendered above the segments. The widget is the segments now,
  nothing else.

  2.2.0 shipped label-above-segments as one fixed composition on the
  reasoning that the two always travel together. The first real caller
  proved that wrong within the same week: CherishCRM's onboarding app bar
  wanted the label in the toolbar's own `title` (centred against the whole
  bar width) and the segments on their own in `bottom` below it — a layout
  the bundled widget could not produce without CherishCRM either
  duplicating the label outside it or living with the wrong composition.
  Nothing about that split is unusual enough to treat as a special case
  the widget should carry a flag for; a caller that wants a label composes
  one line of `Text` next to this, wherever its own layout puts it.

  **Adopters:** replace `CommonStepIndicator(label: ..., current: ...,
  total: ...)` with `CommonStepIndicator(current: ..., total: ...)` plus
  your own `Text(label)` positioned where the old rendering put it (directly
  above the segments, with an 8px gap, is what 2.2.0 did internally).

## 2.2.0
- New `CommonStepIndicator`: a text label above N short pills, filled solid
  through the current step and faint after it — a step counter for a wizard
  whose length is fixed and known ahead of time (an onboarding guide, a short
  setup flow), as distinct from `CommonLoadingWidget`'s determinate mode,
  which reads as progress toward an unstated number and belongs to an
  operation with a fraction rather than a step index.

  Extracted from CherishCRM's onboarding guide, where it started as a
  full-width continuous bar and changed shape twice before landing here: once
  to move it out of the app bar into the centred page content (a bold bar
  pinned to the top and a centred block below it read as two things
  competing for attention across empty space), and once back into the app
  bar after the bar itself became short segments — quiet enough that the
  competition the first move was solving no longer existed. Both app bar and
  in-page placement work: the widget sizes itself to its own compact width
  rather than stretching, so a caller centres it however its own layout
  already centres things.

  Takes `label` as a required `String`, like every other widget here that
  always shows text — see the README's Text ownership section.

## 2.1.0
- `CommonInfoWidget` caps its content column at a new optional
  `maxContentWidth` (default `CommonInfoWidget.defaultMaxContentWidth`, 480).
  Neither the title nor the caption was bounded before, so a caption on a
  1024px tablet spanned the whole window. The cap covers the icon, title,
  caption and the actions `Wrap` together, and `CommonErrorWidget` /
  `CommonErrorSliverWidget` inherit it through composition.

  Pass an explicit value where the surrounding page caps its own content
  differently — a placeholder that *replaces* that content should not render
  narrower than what it replaced.

- `CommonInfoWidget`'s **dense** variant gains 16px horizontal padding. It
  previously had none at all, so its text could sit flush against the host's
  edge.

  This does **not** make dense narrower than the default variant, and cannot:
  at a container width `W` the dense content is `min(cap, W - 32)` against the
  default's `min(cap, W - 48)`, so below `cap + 32` dense stays the wider of
  the two. The two variants never share a container in practice — the default
  is full-screen, dense sits inside a section that already carries its own
  inset — so the comparison is not the thing being fixed. Being flush is.

  **Adopters:** a dense call site that already compensated with its own
  horizontal inset now gets both. Check inline cards and dialogs with a tight
  measure; the padding is deliberately not a parameter, so compensate at the
  call site or give the host more room.

- ui_kit gains a `test/` directory and a `flutter_test` dev-dependency; CI runs
  `flutter test` for it. It was the only package in this workspace with no
  tests. (`flutter_test` cannot be added on any 1.x branch — `hlc_sync` pinned
  `test: ^1.31.2` there, which makes the whole workspace unresolvable once a
  Flutter package with tests joins it. That floor was widened on `main` only.)

## 2.0.0
- **BREAKING** — `CommonDeleteDialog` (and its `.show` helper) drops
  `errorMessageBuilder` and `onError`. A failure in `onDelete` now propagates to
  the caller instead of being caught and rendered inside the dialog.

  The dialog knows nothing about an arbitrary callback's exception types, so the
  only report it could produce was `toString()` in a text field — away from the
  handler that knows what failed. It still clears its loading state on failure,
  so the buttons come back live; what the user sees is the caller's decision.

  **Handle the failure INSIDE `onDelete`.** A `try` around `show` compiles,
  raises no lint, and catches nothing: the delete button invokes `onDelete`
  fire-and-forget, and `show` returns the dialog route's future, not the
  callback's. An unhandled exception reaches the zone handler instead — logged,
  with the user told nothing.

  Migration is not a one-line move. A caller that passed these may have no
  failure path of its own at all — the dialog *was* its error UI — so removing
  them leaves a delete that fails silently. Add the handling before bumping, and
  cover it with a test: telling a user a delete succeeded when it did not is the
  failure this shape invites.

## 1.2.0
- `CommonNavTile` (all three named constructors) gains an optional `subtitle`
  param, rendered as the tile's `ListTile.subtitle`.
- `CommonDeleteDialog` (and its `.show` helper) gains optional `confirmPhrase`
  + `confirmFieldHint` params — when set, the delete button stays disabled
  behind a text field that must match `confirmPhrase` exactly, for actions
  that need more friction than a second tap. `confirmFieldHint` is required
  whenever `confirmPhrase` is set (same text-ownership rule as everywhere
  else in this package).

## 1.1.0
- Added `CommonBadge`, `CommonNavTile` (`.none`/`.internal`/`.external`),
  `CommonInfoWidget`/`CommonErrorWidget`(+Sliver+Dialog)/`CommonLoadingWidget`
  (+Sliver+Dialog)/`CommonSuccessDialog`/`CommonProgressDialog`, and
  `CommonDeleteDialog` — merged from equivalent widgets independently built
  in CherishCRM-Flutter and NovelGlide-Flutter (see each class's doc comment
  for which app's shape won and why). New dependency:
  `loading_animation_widget`. No widget in this package ships built-in copy —
  see README §Text ownership.

## 1.0.6
- Moved into `dart-packages` as a workspace member. No longer published to
  pub.dev — consumed as a git dependency. No functional change.

## 1.0.5
- Fix that DateTimePickerField didn't update controller value after clearing the value.

## 1.0.4
- Fix that DateTimePickerField didn't get correct value in onSave if initial value was provided by controller in initState.

## 1.0.3
- Fix that DateTimePickerField didn't fill in if initial value was provided in initState.

## 1.0.2
- Fix missing components export.

## 1.0.1
- Added DateTimePickerField and DatePickerField.

## 1.0.0

- Initial version.
