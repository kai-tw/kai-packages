import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_command.dart';
import 'switched_file.dart';

/// The pieces of a Flutter SDK that `flutter test` runs a test file with:
/// the compiler it keeps running, and the `flutter_tester` engine.
///
/// Used directly, without `flutter test` around them, so each test file is
/// compiled once for all of a run's mutants. The flags below are the ones
/// `flutter_tools` passes for a test on the VM in debug mode; they are not a
/// public interface and can change with Flutter. Nothing relies on them
/// being right: every test file runs unmutated first and has to pass, and
/// one that does not leaves its mutants to `flutter test`.
class FlutterSdk {
  FlutterSdk._(this.root, this._host);

  /// The SDK's root directory, which holds `bin/flutter`.
  final String root;

  /// The engine's host directory name, e.g. `darwin-x64`.
  final String _host;

  String get _cache => p.join(root, 'bin', 'cache');
  String get _engine => p.join(_cache, 'artifacts', 'engine');

  String get dartAotRuntime =>
      p.join(_cache, 'dart-sdk', 'bin', 'dartaotruntime');
  String get frontendServer => p.join(
    _cache,
    'dart-sdk',
    'bin',
    'snapshots',
    'frontend_server_aot.dart.snapshot',
  );
  String get patchedSdk => p.join(_engine, 'common', 'flutter_patched_sdk');
  String get tester => p.join(_engine, _host, 'flutter_tester');
  String get icuData => p.join(_engine, _host, 'icudtl.dat');

  /// Where `flutter test` points fontconfig.
  String get fonts => p.join(_cache, 'artifacts');

  /// The SDK [executable] (`flutter`, or a path to it) belongs to, or `null`
  /// with the reason passed to [onMissing].
  static FlutterSdk? locate(
    String executable, {
    required void Function(String reason) onMissing,
  }) {
    final String? host = _hostDirectory();
    if (host == null) {
      onMissing('no flutter_tester for ${Abi.current()}');
      return null;
    }
    final String? found = _onPath(executable);
    if (found == null) {
      onMissing('$executable is not on PATH');
      return null;
    }
    final FlutterSdk sdk = FlutterSdk._(
      p.dirname(p.dirname(File(found).resolveSymbolicLinksSync())),
      host,
    );
    for (final String path in <String>[
      sdk.dartAotRuntime,
      sdk.frontendServer,
      sdk.tester,
    ]) {
      if (!File(path).existsSync()) {
        onMissing('$path is missing — run `flutter precache`');
        return null;
      }
    }
    if (!Directory(sdk.patchedSdk).existsSync()) {
      onMissing('${sdk.patchedSdk} is missing — run `flutter precache`');
      return null;
    }
    return sdk;
  }

  static String? _hostDirectory() => switch (Abi.current()) {
    Abi.macosArm64 || Abi.macosX64 => 'darwin-x64',
    Abi.linuxX64 => 'linux-x64',
    Abi.linuxArm64 => 'linux-arm64',
    _ => null,
  };

  static String? _onPath(String executable) {
    if (p.isAbsolute(executable) || executable.contains('/')) {
      final String path = p.absolute(executable);
      return File(path).existsSync() ? path : null;
    }
    for (final String dir in (Platform.environment['PATH'] ?? '').split(':')) {
      final String path = p.join(dir, executable);
      if (dir.isNotEmpty && File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  /// The command that runs [dill], a compiled test entry, the way
  /// `flutter test` does: [mutantId] picks the mutant a switched file runs as,
  /// `null` none.
  ProcessCommand testerCommand(
    String dill, {
    required String workingDirectory,
    required String packageConfig,
    required String assets,
    required String fontConfig,
    required String appName,
    int? mutantId,
  }) => ProcessCommand(
    tester,
    <String>[
      '--disable-vm-service',
      if (File(icuData).existsSync()) '--icu-data-file-path=$icuData',
      '--enable-checked-mode',
      '--verify-entry-points',
      '--enable-software-rendering',
      '--skia-deterministic-rendering',
      '--enable-dart-profiling',
      '--non-interactive',
      '--use-test-fonts',
      '--disable-asset-fonts',
      '--packages=$packageConfig',
      '--flutter-assets-dir=$assets',
      dill,
    ],
    workingDirectory: workingDirectory,
    environment: <String, String>{
      'FLUTTER_TEST': 'true',
      'FONTCONFIG_FILE': fontConfig,
      'APP_NAME': appName,
      'UNIT_TEST_ASSETS': assets,
      // Always set, so a value this process inherited cannot switch a mutant
      // on for the unmutated run.
      mutantIdVariable: mutantId?.toString() ?? '',
    },
  );

  /// The fontconfig file `flutter test` writes, pointing at the SDK's fonts.
  String fontConfig() =>
      '<fontconfig>\n'
      '  <dir>$fonts</dir>\n'
      '  <cachedir>/var/cache/fontconfig</cachedir>\n'
      '</fontconfig>\n';
}

/// The Dart program a test file runs as: the test's `main` handed straight
/// to `package:test_core`, with the golden-file setup and
/// `flutter_test_config.dart` wrapping `flutter test` gives it, exiting 0
/// when every test passed and 1 when one did not.
String testEntry(String testFile, {String? config}) {
  final String test = Uri.file(testFile).toString();
  return <String>[
    "import 'dart:io' as io;",
    '',
    "import 'package:flutter_test/flutter_test.dart';",
    // Not a public library, but the only runner for a `main` already in
    // this isolate; a test file whose package lacks it fails to compile and
    // goes back to `flutter test`.
    "import 'package:test_core/src/direct_run.dart';",
    '',
    "import '$test' as test;",
    if (config != null) "import '${Uri.file(config)}' as config;",
    '',
    'Future<void> main() async {',
    "  goldenFileComparator = LocalFileComparator(Uri.parse('$test'));",
    '  autoUpdateGoldenFiles = false;',
    '  final bool passed = await directRunTests(',
    config == null
        ? '    test.main,'
        : '    () => config.testExecutable(test.main),',
    '  );',
    '  io.exit(passed ? 0 : 1);',
    '}',
    '',
  ].join('\n');
}

/// The `flutter_test_config.dart` `flutter test` would wrap [testFile] in:
/// the nearest one from its directory up to [root], or `null`.
String? testConfigFor(String testFile, String root) {
  for (
    String dir = p.dirname(testFile);
    p.equals(dir, root) || p.isWithin(root, dir);
    dir = p.dirname(dir)
  ) {
    final String config = p.join(dir, 'flutter_test_config.dart');
    if (File(config).existsSync()) {
      return config;
    }
  }
  return null;
}
