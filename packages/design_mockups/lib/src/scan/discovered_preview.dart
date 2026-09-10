/// One `@MockupPreview`-annotated function found in the project.
class DiscoveredPreview {
  const DiscoveredPreview({
    required this.spec,
    required this.screen,
    required this.state,
    required this.sizes,
    required this.textScale,
    required this.functionName,
    required this.importUri,
    required this.takesArguments,
  });

  final String spec;
  final String screen;
  final String state;
  final List<String> sizes;
  final double textScale;
  final String functionName;

  /// The `package:` URI the generated registry imports, or an absolute path
  /// for a preview under `tool/`, which has no package URI.
  final String importUri;

  /// Whether the function takes a `BuildContext`. A zero-arg function is the
  /// common case and is adapted at generation time.
  final bool takesArguments;

  /// Sorted so the generated file is stable — a registry that reorders on
  /// every scan produces a diff that says nothing.
  static int compare(DiscoveredPreview a, DiscoveredPreview b) {
    final int bySpec = a.spec.compareTo(b.spec);
    if (bySpec != 0) {
      return bySpec;
    }
    final int byScreen = a.screen.compareTo(b.screen);
    if (byScreen != 0) {
      return byScreen;
    }
    return a.state.compareTo(b.state);
  }
}
