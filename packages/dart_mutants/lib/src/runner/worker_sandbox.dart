import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_command.dart';
import 'temp_space.dart';

/// A package directory for one parallel worker, made almost entirely of
/// symbolic links back to the real one, so several workers can each have a
/// mutated file on disk at once without copying the package.
///
/// Only what has to differ is real:
///
/// - each target file, a copy the worker writes its mutants into;
/// - the directories on the way to them, and every directory under `lib/`
///   and `test/`, so that a target can be a file rather than a link — their
///   files are links;
/// - the top-level files (a `pubspec.yaml`, `analysis_options.yaml`, …),
///   copies, because tools rewrite some of them in place, and a rewrite
///   through a link would land in the real package;
/// - `.dart_tool/`, with a `package_config.json` that resolves this package
///   to the worker instead of the original.
///
/// Every other top-level directory is one link. `build/` and `.git/` are
/// left out, and so are a Flutter package's platform directories, which a
/// test on the VM does not read and Flutter's tooling may write to.
///
/// Measured on a small Flutter package: the worker's own files came to a few
/// kilobytes, and `flutter test` then wrote 46MB of its own `build/` into
/// it. A `dart test` worker's `.dart_tool/` grows by the compiled test
/// runner, about 30MB on a small package, and by the kernel cache that is
/// cleared before every mutant anyway.
///
/// Nothing is ever written through a link: [write] refuses one.
class WorkerSandbox {
  WorkerSandbox._(this.id, this.root, this.directory);

  /// Creates worker [id] for the package at [root], with a real copy of each
  /// of [targets] (paths under [root]), in a directory from [temps].
  ///
  /// [flutter] leaves out the platform directories.
  static WorkerSandbox create({
    required int id,
    required String root,
    required List<String> targets,
    required TempSpace temps,
    required bool flutter,
  }) {
    final String source = p.normalize(p.absolute(root));
    // Resolved: `pub` compares the package config's root with the working
    // directory's real path, and `/var` is a link to `/private/var` on
    // macOS. Unresolved, every `dart test` in the worker exits 65.
    final WorkerSandbox sandbox = WorkerSandbox._(
      id,
      source,
      temps.create('worker$id').resolveSymbolicLinksSync(),
    );
    final Set<String> mirrored = <String>{
      'lib',
      'test',
      for (final String target in targets)
        p.split(p.relative(p.absolute(target), from: source)).first,
    };
    sandbox
      .._linkTopLevel(mirrored, skip: flutter ? _flutterSkipped : _skipped)
      .._writeDartTool();
    for (final String target in targets) {
      final String copy = sandbox.pathFor(target);
      // A top-level target is already a copy; one in a directory is a link.
      if (FileSystemEntity.isLinkSync(copy)) {
        Link(copy).deleteSync();
      }
      File(p.absolute(target)).copySync(copy);
    }
    return sandbox;
  }

  static const Set<String> _skipped = <String>{'.dart_tool', 'build', '.git'};

  static const Set<String> _flutterSkipped = <String>{
    ..._skipped,
    'android',
    'ios',
    'linux',
    'macos',
    'web',
    'windows',
  };

  /// Numbers the workers of a run from 0, for statistics.
  final int id;

  /// The real package's directory.
  final String root;

  /// This worker's copy of it.
  final String directory;

  /// Where [path], a file of the real package, is in this worker.
  String pathFor(String path) =>
      p.join(directory, p.relative(p.absolute(path), from: root));

  /// [command] run in this worker instead of the real package: the working
  /// directory moved, any argument naming a path inside the package moved
  /// with it, and — under `flutter test` — `--no-pub`, since the copied
  /// `pubspec.yaml` would otherwise look newer than the package config and
  /// send Flutter to `pub get` in the middle of the run.
  ProcessCommand commandFor(ProcessCommand command, {required bool flutter}) =>
      ProcessCommand(
        command.executable,
        <String>[
          // Absolute paths only. A relative one already resolves against the
          // worker, and `p.isWithin` would read one against this process's
          // working directory — which, run from the package, turns the
          // `test` subcommand itself into a path.
          for (final String argument in command.arguments)
            p.isAbsolute(argument) && p.isWithin(root, argument)
                ? pathFor(argument)
                : argument,
          if (flutter && !command.arguments.contains('--no-pub')) '--no-pub',
        ],
        workingDirectory: directory,
      );

  /// Writes [content] to [path], a file in this worker. Refuses a link:
  /// writing through one would change the real package.
  void write(String path, String content) {
    if (FileSystemEntity.isLinkSync(path)) {
      throw StateError('refusing to write through the link at $path');
    }
    File(path).writeAsStringSync(content);
  }

  /// Bytes this worker holds of its own, links not followed — what it costs
  /// in disk space right now.
  int diskBytes() {
    int total = 0;
    for (final FileSystemEntity entity in Directory(
      directory,
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += entity.lengthSync();
      }
    }
    return total;
  }

