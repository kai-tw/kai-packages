import 'package:dart_lints/src/rules/core/avoid_vague_type_words.dart';
import 'package:test/test.dart';

import '../naming_fixture.dart';

const String _source = r'''
class SessionManager {}
mixin CacheHelper {}
enum DateUtil { a }
extension StringUtils on String {}
extension on int {}
typedef ParseHelperCallback = void Function();
extension type ManagerId(int value) {}
class HelperText {}

class SessionRepository {}
class Helpers {}
class Utility {}
class Management {}
''';

const String _services = r'''
abstract class BackgroundService {}

class SyncService extends BackgroundService {}
class DownloadService implements BackgroundService {}
class LoginService {}
mixin ServiceLocatorMixin {}
class ServiceRequestData {}
''';

Future<Set<String>> _reported(AvoidVagueTypeWords rule, String source) async =>
    reportedNames(await NamingFixture().resolved(rule, source), source);

void main() {
  test('[partition] a listed word anywhere in any kind of type name is '
      'reported; unlisted and partial words are not', () async {
    expect(await _reported(AvoidVagueTypeWords(), _source), <String>{
      'SessionManager',
      'CacheHelper',
      'DateUtil',
      'StringUtils',
      'ParseHelperCallback',
      'ManagerId',
      'HelperText',
    });
  });

  test('[decision] a configured list replaces the default', () async {
    expect(
      await _reported(
        AvoidVagueTypeWords(forbiddenWords: <String>['Repository']),
        _source,
      ),
      <String>{'SessionRepository'},
    );
  });

  test('[boundary] a name with two listed words is reported once', () async {
    const String source = 'class ManagerHelper {}\n';
    expect(
      await NamingFixture().resolved(AvoidVagueTypeWords(), source),
      hasLength(1),
    );
  });

  test('[decision] a scoped word is allowed on a subtype of a listed type, '
      'extended or implemented, and forbidden everywhere else', () async {
    final AvoidVagueTypeWords rule = AvoidVagueTypeWords(
      forbiddenWords: const <String>[],
      scopedWords: <Map<String, Object?>>[
        <String, Object?>{
          'word': 'Service',
          'unlessExtends': <Object?>['BackgroundService'],
        },
      ],
    );
    expect(await _reported(rule, _services), <String>{
      'LoginService',
      'ServiceLocatorMixin',
      'ServiceRequestData',
    });
  });

  test('[partition] a scoped word with no exceptions is forbidden like any '
      'other', () async {
    final AvoidVagueTypeWords rule = AvoidVagueTypeWords(
      forbiddenWords: const <String>[],
      scopedWords: <Map<String, Object?>>[
        <String, Object?>{'word': 'Data'},
      ],
    );
    expect(await _reported(rule, _services), <String>{'ServiceRequestData'});
  });
}
