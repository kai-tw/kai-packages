/// Collects every `@MockupPreview` in the project into a generated registry.
///
/// Run before `flutter test tool/design_mockups/` — the `render-mockups`
/// script does this for you when the project depends on `design_mockups`.
///
///     dart run design_mockups:scan
///     dart run design_mockups:scan --root=lib --root=tool/design_mockups \
///       --out=tool/design_mockups/preview_registry.g.dart
///
/// The output is generated on every render and belongs in `.gitignore`:
/// committing it invites someone to edit it, and a hand-edited registry is
/// exactly the file this tool exists to delete.
library;

import 'dart:io';

import 'package:design_mockups/src/scan/discovered_preview.dart';
import 'package:design_mockups/src/scan/preview_scanner.dart';
import 'package:design_mockups/src/scan/registry_emitter.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln(
      'Usage: dart run design_mockups:scan [--root=<dir>]... [--out=<file>]\n'
      '\n'
      '  --root  A directory to scan. Repeatable. Defaults to lib and\n'
      '          tool/design_mockups.\n'
      '  --out   Where to write the registry. Defaults to\n'
      '          tool/design_mockups/preview_registry.g.dart.',
    );
    return;
  }

  final List<String> roots = <String>[
    for (final String arg in args)
      if (arg.startsWith('--root=')) arg.substring('--root='.length),
  ];
  final String out = args
      .firstWhere(
        (String a) => a.startsWith('--out='),
        orElse: () => '--out=tool/design_mockups/preview_registry.g.dart',
      )
      .substring('--out='.length);

  final String projectRoot = Directory.current.path;
  final String packageName = _packageName(projectRoot);

  int refused = 0;
  final List<DiscoveredPreview> previews = await scanPreviews(
    roots: roots.isEmpty ? const <String>['lib', 'tool/design_mockups'] : roots,
    packageName: packageName,
    projectRoot: projectRoot,
    onDiagnostic: (String message) {
      refused++;
      stderr.writeln(message);
    },
  );

  final File file = File(p.join(projectRoot, out))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      emitRegistry(previews, outDir: p.dirname(p.join(projectRoot, out))),
    );

  // Say what was found even when it is nothing: an empty registry and a scan
  // that never ran produce the same file, and only this line tells them apart.
  stdout.writeln(
    'design_mockups: ${previews.length} preview(s) in '
    '${previews.map((DiscoveredPreview e) => e.spec).toSet().length} spec(s) '
    '-> ${p.relative(file.path, from: projectRoot)}',
  );

  // A refused preview is a render the author asked for and will not get, so
  // this exits non-zero and the render script stops. The alternative — a
  // warning on stderr and a green run — buries it under the test output, and
  // the missing screen is noticed only by whoever remembers expecting it.
  // The registry is still written, so fixing the annotation and re-running is
  // the whole recovery.
  if (refused > 0) {
    stderr.writeln(
      'design_mockups: $refused preview(s) were skipped (above). Fix or remove '
      'the annotations and re-run.',
    );
    exitCode = 1;
  }
}

/// The consuming project's package name, so previews under `lib/` are imported
/// by `package:` URI rather than by a path that only resolves from one
/// directory.
String _packageName(String projectRoot) {
  final File pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    throw StateError(
      'design_mockups: no pubspec.yaml in $projectRoot. Run this from the '
      'project root.',
    );
  }
  final YamlMap doc = loadYaml(pubspec.readAsStringSync()) as YamlMap;
  return doc['name'] as String;
}
