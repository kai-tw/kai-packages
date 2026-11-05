import 'dart:io';

import 'package:path/path.dart' as p;

import '../generated_file_filter.dart';
import '../runner/worker_sandbox.dart';

/// Why [DiffScope.of] could not say what a change touched.
class DiffScopeException implements Exception {
  const DiffScopeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The Dart files a change touched, and the lines it added or changed in
/// each — what review mode mutates.
///
/// The change is everything since the merge base of a ref and `HEAD`, up to
/// the working tree: commits on the branch and uncommitted edits to tracked
/// files alike. A file whose change only deleted lines has nothing new to
/// ask about, so it is left out.
class DiffScope {
  const DiffScope(this.base, this.lines);

  /// The merge base the change is measured from.
  final String base;

  /// Each touched file, absolute, with its added or changed lines.
  final Map<String, Set<int>> lines;

  List<String> get files => lines.keys.toList();

  /// The scope of the change since [ref] in the git repository holding
  /// [packageRoot]. With [files], those files are the scope and [ref] only
  /// sets their lines; without, every Dart file under the package's `lib/`
  /// that the change touched, generated files left out.
  static Future<DiffScope> of(
    String ref, {
    required String packageRoot,
    List<String>? files,
  }) async {
    final String root = realPath(packageRoot);
    final String repo = (await _git(root, <String>[
      'rev-parse',
      '--show-toplevel',
    ], 'the package is not in a git repository')).trim();
    await _git(root, <String>[
      'rev-parse',
      '--verify',
      '--quiet',
      '$ref^{commit}',
    ], '--diff $ref does not resolve to a commit');
    final String base = (await _git(root, <String>[
      'merge-base',
      ref,
      'HEAD',
    ], 'no merge base between $ref and HEAD')).trim();
    final List<String> candidates =
        files?.map((String f) => realPath(f)).toList() ??
        await _touched(repo, root, base);
    final Map<String, Set<int>> lines = <String, Set<int>>{};
    for (final String file in candidates) {
      final Set<int> changed = parseAddedLines(
        await _git(repo, <String>[
          'diff',
          '-U0',
          '--no-color',
          '--no-ext-diff',
          base,
          '--',
          file,
        ], 'git diff failed for $file'),
      );
      if (changed.isNotEmpty) {
        lines[file] = changed;
      }
    }
    return DiffScope(base, lines);
  }

  /// Every Dart file under [root]'s `lib/` that changed since [base].
  static Future<List<String>> _touched(
    String repo,
    String root,
    String base,
  ) async {
    final String names = await _git(repo, <String>[
      'diff',
      '--name-only',
      '--no-renames',
      base,
    ], 'git diff failed');
    final String lib = p.join(root, 'lib');
    return <String>[
      for (final String name in names.split('\n'))
        if (name.trim().isNotEmpty)
          if (p.join(realPath(repo), name.trim()) case final String file
              when file.endsWith('.dart') &&
                  p.isWithin(lib, file) &&
                  !isGeneratedFile(file) &&
                  File(file).existsSync())
            file,
    ]..sort();
  }

  static Future<String> _git(
    String dir,
    List<String> arguments,
    String failure,
  ) async {
    final ProcessResult result = await Process.run(
      'git',
      arguments,
      workingDirectory: dir,
    );
    if (result.exitCode != 0) {
      throw DiffScopeException(failure);
    }
    return result.stdout as String;
  }
}

/// The new-side lines of every hunk in [diff], a `git diff -U0`: the lines
/// it added or changed. A hunk that only deletes adds none.
Set<int> parseAddedLines(String diff) {
  final RegExp hunk = RegExp(
    r'^@@ -[0-9,]+ \+(\d+)(?:,(\d+))? @@',
    multiLine: true,
  );
  return <int>{
    for (final RegExpMatch m in hunk.allMatches(diff))
      for (
        int line = int.parse(m[1]!);
        line < int.parse(m[1]!) + int.parse(m[2] ?? '1');
        line++
      )
        line,
  };
}