  void _linkTopLevel(Set<String> mirrored, {required Set<String> skip}) {
    for (final FileSystemEntity entity in Directory(
      root,
    ).listSync(followLinks: false)) {
      final String name = p.basename(entity.path);
      final String destination = p.join(directory, name);
      if (skip.contains(name)) {
        continue;
      }
      if (entity is Directory && mirrored.contains(name)) {
        _mirror(entity, destination);
      } else if (entity is File) {
        entity.copySync(destination);
      } else {
        Link(destination).createSync(entity.path);
      }
    }
  }

  /// [source] as real directories holding links to its files.
  static void _mirror(Directory source, String destination) {
    Directory(destination).createSync();
    for (final FileSystemEntity entity in source.listSync(followLinks: false)) {
      final String target = p.join(destination, p.basename(entity.path));
      if (entity is Directory) {
        _mirror(entity, target);
      } else {
        Link(target).createSync(entity.path);
      }
    }
  }

  /// The package config, with this package moved here, and the two small
  /// files `pub` checks it against. The rest of `.dart_tool/` is build
  /// output the tools recreate.
  void _writeDartTool() {
    final Directory tool = Directory(p.join(directory, '.dart_tool'))
      ..createSync();
    final File? config = _packageConfigOf(root);
    if (config == null) {
      return;
    }
    final String configPath = config.path;
    _anchorPathDependencies();
    final String configRoot = p.dirname(p.dirname(configPath));
    if (!p.equals(configRoot, root)) {
      _standAlone(configRoot);
    }
    final Map<String, Object?> json =
        jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
    final Uri base = Uri.directory(p.dirname(configPath));
    final String self = p.normalize(root);
    for (final Object? entry in json['packages']! as List<Object?>) {
      final Map<String, Object?> package = entry! as Map<String, Object?>;
      final Uri resolved = base.resolve(package['rootUri']! as String);
      final Uri moved = p.normalize(p.fromUri(resolved)) == self
          ? Uri.directory(directory)
          : resolved;
      package['rootUri'] = moved.toString();
    }
    File(
      p.join(tool.path, 'package_config.json'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    for (final String name in <String>['package_graph.json', 'version']) {
      final File file = File(p.join(p.dirname(configPath), name));
      if (file.existsSync()) {
        file.copySync(p.join(tool.path, name));
      }
    }
  }

  /// Rewrites each relative `path:` in the worker's `pubspec.yaml` that names
  /// a directory next to the package, to that directory's absolute path. The
  /// worker sits elsewhere, where `../sibling` names nothing, and `pub`
  /// checks path dependencies before every `dart test`.
  void _anchorPathDependencies() {
    final File pubspec = File(p.join(directory, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      return;
    }
    pubspec.writeAsStringSync(
      pubspec.readAsStringSync().replaceAllMapped(
        RegExp(r'''^(\s*path:\s*)(['"]?)([^'"\s#]+)\2''', multiLine: true),
        (Match m) {
          final String value = m[3]!;
          final String target = p.normalize(p.join(root, value));
          return p.isRelative(value) && Directory(target).existsSync()
              ? '${m[1]}${m[2]}$target${m[2]}'
              : m[0]!;
        },
      ),
    );
  }

  /// Turns the copy of a workspace member into a package of its own: `pub`
  /// refuses `resolution: workspace` with no workspace above it, and a
  /// package of its own needs a lock file, which is the workspace's. Both
  /// are written before the package config, which must be the newest of the
  /// three for `pub` to consider it up to date.
  void _standAlone(String workspaceRoot) {
    final File pubspec = File(p.join(directory, 'pubspec.yaml'));
    if (pubspec.existsSync()) {
      pubspec.writeAsStringSync(
        pubspec.readAsStringSync().replaceAll(
          RegExp(r'^resolution:\s*workspace\s*$', multiLine: true),
          '',
        ),
      );
    }
    final File lock = File(p.join(workspaceRoot, 'pubspec.lock'));
    if (lock.existsSync()) {
      lock.copySync(p.join(directory, 'pubspec.lock'));
    }
  }

  /// The package config the tools use for the package at [root]: its own,
  /// or — for a member of a pub workspace, whose `.dart_tool/` holds only a
  /// pointer — the workspace's. The worker gets a copy of its own either
  /// way, since the workspace root is not above the worker.
  static File? _packageConfigOf(String root) {
    final File own = File(p.join(root, '.dart_tool', 'package_config.json'));
    if (own.existsSync()) {
      return own;
    }
    final File pointer = File(
      p.join(root, '.dart_tool', 'pub', 'workspace_ref.json'),
    );
    if (!pointer.existsSync()) {
      return null;
    }
    final Object? workspaceRoot =
        (jsonDecode(pointer.readAsStringSync())
            as Map<String, Object?>)['workspaceRoot'];
    if (workspaceRoot is! String) {
      return null;
    }
    final File shared = File(
      p.join(
        p.normalize(p.join(p.dirname(pointer.path), workspaceRoot)),
        '.dart_tool',
        'package_config.json',
      ),
    );
    return shared.existsSync() ? shared : null;
  }
}
