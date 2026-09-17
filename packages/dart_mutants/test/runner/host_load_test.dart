import 'dart:io';

import 'package:dart_mutants/src/runner/host_load.dart';
import 'package:test/test.dart';

void main() {
  test('[partition] reads the three averages from /proc/loadavg', () {
    expect(HostLoad.parse('0.52 0.58 0.59 1/467 12345\n')!.averages, <double>[
      0.52,
      0.58,
      0.59,
    ]);
  });

  test('[partition] reads the three averages from sysctl vm.loadavg', () {
    expect(HostLoad.parse('{ 1.23 1.45 12 }\n')!.averages, <double>[
      1.23,
      1.45,
      12,
    ]);
  });

  test('[boundary] fewer than three numbers is no reading', () {
    expect(HostLoad.parse('{ 1.23 1.45 }'), isNull);
    expect(HostLoad.parse(''), isNull);
  });

  test(
    '[state] reads this machine on Linux and macOS, and nothing elsewhere',
    () async {
      final HostLoad? load = await HostLoad.read();
      if (Platform.isLinux || Platform.isMacOS) {
        expect(load!.averages, hasLength(3));
      } else {
        expect(load, isNull);
      }
    },
  );
}
