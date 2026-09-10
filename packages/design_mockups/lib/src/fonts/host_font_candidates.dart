import 'dart:io';

import 'mockup_font_face.dart';
import 'mockup_font_family.dart';

/// The cache the `fetch-fonts` entry point fills. First in every chain,
/// because a downloaded pinned face is the only source that renders the same
/// on every machine.
const String kMockupFontCacheDir = '.dart_tool/design_mockups/fonts';

/// Broad-coverage host faces, most complete first.
///
/// This is a **chain**, and the ordering is the whole of it: the engine walks
/// it per character, so a glyph the first face lacks is taken from the next
/// one that has it.
///
/// Entries are per-script rather than one "unicode" face because no installed
/// face covers Traditional Chinese, Simplified Chinese, Japanese and Korean
/// well at once, and a Han character that resolves to the wrong regional face
/// is a subtler defect than tofu: it renders, and it renders wrong.
const List<String> kHostCjkFontPaths = <String>[
  // Downloaded Noto, if `fetch-fonts` has run. Pinned, script-specific, and
  // identical everywhere.
  '$kMockupFontCacheDir/NotoSansTC-Regular.ttf',
  '$kMockupFontCacheDir/NotoSansSC-Regular.ttf',
  '$kMockupFontCacheDir/NotoSansJP-Regular.ttf',
  '$kMockupFontCacheDir/NotoSansKR-Regular.ttf',

  // macOS. A `.ttc` collection loads its first face, which for these is a
  // regular weight.
  '/System/Library/Fonts/PingFang.ttc',
  '/System/Library/Fonts/Supplemental/Songti.ttc',
  '/System/Library/Fonts/Hiragino Sans GB.ttc',
  '/System/Library/Fonts/ヒラギノ角ゴシック W4.ttc',
  '/System/Library/Fonts/AppleSDGothicNeo.ttc',
  '/System/Library/Fonts/Apple Symbols.ttf',
  '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',

  // Linux / CI.
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc',
  '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
];

/// Emoji, which is its own kind of tofu: a status chip or a piece of sample
/// copy carrying one renders an empty box, and the reviewer reads that as a
/// missing asset in the design rather than a missing font on the host.
const List<String> kHostEmojiFontPaths = <String>[
  '/System/Library/Fonts/Apple Color Emoji.ttc',
  '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
];

/// The prefix each link of the fallback chain is registered under.
///
/// **One family per FILE, not one family holding every file.** Several faces
/// added to a single `FontLoader` are alternates of ONE family, and the engine
/// chooses between them by the font's own WEIGHT metadata — it does not walk
/// them looking for a glyph. A family built that way therefore covers exactly
/// what its first matching face covers, and the rest are dead weight.
/// Per-glyph fallback is `fontFamilyFallback`'s job, and that takes a list of
/// family NAMES, which is why each file needs one of its own.
///
/// This was found by looking at a render rather than by reasoning: a heading
/// came out one character short — no box, no warning — because 歡 is absent
/// from the Simplified face that happened to win the weight match, and nothing
/// went looking any further.
const String kMockupFallbackFamilyPrefix = 'DesignMockupFallback';

/// The icon family Flutter's own widgets ask for. Ships with the SDK, so this
/// is found or the SDK is broken — and without it every `Icon` in the render
/// is a tofu box, which passes every file-exists and dimension check silently.
const String kMaterialIconsFamily = 'MaterialIcons';

/// Everything under the font cache directory, so a face dropped in by hand is
/// picked up without editing this list.
List<String> cachedFontPaths() {
  final Directory dir = Directory(kMockupFontCacheDir);
  if (!dir.existsSync()) {
    return const <String>[];
  }
  return dir
      .listSync()
      .whereType<File>()
      .map((File f) => f.path)
      .where(
        (String path) =>
            path.endsWith('.ttf') ||
            path.endsWith('.otf') ||
            path.endsWith('.ttc'),
      )
      .toList()
    ..sort();
}

/// The Material icon font shipped with the installed SDK.
List<MockupFontFace> materialIconFaces() {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  return <MockupFontFace>[
    if (root != null)
      MockupFontFace(
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ),
  ];
}

/// One family per broad-coverage face this host has, in chain order.
///
/// Empty on a host with none of them, which the caller turns into a loud
/// failure rather than a page of boxes.
List<MockupFontFamily> defaultFallbackFamilies() {
  final Set<String> seen = <String>{};
  final List<String> paths = <String>[
    for (final String path in <String>[
      ...cachedFontPaths(),
      ...kHostCjkFontPaths,
      ...kHostEmojiFontPaths,
    ])
      if (seen.add(path) && File(path).existsSync()) path,
  ];
  return <MockupFontFamily>[
    for (int i = 0; i < paths.length; i++)
      MockupFontFamily.bundled(
        family: '$kMockupFallbackFamilyPrefix$i',
        faces: <MockupFontFace>[MockupFontFace(paths[i])],
      ),
  ];
}
