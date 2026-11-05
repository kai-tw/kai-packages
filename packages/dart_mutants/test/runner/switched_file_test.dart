import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:dart_mutants/src/mutant.dart';
import 'package:dart_mutants/src/runner/switched_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A mutant replacing the [occurrence]th [original] in [source].
Mutant _mutant(
  String source,
  String original,
  String replacement, {
  int occurrence = 1,
}) {
  int offset = -1;
  for (int i = 0; i < occurrence; i++) {
    offset = source.indexOf(original, offset + 1);
  }
  expect(offset, isNonNegative, reason: original);
  return Mutant(
    filePath: 'a.dart',
    offset: offset,
    length: original.length,
    line: 1,
    column: 1,
    original: original,
    replacement: replacement,
    operatorName: 'test',
    description: '',
  );
}

void _expectParses(String source) {
  expect(
    parseString(content: source, throwIfDiagnostics: false).errors,
    isEmpty,
    reason: source,
  );
}

const String _program = '''
import 'dart:core';

int pick(int a, int b) {
  if (a > b) {
    return a;
  }
  log(a);
  return b;
}

void log(int a) => calls++;

int calls = 0;

void main() {
  print('\${pick(2, 1)} \${pick(1, 2)} \$calls');
}
''';

void main() {
  test('[partition] an expression mutant becomes a conditional on its id', () {
    final SwitchedFile file = switchMutants(_program, <int, Mutant>{
      3: _mutant(_program, '>', '>='),
    });
    expect(file.switched, <int>{3});
    expect(file.source, contains('(_dmOn(3) ? (a >= b) : (a > b))'));
    expect(file.source, contains(mutantIdVariable));
    _expectParses(file.source);
  });

  test('[partition] a statement mutant becomes an if on its id', () {
    final SwitchedFile file = switchMutants(_program, <int, Mutant>{
      7: _mutant(_program, 'log(a);', ';'),
    });
    expect(file.source, contains('if (_dmOn(7)) { ; } else { log(a); }'));
    _expectParses(file.source);
  });

  test(
    '[partition] mutants at one node chain, and one inside another is '
    'switched inside its unmodified branch',
    () {
      final SwitchedFile file = switchMutants(_program, <int, Mutant>{
        1: _mutant(_program, '>', '<'),
        2: _mutant(_program, '>', '>='),
        3: _mutant(_program, 'a > b', 'true'),
        4: _mutant(_program, 'log(a);', ';'),
        5: _mutant(_program, 'log(a)', 'log(b)'),
      });
      expect(file.switched, <int>{1, 2, 3, 4, 5});
      expect(
        file.source,
        contains(
          '(_dmOn(1) ? (a < b) : _dmOn(2) ? (a >= b) : _dmOn(3) ? (true) : '
          '(a > b))',
        ),
      );
      expect(
        file.source,
        contains(
          'if (_dmOn(4)) { ; } else { '
          '(_dmOn(5) ? (log(b)) : (log(a))); }',
        ),
      );
      _expectParses(file.source);
    },
  );

  test(
    '[partition] an expression is switched whole, so a null check it '
    'promotes stays in one piece',
    () {
      const String source = '''
bool f(String? s) => s != null && s.isEmpty;
''';
      final SwitchedFile file = switchMutants(source, <int, Mutant>{
        0: _mutant(source, '!=', '=='),
      });
      expect(
        file.source,
        contains(
          '(_dmOn(0) ? (s == null && s.isEmpty) : (s != null && s.isEmpty))',
        ),
      );
    },
  );

  test('[partition] what cannot read the environment is left out, with '
      'why', () {
    const String source = '''
const int k = 1 + 2;

class C {
  const C([this.x = 3 - 1]);
  final int x;
}

void f() {
  final int y = 4;
  print(y);
}
''';
    final SwitchedFile file = switchMutants(source, <int, Mutant>{
      0: _mutant(source, '+', '-'),
      1: _mutant(source, '-', '+'),
      2: _mutant(source, 'final int y = 4;', ';'),
    });
    expect(file.switched, isEmpty);
    expect(file.skipped, <int, String>{
      0: 'constant context',
      1: 'constant context',
      2: 'local declaration',
    });
    expect(file.source, source);
  });

  test('[partition] a part file is left out whole', () {
    const String source = '''
part of 'lib.dart';

int f(int a) => a + 1;
''';
    final SwitchedFile file = switchMutants(source, <int, Mutant>{
      0: _mutant(source, '+', '-'),
    });
    expect(file.switched, isEmpty);
    expect(file.skipped, <int, String>{0: 'part file'});
  });

  test(
    '[happy] the switched program runs unmodified with no id, and as each '
    'mutant with its id',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync('schemata');
      addTearDown(() => dir.deleteSync(recursive: true));
      final SwitchedFile file = switchMutants(_program, <int, Mutant>{
        0: _mutant(_program, '>', '<'),
        1: _mutant(_program, 'log(a);', ';'),
      });
      final String path = p.join(dir.path, 'main.dart');
      File(path).writeAsStringSync(file.source);
      Future<String> run(String id) async {
        final ProcessResult r = await Process.run(
          Platform.resolvedExecutable,
          <String>['run', path],
          environment: <String, String>{mutantIdVariable: id},
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return (r.stdout as String).trim();
      }

      expect(await run(''), '2 2 1');
      expect(await run('0'), '1 1 1');
      expect(await run('1'), '2 2 0');
    },
  );
}
