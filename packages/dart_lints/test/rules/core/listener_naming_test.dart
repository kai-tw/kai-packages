import 'package:dart_lints/src/lint_rule_base.dart';
import 'package:dart_lints/src/rules/core/listener_naming.dart';
import 'package:test/test.dart';

import '../naming_fixture.dart';

/// A stand-in for Flutter's `Listenable`, so the fixture needs nothing
/// outside the SDK.
const String _listenable = '''
import 'dart:async';

class Notifier {
  void addListener(void Function() listener) {}
  void removeListener(void Function() listener) {}
  void addStatusListener(void Function(int) listener) {}
}
''';

void main() {
  late NamingFixture fixture;

  setUp(() => fixture = NamingFixture());

  /// The text of each argument reported in [members], which sit inside a
  /// class `C` that has a `Notifier n` and a `Stream<int> s`.
  Future<List<String>> reported(String members, {String? prefix}) async {
    final String source =
        '$_listenable\n'
        'class C {\n'
        '  final Notifier n = Notifier();\n'
        '  final Stream<int> s = const Stream<int>.empty();\n'
        '$members\n'
        '}\n';
    final List<LintViolation> violations = await fixture.resolved(
      ListenerNaming(prefix: prefix),
      source,
    );
    return <String>[
      for (final LintViolation v in violations)
        RegExp(r'[A-Za-z_]\w*').firstMatch(
          source.split('\n')[v.line - 1].substring(v.column - 1),
        )![0]!,
    ];
  }

  test(
    '[partition] a method passed to addListener must start with on',
    () async {
      expect(
        await reported('''
  void start() {
    n.addListener(_handleChange);
    n.addListener(_onChange);
  }
  void _handleChange() {}
  void _onChange() {}
'''),
        <String>['_handleChange'],
      );
    },
  );

  test('[partition] any add…Listener and remove…Listener counts', () async {
    expect(
      await reported('''
  void start() {
    n.removeListener(_changed);
    n.addStatusListener(_status);
  }
  void _changed() {}
  void _status(int s) {}
'''),
      <String>['_changed', '_status'],
    );
  });

  test(
    '[partition] Stream.listen checks onData, onError and onDone, and not '
    'cancelOnError',
    () async {
      expect(
        await reported('''
  void start() {
    s.listen(_data, onError: _failed, onDone: _done, cancelOnError: true);
    s.listen(_onData, onError: _onError, onDone: _onDone);
  }
  void _data(int v) {}
  void _failed(Object e) {}
  void _done() {}
  void _onData(int v) {}
  void _onError(Object e) {}
  void _onDone() {}
'''),
        <String>['_data', '_failed', '_done'],
      );
    },
  );

  test('[partition] top-level and local functions are checked too', () async {
    expect(
      await reported(
        '''
  void start() {
    void tick() {}
    n.addListener(tick);
    n.addListener(refresh);
  }
'''
        '}\n'
        'void refresh() {}\n'
        'class D {',
      ),
      <String>['tick', 'refresh'],
    );
  });

  test(
    '[decision] closures, parameters and fields are left alone: they have no '
    'declared listener name to fix',
    () async {
      expect(
        await reported('''
  final void Function() callback = () {};
  void start(void Function() given) {
    n.addListener(() {});
    n.addListener(given);
    n.addListener(callback);
  }
'''),
        isEmpty,
      );
    },
  );

  test(
    '[decision] listen on something that is not a Stream is left alone',
    () async {
      expect(
        await reported(
          '''
  void start(Radio r) {
    r.listen(_tune);
  }
  void _tune() {}
'''
          '}\n'
          'class Radio {\n'
          '  void listen(void Function() f) {}\n'
          '}\n'
          'class D {',
        ),
        isEmpty,
      );
    },
  );

  test(
    '[error-guessing] the prefix needs a capital after it: `once` and a bare '
    '`on` are not listener names',
    () async {
      expect(
        await reported('''
  void start() {
    n.addListener(once);
    n.addListener(on);
  }
  void once() {}
  void on() {}
'''),
        <String>['once', 'on'],
      );
    },
  );

  test('[decision] `prefix` replaces `on`', () async {
    expect(
      await reported('''
  void start() {
    n.addListener(_handleChange);
    n.addListener(_onChange);
  }
  void _handleChange() {}
  void _onChange() {}
''', prefix: 'handle'),
      <String>['_onChange'],
    );
  });

  test('[partition] the message suggests a name with the prefix', () async {
    final List<LintViolation> violations = await fixture.resolved(
      ListenerNaming(),
      '$_listenable\n'
      'class C {\n'
      '  final Notifier n = Notifier();\n'
      '  void start() => n.addListener(_changed);\n'
      '  void _changed() {}\n'
      '}\n',
    );

    expect(violations.single.message, contains("'_onChanged'"));
  });

  test(
    "[decision] someone else's method, passed on to forward events, is left "
    'alone; `this.name` is checked',
    () async {
      expect(
        await reported('''
  final StreamController<int> out = StreamController<int>();
  final List<int> seen = <int>[];
  void start() {
    s.listen(out.add, onError: out.addError, onDone: out.close);
    s.listen(seen.add);
    n.addListener(this._changed);
  }
  void _changed() {}
'''),
        <String>['this'],
      );
    },
  );

  test(
    '[partition] a leading `handle` is replaced in the suggestion',
    () async {
      final List<LintViolation> violations = await fixture.resolved(
        ListenerNaming(),
        '$_listenable\n'
        'class C {\n'
        '  final Notifier n = Notifier();\n'
        '  void start() => n.addListener(_handleScroll);\n'
        '  void _handleScroll() {}\n'
        '}\n',
      );

      expect(violations.single.message, contains("'_onScroll'"));
    },
  );
}
