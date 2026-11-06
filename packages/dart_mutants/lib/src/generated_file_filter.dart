/// Whether [filePath] is generated output this package should never mutate.
///
/// Not configurable: a generator's own output is never hand-edited, so
/// mutating it tests nothing about anyone's code. The suffixes are the ones
/// code generators commonly write — serialisation and data classes, mocks,
/// dependency-injection configuration (`.config.dart`) and asset references
/// (`.gen.dart`) — and `generated/` the directory they commonly write into.
bool isGeneratedFile(String filePath) {
  const List<String> suffixes = <String>[
    '.g.dart',
    '.freezed.dart',
    '.mocks.dart',
    '.config.dart',
    '.gen.dart',
  ];
  if (suffixes.any(filePath.endsWith)) {
    return true;
  }
  return filePath.contains('/generated/');
}
