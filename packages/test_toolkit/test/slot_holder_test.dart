import 'package:test/test.dart';
import 'package:test_toolkit/test_toolkit.dart';

void main() {
  final SlotHolder holder = SlotHolder(
    pid: 42,
    label: 'app',
    workingDirectory: '/work/app',
    command: 'flutter test test/a_test.dart',
    startedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
  );

  test('decode reads back what encode wrote', () {
    final SlotHolder read = SlotHolder.decode(holder.encode());

    expect(read.pid, 42);
    expect(read.label, 'app');
    expect(read.workingDirectory, '/work/app');
    expect(read.command, 'flutter test test/a_test.dart');
    expect(read.startedAt, holder.startedAt);
  });

  test('decode gives the unknown holder for anything else', () {
    for (final String text in <String>['', '{', '[]', '{"pid": "x"}']) {
      expect(SlotHolder.decode(text), same(SlotHolder.unknown), reason: text);
    }
  });

  test('describe says who, for how long, and what', () {
    expect(
      holder.describe(holder.startedAt.add(const Duration(seconds: 125))),
      'app  pid 42  2m05s  flutter test test/a_test.dart',
    );
    expect(
      SlotHolder.unknown.describe(DateTime.now()),
      '(holder not readable)',
    );
  });
}
