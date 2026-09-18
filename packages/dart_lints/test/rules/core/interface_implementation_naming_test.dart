import 'package:dart_lints/src/config/dart_lints_config_exception.dart';
import 'package:dart_lints/src/rules/core/interface_implementation_naming.dart';
import 'package:test/test.dart';

import '../naming_fixture.dart';

const String _source = r'''
abstract interface class ReaderRepository {
  String read();
}

abstract class BookStore {
  static BookStore create() => SqliteBookStore();
  int count();
}

abstract class Shape {
  int sides() => 0;
}

class ReaderRepositoryImpl implements ReaderRepository {
  @override
  String read() => '';
}

class SqliteReaderRepository implements ReaderRepository {
  @override
  String read() => '';
}

class SqliteBookStore extends BookStore {
  @override
  int count() => 0;
}

class BookStoreImpl implements BookStore {
  @override
  int count() => 0;
}

class ReaderRepositorySqliteImpl implements ReaderRepository {
  @override
  String read() => '';
}

class FileReader implements ReaderRepository {
  @override
  String read() => '';
}

class Square extends Shape {}

abstract class CachedReaderRepository implements ReaderRepository {}

class Name implements Comparable<Name> {
  @override
  int compareTo(Name other) => 0;
}
''';

Future<Set<String>> _reported(String style, {String? path}) async =>
    reportedNames(
      await NamingFixture().resolved(
        InterfaceImplementationNaming(style: style),
        _source,
        path: path ?? 'lib/subject.dart',
      ),
      _source,
    );

void main() {
  test('[partition] impl: only <Interface>Impl passes, for an implements or '
      'an extends of a purely abstract class', () async {
    expect(await _reported('impl'), <String>{
      'SqliteReaderRepository',
      'SqliteBookStore',
      'ReaderRepositorySqliteImpl',
      'FileReader',
    });
  });

  test(
    '[partition] tech_prefix: only <Technology><Interface> passes',
    () async {
      expect(await _reported('tech_prefix'), <String>{
        'ReaderRepositoryImpl',
        'BookStoreImpl',
        'ReaderRepositorySqliteImpl',
        'FileReader',
      });
    },
  );

  test('[partition] impl_or_prefix: both forms pass, and neither a bare name '
      'nor a prefixed Impl does', () async {
    expect(await _reported('impl_or_prefix'), <String>{
      'ReaderRepositorySqliteImpl',
      'FileReader',
    });
  });

  test('[state] impl_or_prefix leaves an existing <Interface>Impl alone when '
      'a second implementation arrives — no count, so no file turns red for '
      'a change elsewhere', () async {
    const String source = r'''
abstract interface class ReaderRepository {
  String read();
}

class ReaderRepositoryImpl implements ReaderRepository {
  @override
  String read() => '';
}

class SqliteReaderRepository implements ReaderRepository {
  @override
  String read() => '';
}
''';
    expect(
      await NamingFixture().resolved(
        InterfaceImplementationNaming(style: 'impl_or_prefix'),
        source,
      ),
      isEmpty,
    );
  });

  test('[decision] a class with a concrete member is not an interface, an '
      'abstract implementation is not an implementation, and an SDK interface '
      'is not the package\'s', () async {
    final Set<String> reported = await _reported('impl');
    expect(reported, isNot(contains('Square')));
    expect(reported, isNot(contains('CachedReaderRepository')));
    expect(reported, isNot(contains('Name')));
  });

  test('[boundary] a file outside the package\'s lib is not checked', () async {
    expect(await _reported('impl', path: 'test/subject_test.dart'), isEmpty);
  });

  test('[error] a style other than impl or tech_prefix is a configuration '
      'fault', () {
    expect(
      () => InterfaceImplementationNaming(style: 'suffix'),
      throwsA(isA<DartLintsConfigException>()),
    );
  });
}
