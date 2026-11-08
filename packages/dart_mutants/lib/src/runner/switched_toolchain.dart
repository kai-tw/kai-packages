import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_command.dart';
import 'switched_file.dart';

/// How a switched run compiles a test file and runs the result: the pieces
/// of a Flutter SDK `flutter test` uses, or of a Dart SDK `dart test` uses,
/// started directly so each test file is compiled once for a whole run.
///
/// The flags passed below are the ones the test runners pass themselves.
/// They are not a public interface and can change with an SDK. Every test
/// file runs unmutated first and has to pass, so a change that breaks them
/// stops the run, saying which file, rather than score anything.
abstract interface class SwitchedToolchain {
  /// The packages a compiled test entry imports, which the package under
  /// test has to resolve.
  List<String> get requiredPackages;

  /// The compiler, kept running across compiles: its executable first.
  List<String> compiler({
    required String outputDill,
    required String packageConfig,
  });

  /// Writes what [command] needs into [work], once per lane.
  void prepare(String work);

  /// Runs [dill] from [workingDirectory]: [mutantId] picks the mutant the
  /// switched files run as, `null` none; [reached] names the file they write
  /// the switches they reach to, `null` none — see [reachedVariable].
  ProcessCommand command(
    String dill, {
    required String workingDirectory,
    required String packageConfig,
    required String work,
    int? mutantId,
    String? reached,
  });

  /// The program the test file at [testFile] (inside [root]) runs as,
  /// handed [arguments] — the test command's own filtering options — and
  /// [testTimeout], the longest one test may run, `null` no limit.
  String entry(
    String testFile, {
    required String root,
    required List<String> arguments,
    Duration? testTimeout,
  });
}

/// The Flutter SDK [FlutterToolchain.locate] found: `flutter_tester` and the
/// compiler `flutter test` keeps running.
class FlutterToolchain implements SwitchedToolchain {
  FlutterToolchain._(this.sdkRoot, this._host, this._packageRoot);

  /// The SDK's root directory, which holds `bin/flutter`.
  final String sdkRoot;

  /// The engine's host directory name, e.g. `darwin-x64`.
  final String _host;

  /// The package under test, whose `build/unit_test_assets` a run of the
  /// test command left behind.
  final String _packageRoot;

  String get _cache => p.join(sdkRoot, 'bin', 'cache');
  String get _engine => p.join(_cache, 'artifacts', 'engine');

  String get _dartAotRuntime =>
      p.join(_cache, 'dart-sdk', 'bin', 'dartaotruntime');
  String get _frontendServer => p.join(
    _cache,
    'dart-sdk',
    'bin',
    'snapshots',
    'frontend_server_aot.dart.snapshot',
  );
  String get _patchedSdk => p.join(_engine, 'common', 'flutter_patched_sdk');
  String get _tester => p.join(_engine, _host, 'flutter_tester');
  String get _icuData => p.join(_engine, _host, 'icudtl.dat');

