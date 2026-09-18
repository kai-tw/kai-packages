import 'package:dart_lints/src/lint_rule_base.dart';
import 'package:dart_lints/src/rules/state_holder/state_holder_naming.dart';
import 'package:dart_lints/src/rules/state_holder/state_holder_role.dart';
import 'package:test/test.dart';

import '../naming_fixture.dart';

/// Stand-ins for the frameworks' bases; the rule matches them by name.
const String _bloc = r'''
class Cubit<S> { Cubit(this.state); S state; }
class Bloc<E, S> { Bloc(this.state); S state; }
class HydratedCubit<S> extends Cubit<S> { HydratedCubit(super.state); }

class ReaderSettingsState {}
class LibraryState {}
class ShelfData {}
class SearchEvent {}
class SearchState {}

class ReaderSettingsCubit extends Cubit<ReaderSettingsState> {
  ReaderSettingsCubit() : super(ReaderSettingsState());
}
class ReaderSettings extends Cubit<ReaderSettingsState> {
  ReaderSettings() : super(ReaderSettingsState());
}
class LibraryCubit extends HydratedCubit<ShelfData> {
  LibraryCubit() : super(ShelfData());
}
class Counter extends Cubit<int> {
  Counter() : super(0);
}
class CounterCubit extends Cubit<int> {
  CounterCubit() : super(0);
}
class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc() : super(SearchState());
}
class SearchCubit extends Bloc<SearchEvent, SearchState> {
  SearchCubit() : super(SearchState());
}
class PretendCubit {}
class GenericCubit<T> extends Cubit<T> {
  GenericCubit(super.state);
}
class MockLibraryCubit implements LibraryCubit {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
''';

const String _riverpod = r'''
class Notifier<S> {}
class AsyncNotifier<S> {}
class $Notifier<S> {}

class TodosNotifier extends Notifier<List<String>> {}
class Todos extends Notifier<List<String>> {}
class ProfileAsyncNotifier extends AsyncNotifier<int> {}
class ProfileNotifier extends AsyncNotifier<int> {}
class Generated extends $Notifier<int> {}
''';

StateHolderNaming _blocRule() => StateHolderNaming(
  name: 'require_cubit_suffix',
  roles: const <StateHolderRole>[
    StateHolderRole(base: 'Cubit', suffix: 'Cubit', stateTypeArgument: 0),
    StateHolderRole(base: 'Bloc', suffix: 'Bloc', stateTypeArgument: 1),
  ],
);

