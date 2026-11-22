import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_queue/test_queue.dart';

const int _gb = 1024 * 1024 * 1024;

void main() {
  group('slotsFor', () {
    test('gives one slot per 4 GB beyond the first 8', () {
      expect(QueueSettings.slotsFor(16 * _gb), 2);
      expect(QueueSettings.slotsFor(32 * _gb), 6);
    });

    test('gives at least one slot', () {
      expect(QueueSettings.slotsFor(8 * _gb), 1);
      expect(QueueSettings.slotsFor(null), 1);
    });
  });

  test('defaults to the cache directory, the memory and 3 GB a slot', () {
    final QueueSettings settings = QueueSettings.fromEnvironment(
      const <String, String>{'HOME': '/home/u'},
      memoryBytes: 16 * _gb,
    );

    expect(
      settings.directory.path,
      p.join('/home/u', '.cache', 'test_queue', 'slots'),
    );
    expect(settings.slotCount, 2);
    expect(settings.memoryPerSlot, 3 * _gb);
  });

  test('takes XDG_CACHE_HOME over HOME', () {
    final QueueSettings settings = QueueSettings.fromEnvironment(
      const <String, String>{'HOME': '/home/u', 'XDG_CACHE_HOME': '/c'},
      memoryBytes: null,
    );

    expect(settings.directory.path, p.join('/c', 'test_queue', 'slots'));
  });

  test('takes every value the environment sets', () {
    final QueueSettings settings = QueueSettings.fromEnvironment(
      const <String, String>{
        QueueSettings.directoryVariable: '/slots',
        QueueSettings.slotsVariable: ' 5 ',
        QueueSettings.memoryVariable: '2',
      },
      memoryBytes: 16 * _gb,
    );

    expect(settings.directory.path, '/slots');
    expect(settings.slotCount, 5);
    expect(settings.memoryPerSlot, 2 * _gb);
  });

  test('rejects a value that is not a whole number, 1 or more', () {
    for (final String bad in <String>['0', '-1', 'two', '1.5']) {
      expect(
        () => QueueSettings.fromEnvironment(<String, String>{
          QueueSettings.slotsVariable: bad,
        }, memoryBytes: null),
        throwsFormatException,
        reason: bad,
      );
    }
  });
}
