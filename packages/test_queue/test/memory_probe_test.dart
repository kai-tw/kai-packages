import 'dart:io';

import 'package:test/test.dart';
import 'package:test_queue/test_queue.dart';

const String _vmStat = '''
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                    41601.
Pages active:                                 371437.
Pages inactive:                               341178.
Pages speculative:                             29198.
Pages throttled:                                   0.
Pages wired down:                             159314.
Pages purgeable:                                2169.
''';

const String _meminfo = '''
MemTotal:       16384000 kB
MemFree:         1000000 kB
MemAvailable:    6000000 kB
''';

void main() {
  test('parseVmStat adds free, inactive, speculative and purgeable', () {
    expect(
      MemoryProbe.parseVmStat(_vmStat),
      (41601 + 341178 + 29198 + 2169) * 16384,
    );
  });

  test('parseVmStat is null when a field is missing', () {
    expect(
      MemoryProbe.parseVmStat(_vmStat.replaceAll('Pages inactive', 'X')),
      isNull,
    );
    expect(MemoryProbe.parseVmStat('Pages free: 4.'), isNull);
  });

  test('parseMeminfo reads one field in bytes', () {
    expect(MemoryProbe.parseMeminfo(_meminfo, 'MemAvailable'), 6000000 * 1024);
    expect(MemoryProbe.parseMeminfo(_meminfo, 'SwapTotal'), isNull);
  });

  test('availableBytes reads what this platform offers', () async {
    final MemoryProbe probe = MemoryProbe(
      run: (String executable, List<String> arguments) async =>
          executable == 'vm_stat' ? _vmStat : null,
      readMeminfo: () async => _meminfo,
    );

    final int? available = await probe.availableBytes();

    if (Platform.isMacOS) {
      expect(available, MemoryProbe.parseVmStat(_vmStat));
    } else if (Platform.isLinux) {
      expect(available, 6000000 * 1024);
    }
  });

  test('totalBytes reads this machine', () async {
    expect(await MemoryProbe().totalBytes(), greaterThan(0));
  });
}
