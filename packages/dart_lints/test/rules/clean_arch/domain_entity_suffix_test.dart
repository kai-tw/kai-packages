import 'package:dart_lints/src/rules/clean_arch/domain_entity_suffix.dart';
import 'package:test/test.dart';

import '../naming_fixture.dart';

const String _source = r'''
class Book {}
class BookEntity {}
abstract class ShelfEntity {}
class _Cursor {}
enum BookFormat { epub, pdf }
''';

Set<String> _reported(DomainEntitySuffix rule, String path) => reportedNames(
  NamingFixture().parsed(rule, _source, path: path),
  _source,
);

void main() {
  test('[partition] in a feature\'s domain/entities, only a public class '
      'without the suffix is reported', () {
    expect(
      _reported(
        DomainEntitySuffix(),
        'lib/features/library/domain/entities/book.dart',
      ),
      <String>{'Book'},
    );
  });

  test('[partition] outside the entity directory nothing is checked', () {
    for (final String path in <String>[
      'lib/features/library/domain/repositories/book.dart',
      'lib/features/library/data/entities/book.dart',
      'lib/shared/domain/entities/book.dart',
    ]) {
      expect(_reported(DomainEntitySuffix(), path), isEmpty, reason: path);
    }
  });

  test('[decision] a forbidden word fails an entity that has the suffix, by '
      'whole word only', () {
    const String source = r'''
class BookDataEntity {}
class DatabaseEntity {}
class BookEntity {}
''';
    expect(
      reportedNames(
        NamingFixture().parsed(
          DomainEntitySuffix(forbiddenWords: <String>['Data']),
          source,
          path: 'lib/features/library/domain/entities/book.dart',
        ),
        source,
      ),
      <String>{'BookDataEntity'},
    );
  });

  test('[decision] the roots, the directory and the suffix are the '
      'project\'s', () {
    expect(
      _reported(
        DomainEntitySuffix(
          featureRoots: <String>['lib/modules'],
          entityDirectory: 'models',
          suffix: 'Model',
        ),
        'lib/modules/library/domain/models/book.dart',
      ),
      <String>{'Book', 'BookEntity', 'ShelfEntity'},
    );
  });
}
