/// A type name split into its words, as the naming rules read it.
///
/// A name reads as `<category words><kind word>`: `ConnectionTimeoutFailure`
/// is the `Failure` kind, and `ConnectionTimeout` says which one. The kind is
/// the last word.
///
/// Words split at case changes, and a run of capitals is one word — an
/// acronym — until the capital that starts the next word: `HTTPClientError` is
/// `HTTP`, `Client`, `Error`. Digits stay with the word before them. A leading
/// `_` or `$` is not part of any word.
class NameWords {
  NameWords(this.name)
    : words = _split(name.replaceFirst(RegExp(r'^[_$]+'), ''));

  final String name;
  final List<String> words;

  static final RegExp _word = RegExp(
    r'[A-Z]+(?![a-z])[0-9]*|[A-Z]?[a-z]+[0-9]*|[0-9]+',
  );

  static List<String> _split(String name) => _word
      .allMatches(name)
      .map((Match m) => m.group(0) ?? '')
      .toList(growable: false);

  /// The kind word, or `''` for a name with no words.
  String get kind => words.isEmpty ? '' : words.last;

  /// Everything before the kind word, joined back together.
  String get category =>
      words.isEmpty ? '' : words.sublist(0, words.length - 1).join();

  /// Whether one of the words is exactly [word].
  bool contains(String word) => words.contains(word);
}
