import 'package:dart_lints/src/rules/core/name_words.dart';
import 'package:test/test.dart';

void main() {
  for (final (String name, List<String> words) in <(String, List<String>)>[
    ('ConnectionTimeoutFailure', <String>['Connection', 'Timeout', 'Failure']),
    ('HTTPClientError', <String>['HTTP', 'Client', 'Error']),
    ('IOError', <String>['IO', 'Error']),
    ('Base64Codec', <String>['Base64', 'Codec']),
    ('_PrivateState', <String>['Private', 'State']),
    (r'_$Generated', <String>['Generated']),
    ('Failure', <String>['Failure']),
  ]) {
    test('[partition] $name splits into $words', () {
      expect(NameWords(name).words, words);
    });
  }

  test('[partition] the kind is the last word, the category the rest', () {
    final NameWords words = NameWords('ConnectionTimeoutFailure');
    expect(words.kind, 'Failure');
    expect(words.category, 'ConnectionTimeout');
  });

  test('[boundary] a single word has no category', () {
    expect(NameWords('Failure').category, '');
  });

  test('[boundary] a name with no words has no kind', () {
    final NameWords words = NameWords('_');
    expect(words.kind, '');
    expect(words.category, '');
  });

  test('[decision] a word matches whole, never as part of a longer one', () {
    expect(NameWords('HelperText').contains('Helper'), isTrue);
    expect(NameWords('Helpers').contains('Helper'), isFalse);
  });
}
