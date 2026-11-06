import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

import 'worker_sandbox.dart';

/// For each of [targets], the test files among [testFiles] that can load it:
/// those whose imports, exports and parts lead to it, through any package.
/// `null` when this cannot tell, and every test file has to be taken.
///
/// A test runs only code compiled into it, and a test file is compiled with
/// what its directives lead to and nothing else. So a test file left out
/// here cannot execute the target, and its coverage would only say so. The
/// one way around the directives is `Isolate.spawnUri`, which loads a file
/// by its path at run time: a test file that leads to a call of it is kept
/// for every target, whatever it imports.
///
/// [testFiles] are as `TestInvocation.testFiles` gives them, relative to
/// [root]; [targets] are relative to the current directory or absolute, and
/// key the answer as given. Each list keeps [testFiles]' own strings and
/// order.
Map<String, List<String>>? testFilesLoading({
  required String root,
  required List<String> testFiles,
  required Iterable<String> targets,
}) {
  final _Packages? packages = _Packages.of(root);
  if (packages == null) {
    return null;
  }
  final _Graph graph = _Graph(packages);
  final Map<String, String> byPath = <String, String>{
    for (final String file in testFiles) realPath(p.join(root, file)): file,
  };
  graph.walkFrom(byPath.keys);
  return <String, List<String>>{
    for (final String target in targets)
      target: _among(byPath, graph.reaching(realPath(target))),
  };
}

/// The test files of [byPath] (real path -> as given) in [reaching].
List<String> _among(Map<String, String> byPath, Set<String> reaching) =>
    <String>[
      for (final MapEntry<String, String> test in byPath.entries)
        if (reaching.contains(test.key)) test.value,
    ];

/// Every Dart file reachable from the test files, and what leads to what.
class _Graph {
  _Graph(this._packages);

  final _Packages _packages;

  /// Each file read, with the files its directives lead to.
  final Map<String, List<String>> _edges = <String, List<String>>{};

  /// The files that call `Isolate.spawnUri`.
  final Set<String> _spawning = <String>{};

  void walkFrom(Iterable<String> starts) {
    final List<String> pending = <String>[...starts];
    while (pending.isNotEmpty) {
      final String file = pending.removeLast();
      if (_edges.containsKey(file)) {
        continue;
      }
      final List<String> next = _read(file);
      _edges[file] = next;
      pending.addAll(next);
    }
  }

  /// What leads into each file — [_edges] turned around, built once.
  late final Map<String, List<String>> _into = () {
    final Map<String, List<String>> into = <String, List<String>>{};
    for (final MapEntry<String, List<String>> edge in _edges.entries) {
      for (final String to in edge.value) {
        into.putIfAbsent(to, () => <String>[]).add(edge.key);
      }
    }
    return into;
  }();

  /// Every file read that leads to [target], or to a call of
  /// `Isolate.spawnUri`, [target] itself included.
  Set<String> reaching(String target) {
    final Set<String> seen = <String>{};
    final List<String> pending = <String>[target, ..._spawning];
    while (pending.isNotEmpty) {
      final String file = pending.removeLast();
      if (seen.add(file)) {
        pending.addAll(_into[file] ?? const <String>[]);
      }
    }
    return seen;
  }

  /// The files [file]'s directives lead to: every branch of a conditional
  /// import counts, since which one compiles depends on the platform. A
  /// file that cannot be read leads nowhere — it does not compile, so it
  /// runs nothing either.
  List<String> _read(String file) {
    final String source;
    try {
      source = File(file).readAsStringSync();
    } on FileSystemException {
      return const <String>[];
    }
    if (source.contains('spawnUri')) {
      _spawning.add(file);
    }
    final CompilationUnit unit = parseString(
      content: source,
      path: file,
      throwIfDiagnostics: false,
    ).unit;
    final Uri base = p.toUri(file);
    return <String>[
      for (final String uri in unit.directives.expand(_urisOf))
        if (_packages.resolve(base, uri) case final String path) path,
    ];
  }

  /// The URIs [directive] names: none for a directive that names no file,
  /// and every branch of a conditional import.
  static Iterable<String> _urisOf(Directive directive) => <String?>[
    if (directive is UriBasedDirective) directive.uri.stringValue,
    if (directive is NamespaceDirective)
      for (final Configuration c in directive.configurations) c.uri.stringValue,
  ].nonNulls;
}

/// Where each `package:` URI points, read from the package config.
class _Packages {
  _Packages(this._lib);

  /// Each package's `lib/` directory (its `packageUri`), by name.
  final Map<String, String> _lib;

  static _Packages? of(String root) {
    final File? config = WorkerSandbox.packageConfigOf(root);
    if (config == null) {
      return null;
    }
    final Uri base = p.toUri(p.absolute(config.path));
    final Object? json;
    try {
      json = jsonDecode(config.readAsStringSync());
    } on FormatException {
      return null;
    }
    // A config in a shape this does not know says nothing, rather than
    // leave a test file out on a misreading.
    if (json case <String, Object?>{'packages': final List<Object?> list}) {
      final Map<String, String> lib = <String, String>{};
      for (final Object? entry in list) {
        if (entry case <String, Object?>{
          'name': final String name,
          'rootUri': final String rootUri,
        }) {
          final String packageUri = switch (entry['packageUri']) {
            final String uri => uri,
            _ => 'lib/',
          };
          final Uri packageLib = base
              .resolve(_asDirectory(rootUri))
              .resolve(_asDirectory(packageUri));
          lib[name] = realPath(p.fromUri(packageLib));
        } else {
          return null;
        }
      }
      return _Packages(lib);
    }
    return null;
  }

  static String _asDirectory(String uri) => uri.endsWith('/') ? uri : '$uri/';

  /// The file [uri] names, written in the file at [base]; `null` for a
  /// `dart:` library, an unknown package, or a URI that does not parse.
  String? resolve(Uri base, String uri) {
    final Uri? parsed = Uri.tryParse(uri);
    if (parsed == null) {
      return null;
    }
    if (parsed.scheme == 'package') {
      final List<String> segments = parsed.pathSegments;
      if (segments.length < 2) {
        return null;
      }
      final String? lib = _lib[segments.first];
      return lib == null ? null : p.joinAll(<String>[lib, ...segments.skip(1)]);
    }
    if (parsed.hasScheme && parsed.scheme != 'file') {
      return null;
    }
    return p.normalize(p.fromUri(base.resolveUri(parsed)));
  }
}
