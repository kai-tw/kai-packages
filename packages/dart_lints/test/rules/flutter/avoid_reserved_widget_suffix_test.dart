import 'package:dart_lints/src/rules/flutter/avoid_reserved_widget_suffix.dart';
import 'package:test/test.dart';

import '../naming_fixture.dart';

/// Stand-ins for Flutter's bases; the rule matches them by name.
const String _source = r'''
abstract class Widget {}
abstract class StatelessWidget extends Widget {}
abstract class StatefulWidget extends Widget {}
abstract class State<T extends StatefulWidget> {}

class ReaderState extends StatelessWidget {}
class ReaderCubit extends StatelessWidget {}
class ReaderBloc extends StatelessWidget {}
class ReaderNotifier extends StatefulWidget {}
class ThemeProvider extends StatelessWidget {}
class OptionsSheet extends StatelessWidget {}

class ReaderView extends StatelessWidget {}
class ReaderWidget extends StatelessWidget {}
class OptionsBottomSheet extends StatelessWidget {}
class Reader extends StatefulWidget {}
class _ReaderState extends State<Reader> {}
class _HelperCubit extends StatelessWidget {}
class SessionState {}
''';

Future<Set<String>> _reported(AvoidReservedWidgetSuffix rule) async =>
    reportedNames(await NamingFixture().resolved(rule, _source), _source);

void main() {
  test('[partition] every default reserved suffix on a public widget is '
      'reported', () async {
    expect(await _reported(AvoidReservedWidgetSuffix()), <String>{
      'ReaderState',
      'ReaderCubit',
      'ReaderBloc',
      'ReaderNotifier',
      'ThemeProvider',
      'OptionsSheet',
    });
  });

  test('[boundary] a bare Widget suffix, BottomSheet, the State of a '
      'StatefulWidget, a private widget and a non-widget pass', () async {
    expect(
      await _reported(AvoidReservedWidgetSuffix()),
      isNot(
        anyOf(
          contains('ReaderWidget'),
          contains('OptionsBottomSheet'),
          contains('_ReaderState'),
          contains('_HelperCubit'),
          contains('SessionState'),
        ),
      ),
    );
  });

  test('[decision] a project that reserves Widget lists it', () async {
    expect(
      await _reported(
        AvoidReservedWidgetSuffix(
          reservedSuffixes: <Map<String, Object?>>[
            <String, Object?>{'suffix': 'Widget', 'hint': 'name the kind'},
          ],
        ),
      ),
      <String>{'ReaderWidget'},
    );
  });
}
