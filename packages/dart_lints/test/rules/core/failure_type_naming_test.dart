import 'package:dart_lints/src/config/dart_lints_config_exception.dart';
import 'package:dart_lints/src/rules/core/failure_type_naming.dart';
import 'package:test/test.dart';

import '../naming_fixture.dart';

const String _source = r'''
class InvariantError extends Error {}
class InvariantBroken extends Error {}
class DerivedError extends InvariantError {}

class ParseException implements Exception {}
class ParseFailure implements Exception {}
class QuotaExceeded implements Exception {}

class NotReallyError {}
class NotReallyException {}
class NotReallyFailure {}
class Plain {}
''';

Future<Set<String>> _reported({String? failureWord}) async => reportedNames(
  await NamingFixture().resolved(
    FailureTypeNaming(failureWord: failureWord),
    _source,
  ),
  _source,
);

void main() {
  test('[partition] with Exception as the failure word', () async {
    expect(await _reported(), <String>{
      'InvariantBroken',
      'ParseFailure',
      'QuotaExceeded',
      'NotReallyError',
      'NotReallyException',
    });
  });

  test(
    '[partition] with Failure as the failure word, an Exception '
    'implementation ends in Failure, and a Failure claims to be one',
    () async {
      expect(await _reported(failureWord: 'Failure'), <String>{
        'InvariantBroken',
        'ParseException',
        'QuotaExceeded',
        'NotReallyError',
        'NotReallyException',
        'NotReallyFailure',
      });
    },
  );

  test(
    '[state] an Error subtype further down the chain is still an Error',
    () async {
      expect(await _reported(), isNot(contains('DerivedError')));
    },
  );

  test('[decision] a subtype of an exempt type is named by its own scheme and '
      'not checked', () async {
    const String source = r'''
abstract class LintRule {}
class AvoidCatchingError extends LintRule {}
class AvoidThrowingException extends LintRule {}
class CatchingError {}
''';
    expect(
      reportedNames(
        await NamingFixture().resolved(
          FailureTypeNaming(exemptSubtypesOf: <String>['LintRule']),
          source,
        ),
        source,
      ),
      <String>{'CatchingError'},
    );
  });

  test('[error] a failure word other than Exception or Failure is a '
      'configuration fault', () {
    expect(
      () => FailureTypeNaming(failureWord: 'Fault'),
      throwsA(isA<DartLintsConfigException>()),
    );
  });
}
