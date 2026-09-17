/// A forbidden word, and the types whose subtypes may use it anyway.
class ScopedWord {
  const ScopedWord({required this.word, this.unlessExtends = const <String>[]});

  factory ScopedWord.fromMap(Map<String, Object?> map) => ScopedWord(
    word: map['word']! as String,
    unlessExtends: <String>[
      for (final Object? name
          in map['unlessExtends'] as List<Object?>? ?? const <Object?>[])
        name! as String,
    ],
  );

  final String word;

  /// Types, by name, that may use [word] — themselves and their subtypes.
  final List<String> unlessExtends;
}
