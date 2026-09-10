# design_mockups_annotations

The annotation half of [`design_mockups`](../design_mockups): `@MockupPreview`,
and nothing else.

It is a separate package because of the dependency direction. The harness
depends on `flutter_test`, so an app takes it as a **dev** dependency — and a
`lib/` file importing a dev dependency compiles locally, then fails for anyone
consuming that app as a package. Most projects lint against it outright.

This package has no dependencies at all and consists of `const` annotation
classes, which are unreferenced in a release build and shake out of it. So a
widget can declare where it appears in a design render without the render
harness ever entering its compilation root.

```dart
import 'package:design_mockups_annotations/design_mockups_annotations.dart';

@MockupPreview(spec: 'account', screen: 'account_card', state: 'ready')
Widget accountCardReady() => const AccountCard(state: AccountReady(plan: 'Pro'));
```

See `design_mockups` for what happens to it.
