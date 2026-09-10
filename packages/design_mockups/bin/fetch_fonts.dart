/// Downloads a pinned Noto CJK set into the render font cache.
///
///     dart run design_mockups:fetch_fonts
///
/// Optional, and worth running once per machine. The harness falls back to
/// whatever broad-coverage faces the host has, which is enough on a developer
/// Mac and is often nothing at all in CI — and the failure mode there is not an
/// error but a page of tofu boxes that looks like a bug in the app. A pinned
/// download removes both the CI hole and the machine-to-machine difference: the
/// same bytes render the same glyphs everywhere.
///
/// The files land in `.dart_tool/design_mockups/fonts/`, which pub already
/// ignores, so nothing is committed and nothing needs cleaning up.
library;

import 'dart:io';

import 'package:design_mockups/design_mockups.dart';
import 'package:path/path.dart' as p;

/// Google Fonts' variable TTFs, pinned to a commit rather than to a branch.
///
/// A branch ref would defeat the point of downloading at all: the cache exists
/// to make a render identical on every machine and in CI, and `main` moves.
/// Bump this deliberately when a font update is wanted.
const String _commit = '8e44913e4ff26fc997e6856c1ec40ff4791c98c5';
const String _base =
    'https://raw.githubusercontent.com/google/fonts/$_commit/ofl';

const Map<String, String> _fonts = <String, String>{
  'NotoSansTC-Regular.ttf': '$_base/notosanstc/NotoSansTC%5Bwght%5D.ttf',
  'NotoSansSC-Regular.ttf': '$_base/notosanssc/NotoSansSC%5Bwght%5D.ttf',
  'NotoSansJP-Regular.ttf': '$_base/notosansjp/NotoSansJP%5Bwght%5D.ttf',
  'NotoSansKR-Regular.ttf': '$_base/notosanskr/NotoSansKR%5Bwght%5D.ttf',
};

Future<void> main(List<String> args) async {
  final bool force = args.contains('--force');
  final Directory dir = Directory(kMockupFontCacheDir)
    ..createSync(recursive: true);

  final HttpClient client = HttpClient();
  try {
    for (final MapEntry<String, String> font in _fonts.entries) {
      final File file = File(p.join(dir.path, font.key));
      if (file.existsSync() && !force) {
        stdout.writeln('design_mockups: ${font.key} already cached');
        continue;
      }
      stdout.writeln('design_mockups: fetching ${font.key}');
      final HttpClientRequest request = await client.getUrl(
        Uri.parse(font.value),
      );
      final HttpClientResponse response = await request.close();
      if (response.statusCode != 200) {
        // Loud and specific: a half-filled cache renders *some* scripts and
        // tofus the rest, which reads as a font-selection bug rather than a
        // download that 404'd.
        stderr.writeln(
          'design_mockups: ${font.key} failed (HTTP ${response.statusCode}) '
          'from ${font.value}',
        );
        exitCode = 1;
        continue;
      }
      // Download beside the target and rename on completion, so a dropped
      // connection leaves a `.part` nobody reads instead of a truncated
      // `.ttf` that `existsSync()` then treats as cached forever — and
      // `FontLoader` would hand a corrupt face to every later render.
      final File part = File('${file.path}.part');
      try {
        await response.pipe(part.openWrite());
        part.renameSync(file.path);
        // The two concrete shapes this can take: the connection dropping
        // mid-transfer, and the cache directory being unwritable.
      } on HttpException catch (error) {
        _discard(part);
        stderr.writeln('design_mockups: ${font.key} failed — $error');
        exitCode = 1;
      } on FileSystemException catch (error) {
        _discard(part);
        stderr.writeln('design_mockups: ${font.key} failed — $error');
        exitCode = 1;
      }
    }
  } finally {
    client.close();
  }

  stdout.writeln('design_mockups: font cache is ${dir.path}');
}

/// Removes a partial download, so the next run refetches rather than treating
/// a truncated file as cached.
void _discard(File part) {
  if (part.existsSync()) {
    part.deleteSync();
  }
}