void main() {
  group('bloc roles', () {
    late List<LintViolation> violations;
    late Set<String> reported;

    setUpAll(() async {
      violations = await NamingFixture().resolved(_blocRule(), _bloc);
      reported = reportedNames(violations, _bloc);
    });

    test('[partition] a Cubit without the suffix is reported', () {
      expect(reported, containsAll(<String>['ReaderSettings', 'Counter']));
    });

    test('[partition] a class claiming a suffix its type does not have is '
        'reported, whether it is nothing or the other role', () {
      expect(reported, containsAll(<String>['PretendCubit', 'SearchCubit']));
    });

    test('[decision] the state is named for the holder, found through a '
        'subclass of the base', () {
      expect(reported, contains('LibraryCubit'));
      expect(
        violations
            .singleWhere((LintViolation v) => v.message.startsWith('Library'))
            .message,
        contains('LibraryState'),
      );
    });

    test('[boundary] an SDK state type, a type parameter, and a double that '
        'only implements the holder are not held to the state name', () {
      expect(
        reported,
        isNot(
          anyOf(
            contains('CounterCubit'),
            contains('GenericCubit'),
            contains('MockLibraryCubit'),
          ),
        ),
      );
    });

    test('[partition] nothing else is reported', () {
      expect(reported, <String>{
        'ReaderSettings',
        'Counter',
        'PretendCubit',
        'SearchCubit',
        'LibraryCubit',
      });
      expect(
        violations.every(
          (LintViolation v) => v.ruleName == 'require_cubit_suffix',
        ),
        isTrue,
      );
    });
  });

  test('[decision] riverpod roles: the longest suffix a name ends in decides, '
      'and a generated base is not a holder', () async {
    final StateHolderNaming rule = StateHolderNaming(
      name: 'require_notifier_suffix',
      roles: const <StateHolderRole>[
        StateHolderRole(base: 'Notifier', suffix: 'Notifier'),
        StateHolderRole(base: 'AsyncNotifier', suffix: 'AsyncNotifier'),
      ],
    );
    expect(
      reportedNames(await NamingFixture().resolved(rule, _riverpod), _riverpod),
      <String>{'Todos', 'ProfileNotifier'},
    );
  });

  test('[partition] a configured state suffix replaces State', () async {
    const String source = r'''
class Cubit<S> { Cubit(this.state); S state; }
class ReaderModel {}
class ReaderCubit extends Cubit<ReaderModel> {
  ReaderCubit() : super(ReaderModel());
}
''';
    final StateHolderNaming rule = StateHolderNaming(
      name: 'require_cubit_suffix',
      roles: const <StateHolderRole>[
        StateHolderRole(base: 'Cubit', suffix: 'Cubit', stateTypeArgument: 0),
      ],
      stateSuffix: 'Model',
    );
    expect(await NamingFixture().resolved(rule, source), isEmpty);
  });

  group('a state the holder did not name is not asked for', () {
    const String source = r'''
class Cubit<S> { Cubit(this.state); S state; }

class SharedListState<T> {}
class SharedListCubit<T, S extends SharedListState<T>> extends Cubit<S> {
  SharedListCubit(super.state);
}
class Entry {}
typedef EntryState = SharedListState<Entry>;
class EntryCubit extends SharedListCubit<Entry, EntryState> {
  EntryCubit() : super(EntryState());
}
typedef WrongState = SharedListState<Entry>;
class OtherCubit extends SharedListCubit<Entry, WrongState> {
  OtherCubit() : super(WrongState());
}

class StockState {}
class StockCubit extends Cubit<StockState> {
  StockCubit() : super(StockState());
}
class StubStockCubit extends Cubit<StockState> implements StockCubit {
  StubStockCubit() : super(StockState());
}
class _FakeStockCubit extends Cubit<StockState> implements StockCubit {
  _FakeStockCubit() : super(StockState());
}
class RetryingStockCubit extends StockCubit {}

class LooseCubit extends Cubit<StockState> implements Comparable<Object> {
  LooseCubit() : super(StockState());
  @override
  int compareTo(Object other) => 0;
}
''';

    late Set<String> reported;

    setUpAll(() async {
      reported = reportedNames(
        await NamingFixture().resolved(_blocRule(), source),
        source,
      );
    });

    test('[decision] a state written as a typedef counts as the name it is '
        'written under, and the alias still has to be the right one', () {
      expect(reported, isNot(contains('EntryCubit')));
      expect(reported, contains('OtherCubit'));
    });

    test('[partition] a test double — extends the base, implements the real '
        'holder — is not asked to rename a state it borrowed, public or '
        'private', () {
      expect(
        reported,
        isNot(anyOf(contains('StubStockCubit'), contains('_FakeStockCubit'))),
      );
    });

    test('[boundary] a subclass of a concrete holder writes no type argument, '
        'so it is not asked for one', () {
      expect(reported, isNot(contains('RetryingStockCubit')));
    });

    test('[boundary] implementing something unrelated is not a double — the '
        'holder still answers for its own state name', () {
      expect(reported, contains('LooseCubit'));
    });
  });

  test('[partition] a role read from configuration', () {
    final StateHolderRole role = StateHolderRole.fromMap(<String, Object?>{
      'base': 'Bloc',
      'suffix': 'Bloc',
      'stateTypeArgument': 1,
    });
    expect(
      <Object?>[role.base, role.suffix, role.stateTypeArgument],
      <Object?>['Bloc', 'Bloc', 1],
    );
  });
}
