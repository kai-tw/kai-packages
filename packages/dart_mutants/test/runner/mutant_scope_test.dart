import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_mutants/src/runner/line_range.dart';
import 'package:dart_mutants/src/runner/mutant_scope.dart';
import 'package:test/test.dart';

const String _source = '''
String f(bool b) {
  final String s = b ? 'x' : g();
  return s;
}

String g() => 'y';

class C {
  C(this.a) : b = a > 0 ? 1 : 2;

  const C.fixed(this.a) : b = a > 0 ? 1 : 2;

  final int a;
  final int b;

  int twice() {
    final int Function(int) h = (int v) {
      return v * 2;
    };
    return h(a);
  }
}

final int top = 1 < 2 ? 3 : 4;
''';

/// The scope for the first occurrence of [needle] in [_source].
LineRange? _scopeOf(String needle, {int occurrence = 1}) {
  final ParseStringResult parsed = parseString(content: _source);
  int offset = -1;
  for (int i = 0; i < occurrence; i++) {
    offset = _source.indexOf(needle, offset + 1);
  }
  expect(offset, isNonNegative, reason: needle);
  return executableScope(parsed.unit, parsed.lineInfo, offset);
}

void main() {
  test(
    '[partition] a mutant inside a function body is scoped to the whole '
    'function, from the line its entry is recorded on',
    () {
      // Line 2 is the one the VM reports at zero hits when `b` is true.
      expect(_scopeOf("b ? 'x'"), const LineRange(1, 4));
    },
  );

  test('[partition] an expression-bodied function is its own one line', () {
    expect(_scopeOf("'y'"), const LineRange(6, 6));
  });

  test(
    '[partition] a constructor initializer is scoped to the constructor',
    () {
      expect(_scopeOf('a > 0'), const LineRange(9, 9));
    },
  );

  test(
    '[boundary] a const constructor has no scope — its initializers run at '
    'compile time, where coverage sees nothing',
    () {
      expect(_scopeOf('a > 0', occurrence: 2), isNull);
    },
  );

  test(
    '[partition] a mutant in a closure is scoped to the closure, not the '
    'method around it',
    () {
      expect(_scopeOf('v * 2'), const LineRange(17, 19));
    },
  );

  test(
    '[boundary] a top-level initializer has no scope — nothing coverage can '
    'speak for, so the caller runs everything',
    () {
      expect(_scopeOf('1 < 2'), isNull);
    },
  );

  group('the range reaches back to where the VM records the entry', () {
    // Every case above has its name and its body on one line, so none of
    // them could tell a scope that starts at the body from one that starts
    // at the declaration. The VM records a function's entry at its name.
    const String split = '''
/// Documented.
String documented(
  bool b,
) {
  return b ? 'x' : 'y';
}

class K {
  /// A method.
  int
      method(bool b) {
    return b ? 1 : 2;
  }

  K.named(bool b)
      : v = 0 {
    print(b ? 1 : 2);
  }

  final int v;

  final int Function(bool) field = (bool b) {
    return b ? 1 : 2;
  };
}

void outer() {
  int local(bool b) {
    return b ? 1 : 2;
  }
  local(true);
}
''';

    LineRange? scopeIn(String needle, {int occurrence = 1}) {
      final ParseStringResult parsed = parseString(content: split);
      int offset = -1;
      for (int i = 0; i < occurrence; i++) {
        offset = split.indexOf(needle, offset + 1);
      }
      return executableScope(parsed.unit, parsed.lineInfo, offset);
    }

    test('[boundary] a function: from its doc comment, not its body', () {
      expect(scopeIn("b ? 'x'"), const LineRange(1, 6));
    });

    test('[boundary] a method split over lines: from its doc comment', () {
      expect(scopeIn('b ? 1 : 2'), const LineRange(9, 13));
    });

    test('[partition] a constructor body: the whole constructor', () {
      expect(scopeIn('b ? 1 : 2', occurrence: 2), const LineRange(15, 18));
    });

    test(
      '[partition] a closure in a field initializer: the closure — it is a '
      'function, and runs only when called',
      () {
        expect(scopeIn('b ? 1 : 2', occurrence: 3), const LineRange(22, 24));
      },
    );

    test('[partition] a local function: the local function', () {
      expect(scopeIn('b ? 1 : 2', occurrence: 4), const LineRange(28, 30));
    });
  });
}
