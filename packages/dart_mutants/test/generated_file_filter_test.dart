import 'package:dart_mutants/src/generated_file_filter.dart';
import 'package:test/test.dart';

void main() {
  for (final String suffix in <String>[
    '.g.dart',
    '.freezed.dart',
    '.mocks.dart',
    '.config.dart',
    '.gen.dart',
  ]) {
    test('[partition] a $suffix file is generated', () {
      expect(isGeneratedFile('lib/src/foo$suffix'), isTrue);
    });
  }

  test(
    '[partition] a path under generated/ is generated, whatever it ends with',
    () {
      expect(isGeneratedFile('lib/src/generated/foo.dart'), isTrue);
    },
  );

  test('[partition] an ordinary source file is not generated', () {
    expect(isGeneratedFile('lib/src/foo.dart'), isFalse);
  });

  test(
    '[boundary] a suffix appearing mid-path, not at the end, does not count',
    () {
      expect(isGeneratedFile('lib/src/foo.g.dart.bak'), isFalse);
    },
  );
}