  /// The SDK [executable] (`flutter`, or a path to it) belongs to, or `null`
  /// with the reason passed to [onMissing].
  static FlutterToolchain? locate(
    String executable, {
    required String packageRoot,
    required void Function(String reason) onMissing,
  }) {
    final String? host = _hostDirectory();
    if (host == null) {
      onMissing('no flutter_tester for ${Abi.current()}');
      return null;
    }
    final String? found = onPath(executable);
    if (found == null) {
      onMissing('$executable is not on PATH');
      return null;
    }
    final FlutterToolchain sdk = FlutterToolchain._(
      p.dirname(p.dirname(File(found).resolveSymbolicLinksSync())),
      host,
      packageRoot,
    );
    for (final String path in <String>[
      sdk._dartAotRuntime,
      sdk._frontendServer,
      sdk._tester,
    ]) {
      if (!File(path).existsSync()) {
        onMissing('$path is missing — run `flutter precache`');
        return null;
      }
    }
    if (!Directory(sdk._patchedSdk).existsSync()) {
      onMissing('${sdk._patchedSdk} is missing — run `flutter precache`');
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

  @override
  List<String> get requiredPackages => const <String>[
    'flutter_test',
    'dart_mutants',
  ];

  @override
  List<String> compiler({
    required String outputDill,
    required String packageConfig,
  }) => <String>[
    _dartAotRuntime,
    _frontendServer,
    '--sdk-root',
    '$_patchedSdk${p.separator}',
    '--incremental',
    '--no-print-incremental-dependencies',
    '--target=flutter',
    '--experimental-emit-debug-metadata',
    '--output-dill',
    outputDill,
    '--packages',
    packageConfig,
    '-Ddart.vm.profile=false',
    '-Ddart.vm.product=false',
    '--enable-asserts',
    '--track-widget-creation',
    '--verbosity=error',
  ];

  @override
  void prepare(String work) {
    File(p.join(work, 'fonts.conf')).writeAsStringSync(
      '<fontconfig>\n'
      '  <dir>${p.join(_cache, 'artifacts')}</dir>\n'
      '  <cachedir>/var/cache/fontconfig</cachedir>\n'
      '</fontconfig>\n',
    );
    Directory(p.join(work, 'assets')).createSync();
  }

  /// The assets `flutter test` built for the package, which the baseline —
  /// or under the selection, the run that builds them — left behind; an
  /// empty directory when there are none, and a test that needs them then
  /// fails unmutated, which stops the run.
  String _assets(String work) {
    final String built = p.join(_packageRoot, 'build', 'unit_test_assets');
    return Directory(built).existsSync() ? built : p.join(work, 'assets');
  }

  @override
  ProcessCommand command(
    String dill, {
    required String workingDirectory,
    required String packageConfig,
    required String work,
    int? mutantId,
    String? reached,
  }) {
    final String assets = _assets(work);
    return ProcessCommand(
      _tester,
      <String>[
        '--disable-vm-service',
        if (File(_icuData).existsSync()) '--icu-data-file-path=$_icuData',
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
        'FONTCONFIG_FILE': p.join(work, 'fonts.conf'),
        'APP_NAME': packageNameOf(_packageRoot) ?? '',
        'UNIT_TEST_ASSETS': assets,
        // Always set, so a value this process inherited cannot switch a
        // mutant on for the unmutated run.
        mutantIdVariable: mutantId?.toString() ?? '',
        reachedVariable: reached ?? '',
      },
    );
  }

  /// The test's `main` with the golden-file setup and the
  /// `flutter_test_config.dart` wrapping `flutter test` gives it.
  @override
  String entry(
    String testFile, {
    required String root,
    required List<String> arguments,
    Duration? testTimeout,
  }) {
    final String test = Uri.file(testFile).toString();
    final String? config = testConfigFor(testFile, root);
    return <String>[
      "import 'package:dart_mutants/switched_suite.dart';",
      "import 'package:flutter_test/flutter_test.dart';",
      '',
      "import '$test' as test;",
      if (config != null) "import '${Uri.file(config)}' as config;",
      '',
      'Future<void> main() async {',
      "  goldenFileComparator = LocalFileComparator(Uri.parse('$test'));",
      '  autoUpdateGoldenFiles = false;',
      '  await runSwitchedSuite(',
      config == null
          ? '    test.main,'
          : '    () => config.testExecutable(test.main),',
      '    path: ${_literal(p.relative(testFile, from: root))},',
      '    arguments: ${_literals(arguments)},',
      ?_timeout(testTimeout, '    '),
      '  );',
      '}',
      '',
    ].join('\n');
  }
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

/// The Dart SDK this process runs on: its compiler and its VM, as
/// `dart test` uses them.
class DartToolchain implements SwitchedToolchain {
  DartToolchain._(this.sdkRoot, this._platform);

  /// The SDK's root directory, which holds `bin/dart`.
  final String sdkRoot;

  /// The VM's platform kernel the compiler builds against.
  final String _platform;

  String get _dartAotRuntime => p.join(sdkRoot, 'bin', 'dartaotruntime');
  String get _frontendServer => p.join(
    sdkRoot,
    'bin',
    'snapshots',
    'frontend_server_aot.dart.snapshot',
  );
  String get _dart => p.join(sdkRoot, 'bin', 'dart');

  /// The SDK this process runs on — the one `dart run dart_mutants` and so,
  /// on the same PATH, `dart test` use — or `null` with the reason passed to
  /// [onMissing].
  static DartToolchain? locate({
    required void Function(String reason) onMissing,
  }) {
    final String sdk = p.dirname(
      p.dirname(File(Platform.resolvedExecutable).resolveSymbolicLinksSync()),
    );
    final String internal = p.join(sdk, 'lib', '_internal');
    final String? platform = <String>[
      p.join(internal, 'vm_platform_strong.dill'),
      p.join(internal, 'vm_platform.dill'),
    ].where((String path) => File(path).existsSync()).firstOrNull;
    if (platform == null) {
      onMissing('no VM platform kernel under $internal');
      return null;
    }
    final DartToolchain toolchain = DartToolchain._(sdk, platform);
    for (final String path in <String>[
      toolchain._dartAotRuntime,
      toolchain._frontendServer,
      toolchain._dart,
    ]) {
      if (!File(path).existsSync()) {
        onMissing('$path is missing');
        return null;
      }
    }
    return toolchain;
  }

  @override
  List<String> get requiredPackages => const <String>['dart_mutants'];

  @override
  List<String> compiler({
    required String outputDill,
    required String packageConfig,
  }) => <String>[
    _dartAotRuntime,
    _frontendServer,
    '--sdk-root',
    '${p.dirname(_platform)}${p.separator}',
    '--platform',
    _platform,
    '--incremental',
    '--no-print-incremental-dependencies',
    '--target=vm',
    '--output-dill',
    outputDill,
    '--packages',
    packageConfig,
    '--enable-asserts',
    '--verbosity=error',
  ];

  @override
  void prepare(String work) {}

  @override
  ProcessCommand command(
    String dill, {
    required String workingDirectory,
    required String packageConfig,
    required String work,
    int? mutantId,
    String? reached,
  }) => ProcessCommand(
    _dart,
    <String>['--enable-asserts', '--packages=$packageConfig', dill],
    workingDirectory: workingDirectory,
    environment: <String, String>{
      mutantIdVariable: mutantId?.toString() ?? '',
      reachedVariable: reached ?? '',
    },
  );

  @override
  String entry(
    String testFile, {
    required String root,
    required List<String> arguments,
    Duration? testTimeout,
  }) => <String>[
    "import 'package:dart_mutants/switched_suite.dart';",
    '',
    "import '${Uri.file(testFile)}' as test;",
    '',
    'Future<void> main() => runSwitchedSuite(',
    '  test.main,',
    '  path: ${_literal(p.relative(testFile, from: root))},',
    '  arguments: ${_literals(arguments)},',
    ?_timeout(testTimeout, '  '),
    ');',
    '',
  ].join('\n');
}

/// Where [executable] resolves on PATH, or `null`; a path is taken as is.
String? onPath(String executable) {
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

/// The `name:` in [root]'s `pubspec.yaml`, or `null`.
String? packageNameOf(String root) {
  final File pubspec = File(p.join(root, 'pubspec.yaml'));
  if (!pubspec.existsSync()) {
    return null;
  }
  return RegExp(
    r'^name:\s*([A-Za-z0-9_]+)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync())?.group(1);
}

String _literal(String value) =>
    "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

/// The `testTimeout:` argument of an entry, at [indent]; `null` for none.
String? _timeout(Duration? limit, String indent) => limit == null
    ? null
    : '${indent}testTimeout: const Duration(milliseconds: '
          '${limit.inMilliseconds}),';

String _literals(List<String> values) =>
    '<String>[${values.map(_literal).join(', ')}]';
