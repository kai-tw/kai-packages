import 'dart:io';

import 'package:path/path.dart' as p;

/// This package's directory in the user's cache: `$XDG_CACHE_HOME`, or
/// `~/.cache` without it, then `dart_mutants`.
String cacheDirectory() {
  final Map<String, String> env = Platform.environment;
  final String base =
      env['XDG_CACHE_HOME'] ?? p.join(env['HOME'] ?? '.', '.cache');
  return p.join(base, 'dart_mutants');
}
