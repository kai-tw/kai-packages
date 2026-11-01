import 'package:flutter/material.dart';

import 'common_error_widget.dart';

/// The sliver version of [CommonErrorWidget], for use inside a
/// [CustomScrollView].
///
/// It fills the rest of the viewport, so it's always the full-screen
/// variant and takes no `dense`. For an error inside one section of a
/// scroll view, wrap a dense [CommonErrorWidget] in a `SliverToBoxAdapter`.
class CommonErrorSliverWidget extends CommonErrorWidget {
  const CommonErrorSliverWidget({
    super.key,
    super.icon,
    required super.content,
    super.caption,
    super.actions,
  });

  @override
  Widget build(BuildContext context) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: super.build(context),
    );
  }
}
