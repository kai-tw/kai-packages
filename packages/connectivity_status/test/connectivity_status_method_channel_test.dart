import 'package:connectivity_status/connectivity_status_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MethodChannelConnectivityStatus platform =
      MethodChannelConnectivityStatus();
  const MethodChannel channel = MethodChannel(
    MethodChannelConnectivityStatus.channelName,
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          expect(methodCall.method, 'isActiveNetworkMetered');
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('isActiveNetworkMetered forwards to the platform channel', () async {
    expect(await platform.isActiveNetworkMetered, isTrue);
  });

  test('channel name is package-owned and neutral', () {
    expect(
      MethodChannelConnectivityStatus.channelName,
      'net.kaiwu.connectivity_status/metered',
    );
  });
}
