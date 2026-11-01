# ui_kit

This is a UI kit that shares Flutter components through my projects.

## Usage

Just use them like other Flutter components.

```dart
class SimpleWidget extends StatelessWidget {
  const SimpleWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return AppVersion();
  }
}
```

## Widget list

- **AppVersion**: automatically reads the app version and displays it with the
  OS icon (x.x.x).
- **DateTimePickerField** / **DatePickerField**: a form field that picks a
  date(+time) when tapped.
- **CommonBadge**: overlays a badge (hidden/minimal/normal) on a child.
- **CommonNavTile**: a clickable nav row — `.none`/`.internal`/`.external`
  named constructors pick the trailing icon (chevron / external-link / none).
- **CommonInfoWidget**: centred icon+title(+caption+actions) placeholder for
  empty/offline/neutral states, with a `dense` inline variant.
- **CommonErrorWidget** (+ `CommonErrorSliverWidget`, `CommonErrorDialog`):
  error-tinted variants of the above; `CommonErrorWidget` also takes `dense`.
- **CommonLoadingWidget** (+ `CommonLoadingSliverWidget`,
  `CommonLoadingDialog`): spinner (or determinate progress) + label.
- **CommonSuccessDialog**: a success-confirmation dialog.
- **CommonProgressDialog**: switches between the three dialogs above by
  `CommonProgressStatus` (loading/success/error).
- **CommonDeleteDialog**: confirm-then-delete dialog that manages its own
  async lifecycle around `onDelete` — spinner while it runs, stays open with
  an inline error on failure.
- **CommonStepIndicator**: N short pills for a fixed-length wizard, filled
  through the current step. Segments only — pair it with your own `Text` for
  a label, positioned wherever your layout wants it.

### Text ownership

This package ships **no built-in copy**. Every widget whose UI always shows
some text (a title, a button label) takes that text as a **required**
parameter — there is no English/Chinese/whatever default baked in, and
nothing here depends on any app's localization setup. This is a deliberate
constraint from merging widgets out of two apps with different languages and
different (or no) l10n toolchains: a shared package can't own copy without
picking one of them. Purely *behavioral* defaults (e.g. a dialog's dismiss
button defaulting to `Navigator.pop`) are unaffected — only user-visible text
is caller-supplied.

## Status

Moved here from a standalone `pub.dev` package
([`flutter_ui_kit`](https://github.com/kai-tw/flutter_ui_kit), now
discontinued). No functional change from `1.0.5` — the widgets are
byte-for-byte what shipped there. Consumed as a git dependency, not published.
