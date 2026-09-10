import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import 'discovered_preview.dart';

/// Reports a preview that was found but could not be used.
typedef ScanDiagnostic = void Function(String message);

/// Walks [roots] and returns every `@MockupPreview`-annotated top-level
/// function, resolved.
///
/// Resolved rather than parsed-only, because the annotation's arguments may be
/// constants declared elsewhere (`MockupSizes.compact` is one), and a parse
/// tree only knows their source text. That is also why this is a separate CLI
/// step rather than something the harness does at run time: Dart has no
/// reflection to find these with, so somebody has to read the source, and it
/// has to happen before the test is compiled.
Future<List<DiscoveredPreview>> scanPreviews({
  required List<String> roots,
  required String packageName,
  required String projectRoot,
  ScanDiagnostic? onDiagnostic,
}) async {
  final List<String> existing = <String>[
    for (final String root in roots)
      if (Directory(p.normalize(p.absolute(root))).existsSync())
        p.normalize(p.absolute(root)),
  ];
  if (existing.isEmpty) {
    return const <DiscoveredPreview>[];
  }

  final AnalysisContextCollection collection = AnalysisContextCollection(
    includedPaths: existing,
  );
  final List<DiscoveredPreview> found = <DiscoveredPreview>[];
  for (final AnalysisContext context in collection.contexts) {
    for (final String path in context.contextRoot.analyzedFiles()) {
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) {
        continue;
      }
      found.addAll(
        await _previewsIn(
          context: context,
          path: path,
          packageName: packageName,
          projectRoot: projectRoot,
          onDiagnostic: onDiagnostic,
        ),
      );
    }
  }

  found.sort(DiscoveredPreview.compare);
  return found;
}

/// Every preview declared by the library whose defining unit is [path].
Future<List<DiscoveredPreview>> _previewsIn({
  required AnalysisContext context,
  required String path,
  required String packageName,
  required String projectRoot,
  required ScanDiagnostic? onDiagnostic,
}) async {
  final SomeResolvedLibraryResult result = await context.currentSession
      .getResolvedLibrary(path);
  if (result is! ResolvedLibraryResult) {
    return const <DiscoveredPreview>[];
  }
  final LibraryElement library = result.element;
  // A part is reached through its own library, so a non-defining unit would
  // yield the same functions a second time.
  if (library.firstFragment.source.fullName != path) {
    return const <DiscoveredPreview>[];
  }

  final String importUri = _importUri(
    path: path,
    packageName: packageName,
    projectRoot: projectRoot,
  );
  return <DiscoveredPreview>[
    for (final TopLevelFunctionElement function in library.topLevelFunctions)
      ?_readAnnotation(
        function: function,
        importUri: importUri,
        onDiagnostic: onDiagnostic,
      ),
  ];
}

/// The `@MockupPreview` on [function], or null when it carries none — or
/// carries one this scanner cannot use, in which case [onDiagnostic] says why.
DiscoveredPreview? _readAnnotation({
  required TopLevelFunctionElement function,
  required String importUri,
  required ScanDiagnostic? onDiagnostic,
}) {
  final DartObject? value = _mockupPreviewOn(function);
  if (value == null) {
    return null;
  }

  final DiscoveredPreview preview = _toPreview(
    value: value,
    function: function,
    importUri: importUri,
  );
  final String? refusal = _refusalFor(function: function, preview: preview);
  if (refusal != null) {
    onDiagnostic?.call(refusal);
    return null;
  }
  return preview;
}

/// The annotation's remaining fields, each with the default the annotation
/// itself declares — read here rather than inline above so that the reading is
/// one list and the refusing is another.
DiscoveredPreview _toPreview({
  required DartObject value,
  required TopLevelFunctionElement function,
  required String importUri,
}) {
  return DiscoveredPreview(
    // Empty, not null, for a non-constant expression: `_refusalFor` turns that
    // into the diagnostic, so there is one place that decides what is usable.
    spec: _text(value, 'spec', ''),
    screen: _text(value, 'screen', ''),
    state: _text(value, 'state', 'default'),
    sizes: _sizes(value),
    textScale: _number(value, 'textScale', 1.0),
    functionName: function.name ?? '',
    importUri: importUri,
    takesArguments: function.formalParameters.isNotEmpty,
  );
}

