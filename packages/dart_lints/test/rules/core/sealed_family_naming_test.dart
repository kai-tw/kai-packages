import 'package:dart_lints/src/lint_rule_base.dart';
import 'package:dart_lints/src/rules/core/sealed_family_naming.dart';
import 'package:test/test.dart';

import '../naming_fixture.dart';

const String _source = r'''
sealed class ConnectionFailure {}

class ConnectionTimeoutFailure extends ConnectionFailure {}
class ConnectionRefusedFailure implements ConnectionFailure {}

class TimeoutFailure extends ConnectionFailure {}
class ConnectionTimeout extends ConnectionFailure {}
class ConnectionsLostFailure extends ConnectionFailure {}
class ConnectionFailure2 extends ConnectionFailure {}

sealed class Failure {}
class DiskFailure extends Failure {}
class DiskFault extends Failure {}

abstract class OpenFamily {}
class Unrelated extends OpenFamily {}

sealed class ReaderEvent {}
sealed class ReaderPageEvent extends ReaderEvent {}
class ReaderPageTurnedEvent extends ReaderPageEvent {}
class PageTurnedEvent extends ReaderPageEvent {}
''';

void main() {
  late Set<String> reported;

  setUpAll(() async {
    final List<LintViolation> violations = await NamingFixture().resolved(
      SealedFamilyNaming(),
      _source,
    );
    reported = reportedNames(violations, _source);
  });

  test('[partition] members named <category><case><kind> pass, whether they '
      'extend or implement the base', () {
    expect(
      reported,
      isNot(
        anyOf(
          contains('ConnectionTimeoutFailure'),
          contains('ConnectionRefusedFailure'),
        ),
      ),
    );
  });

  test(
    '[partition] a member missing the category, or the kind, is reported',
    () {
      expect(
        reported,
        containsAll(<String>['TimeoutFailure', 'ConnectionTimeout']),
      );
    },
  );

  test('[boundary] the category matches by whole word, not by characters', () {
    expect(reported, contains('ConnectionsLostFailure'));
  });

  test('[boundary] a trailing digit makes a different kind word', () {
    expect(reported, contains('ConnectionFailure2'));
  });

  test('[boundary] a one-word base asks only for the kind', () {
    expect(reported, isNot(contains('DiskFailure')));
    expect(reported, contains('DiskFault'));
  });

  test(
    '[partition] a subtype of a class that is not sealed is not checked',
    () {
      expect(reported, isNot(contains('Unrelated')));
    },
  );

  test('[state] a sealed sub-family is checked against its own parent, and '
      'its members against it', () {
    expect(reported, isNot(contains('ReaderPageEvent')));
    expect(reported, isNot(contains('ReaderPageTurnedEvent')));
    expect(reported, contains('PageTurnedEvent'));
  });

  test('[partition] nothing else is reported', () {
    expect(reported, <String>{
      'TimeoutFailure',
      'ConnectionTimeout',
      'ConnectionsLostFailure',
      'ConnectionFailure2',
      'DiskFault',
      'PageTurnedEvent',
    });
  });
}
