import 'package:dart_mutants/src/runner/coverage_map.dart';
import 'package:test/test.dart';

/// A `dart test --coverage` suite document, shaped as the real one is: one
/// entry per loaded library, `hits` alternating line and count.
Map<String, Object?> _suite(Map<String, List<Object>> hitsBySource) =>
    <String, Object?>{
      'type': 'CodeCoverage',
      'coverage': <Object?>[
        for (final MapEntry<String, List<Object>> e in hitsBySource.entries)
          <String, Object?>{'source': e.key, 'hits': e.value},
      ],
    };

void main() {
  group('the three answers', () {
    late CoverageMap map;

    setUp(() {
      map =
          (CoverageMapBuilder('/pkg')
                ..addDartSuite(
                  'test/a_test.dart',
                  _suite(<String, List<Object>>{
                    'package:pkg/src/foo.dart': <Object>[10, 3, 11, 0, 12, 0],
                  }),
                  'pkg',
                )
                ..addDartSuite(
                  'test/b_test.dart',
                  _suite(<String, List<Object>>{
                    'package:pkg/src/foo.dart': <Object>[10, 0, 11, 2, 12, 0],
                  }),
                  'pkg',
                ))
              .build();
    });

    test('[partition] a line some suite hit is covered by exactly those', () {
      expect(map.testsFor('lib/src/foo.dart', 10, 10), <String>{
        'test/a_test.dart',
      });
      expect(map.testsFor('lib/src/foo.dart', 11, 11), <String>{
        'test/b_test.dart',
      });
    });

    test(
      '[partition] a line every suite reported at zero is uncovered — empty, '
      'not null',
      () {
        expect(map.testsFor('lib/src/foo.dart', 12, 12), isEmpty);
      },
    );

    test(
      '[boundary] a line no suite reported says nothing — null, so the caller '
      'runs everything rather than reading "no test" into a gap',
      () {
        // The VM instruments calls and entries, not statements: a line that
        // ran can be missing from a report altogether. Treating that gap as
        // uncovered would score a mutant undetected without asking a test.
        expect(map.testsFor('lib/src/foo.dart', 20, 20), isNull);
      },
    );

    test(
      '[boundary] a file no suite reported says nothing either — an abstract '
      'interface is absent from a report even when every test loads it',
      () {
        expect(map.testsFor('lib/src/bar.dart', 1, 1), isNull);
      },
    );

    test(
      '[boundary] a mutant spanning several lines is covered by every suite '
      'that hit any of them',
      () {
        expect(map.testsFor('lib/src/foo.dart', 10, 12), <String>{
          'test/a_test.dart',
          'test/b_test.dart',
        });
      },
    );

    test(
      '[boundary] lines partly unreported and partly reported at zero are '
      'uncovered — what was reported is an answer',
      () {
        expect(map.testsFor('lib/src/foo.dart', 12, 14), isEmpty);
      },
    );
  });

  group('addDartSuite', () {
    test(
      '[partition] keeps only the package under test, mapped onto lib/',
      () {
        final CoverageMap map =
            (CoverageMapBuilder('/pkg')..addDartSuite(
                  'test/a_test.dart',
                  _suite(<String, List<Object>>{
                    'package:pkg/foo.dart': <Object>[1, 1],
                    'package:other/foo.dart': <Object>[1, 1],
                    'package:pkg_extra/foo.dart': <Object>[1, 1],
                    'file:///somewhere/test/a_test.dart': <Object>[1, 1],
                  }),
                  'pkg',
                ))
                .build();

        expect(map.testsFor('lib/foo.dart', 1, 1), <String>{
          'test/a_test.dart',
        });
        expect(
          map.testsFor('lib/extra/foo.dart', 1, 1),
          isNull,
          reason: 'package:pkg_extra is not package:pkg',
        );
      },
    );

    test('[boundary] a "start-end" range entry covers every line in it', () {
      final CoverageMap map =
          (CoverageMapBuilder('/pkg')..addDartSuite(
                'test/a_test.dart',
                _suite(<String, List<Object>>{
                  'package:pkg/foo.dart': <Object>['3-5', 1],
                }),
                'pkg',
              ))
              .build();

      for (int line = 3; line <= 5; line++) {
        expect(map.testsFor('lib/foo.dart', line, line), <String>{
          'test/a_test.dart',
        });
      }
      expect(map.testsFor('lib/foo.dart', 6, 6), isNull);
    });
  });

  group('addLcov', () {
    test(
      '[partition] reads SF/DA records, zero counts included, and closes a '
      'file at end_of_record',
      () {
        const String lcov =
            'SF:lib/src/foo.dart\n'
            'DA:3,1\n'
            'DA:4,0\n'
            'LF:2\n'
            'LH:1\n'
            'end_of_record\n'
            'DA:9,1\n'
            'SF:lib/src/bar.dart\n'
            'DA:7,2,checksum\n'
            'end_of_record\n';
        final CoverageMap map = (CoverageMapBuilder(
          '/pkg',
        )..addLcov('test/a_test.dart', lcov)).build();

        expect(map.testsFor('lib/src/foo.dart', 3, 3), <String>{
          'test/a_test.dart',
        });
        expect(map.testsFor('lib/src/foo.dart', 4, 4), isEmpty);
        expect(
          map.testsFor('lib/src/foo.dart', 9, 9),
          isNull,
          reason: 'a DA line outside any SF record belongs to no file',
        );
        expect(map.testsFor('lib/src/bar.dart', 7, 7), <String>{
          'test/a_test.dart',
        });
      },
    );

    test(
      '[partition] an absolute SF path inside the root becomes a key; one '
      'outside it is dropped',
      () {
        final CoverageMap map =
            (CoverageMapBuilder('/abs/pkg')..addLcov(
                  'test/a_test.dart',
                  'SF:/abs/pkg/lib/foo.dart\nDA:1,1\nend_of_record\n'
                      'SF:/abs/other/lib/foo.dart\nDA:1,1\nend_of_record\n',
                ))
                .build();

        expect(map.testsFor('lib/foo.dart', 1, 1), <String>{
          'test/a_test.dart',
        });
        expect(map.testsFor('../other/lib/foo.dart', 1, 1), isNull);
      },
    );
  });

  test(
    '[error] a report in an unexpected shape throws rather than being read '
    'in part — a dropped hit line beside kept zero-hit ones would read as '
    'uncovered',
    () {
      expect(
        () => CoverageMapBuilder('/pkg').addLcov(
          'test/a_test.dart',
          'SF:lib/foo.dart\nDA:1,0\nDA:two,1\nend_of_record\n',
        ),
        throwsFormatException,
      );
      for (final Object? bad in <Object?>[
        <String, Object?>{'coverage': 'nope'},
        _suite(<String, List<Object>>{
          'package:pkg/foo.dart': <Object>[1],
        }),
        _suite(<String, List<Object>>{
          'package:pkg/foo.dart': <Object>[1, 'many'],
        }),
      ]) {
        expect(
          () => CoverageMapBuilder(
            '/pkg',
          ).addDartSuite('test/a_test.dart', bad, 'pkg'),
          throwsFormatException,
          reason: '$bad',
        );
      }
    },
  );

  test(
    '[partition] a file: source inside the root is kept under its relative '
    'path — a test importing ../lib/x.dart reports it that way',
    () {
      final CoverageMap map =
          (CoverageMapBuilder('/abs/pkg')..addDartSuite(
                'test/a_test.dart',
                _suite(<String, List<Object>>{
                  'file:///abs/pkg/lib/foo.dart': <Object>[4, 2],
                }),
                'pkg',
              ))
              .build();

      expect(map.testsFor('lib/foo.dart', 4, 4), <String>{'test/a_test.dart'});
    },
  );
}