/// A constant string field, or [fallback] when it is absent or not constant.
String _text(DartObject value, String field, String fallback) =>
    value.getField(field)?.toStringValue() ?? fallback;

/// A constant double field, or [fallback] when it is absent or not constant.
double _number(DartObject value, String field, double fallback) =>
    value.getField(field)?.toDoubleValue() ?? fallback;

/// Why this preview cannot be used, or null when it can.
///
/// Separate from the reading so that "what the scanner refuses, and what it
/// says about it" is one list a reader can check against the annotation's own
/// doc comment, rather than two guards interleaved with field extraction.
String? _refusalFor({
  required TopLevelFunctionElement function,
  required DiscoveredPreview preview,
}) {
  if (preview.spec.isEmpty || preview.screen.isEmpty) {
    return 'design_mockups: @MockupPreview on ${function.name} has an empty or '
        'non-constant spec or screen and was skipped. Both must be non-empty '
        'literal strings — the scanner reads them without running your code.';
  }
  if (function.formalParameters.length > 1) {
    return 'design_mockups: @MockupPreview function ${function.name} takes '
        '${function.formalParameters.length} parameters; it must take none, '
        'or a single BuildContext. The variant is reached with '
        'MockupVariant.of(context).';
  }
  if (function.isPrivate) {
    return 'design_mockups: @MockupPreview function ${function.name} is '
        'private. The generated registry imports its library with a prefix and '
        'cannot name a private declaration — drop the leading underscore. It '
        'is unreferenced in a release build either way, so it does not widen '
        'the app.';
  }
  // A list rather than a map: `sizes` contributes several entries under one
  // label, and a map literal would keep only the last of them.
  return _unquotableField(<MapEntry<String, String>>[
    MapEntry<String, String>('spec', preview.spec),
    MapEntry<String, String>('screen', preview.screen),
    MapEntry<String, String>('state', preview.state),
    // Also a filename component and a generated string literal; a band id
    // reaches the emitter unchecked otherwise.
    for (final String size in preview.sizes)
      MapEntry<String, String>('size', size),
  ]);
}

/// The characters that cannot survive being written into a single-quoted Dart
/// string literal in the generated registry.
///
/// `$` is the one that actually happens: it makes the emitted literal an
/// interpolation of a name that does not exist, and the error surfaces inside
/// a generated, gitignored file at a line nobody wrote. Refusing here means
/// the complaint names the annotation instead.
final RegExp _unquotable = RegExp(r"[$'\\\n\r]");

String? _unquotableField(List<MapEntry<String, String>> fields) {
  for (final MapEntry<String, String> field in fields) {
    if (_unquotable.hasMatch(field.value)) {
      return 'design_mockups: @MockupPreview ${field.key} "${field.value}" '
          r'contains one of $ \ newline or a quote. These become part of a '
          'generated Dart source file and a filename, so the name has to be '
          'plain: letters, digits, underscores and dashes.';
    }
  }
  return null;
}

/// The evaluated `@MockupPreview` annotation on [function], if any.
DartObject? _mockupPreviewOn(TopLevelFunctionElement function) {
  for (final ElementAnnotation annotation in function.metadata.annotations) {
    final DartObject? value = annotation.computeConstantValue();
    if (value != null && value.type?.element?.name == 'MockupPreview') {
      return value;
    }
  }
  return null;
}

/// The declared bands, defaulting to compact when the list is absent or empty.
List<String> _sizes(DartObject value) {
  final List<String> sizes = <String>[
    for (final DartObject? item
        in value.getField('sizes')?.toListValue() ?? const <DartObject>[])
      ?item?.toStringValue(),
  ];
  return sizes.isEmpty ? const <String>['compact'] : sizes;
}

/// `package:` for anything under `lib/`, otherwise the absolute path — `tool/`
/// is not addressable by package URI, and that is where a fixture needing the
/// harness has to live. The emitter turns the path into a relative import.
String _importUri({
  required String path,
  required String packageName,
  required String projectRoot,
}) {
  final String relative = p.relative(path, from: projectRoot);
  if (p.isWithin('lib', relative)) {
    return 'package:$packageName/${p.relative(relative, from: 'lib')}';
  }
  return path;
}
