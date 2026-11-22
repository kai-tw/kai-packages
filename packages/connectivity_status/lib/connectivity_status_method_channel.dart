import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'connectivity_status_platform_interface.dart';

/// The default [ConnectivityStatusPlatform]: reads the metered capability
/// over a [MethodChannel]. iOS and Android register a native handler for
/// [channelName]; every other platform leaves it unregistered, so a call
/// here throws [MissingPluginException] — the documented "no metered
/// signal on this platform" case a caller absorbs, not a real failure.
class MethodChannelConnectivityStatus extends ConnectivityStatusPlatform {
  /// Package-owned and neutral on purpose: a shared package's channel name
  /// must not carry one consuming app's identity.
  static const String channelName = 'net.kaiwu.connectivity_status/metered';

  @visibleForTesting
  final MethodChannel methodChannel = const MethodChannel(channelName);

  @override
  Future<bool?> get isActiveNetworkMetered =>
      methodChannel.invokeMethod<bool>('isActiveNetworkMetered');
}
