import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'connectivity_status_method_channel.dart';

/// The platform contract for the OS metered-network capability.
///
/// A platform with no native implementation registered — desktop, web —
/// leaves the default [MethodChannelConnectivityStatus] in place, which
/// reports "no signal" as a [MissingPluginException] rather than a wrong
/// answer. See [ConnectivityMeteredDataSource] in the main library for the
/// seam most callers should use instead of this platform interface directly.
abstract class ConnectivityStatusPlatform extends PlatformInterface {
  ConnectivityStatusPlatform() : super(token: _token);

  static final Object _token = Object();

  static ConnectivityStatusPlatform _instance =
      MethodChannelConnectivityStatus();

  /// The default instance of [ConnectivityStatusPlatform] to use.
  ///
  /// Defaults to [MethodChannelConnectivityStatus].
  static ConnectivityStatusPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ConnectivityStatusPlatform] when
  /// they register themselves.
  static set instance(ConnectivityStatusPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Reads the active network's OS-level metered capability.
  ///
  /// Returns `true` when the active link is metered, `false` when it is
  /// unmetered, and `null` when the running platform exposes no metered
  /// signal at all.
  Future<bool?> get isActiveNetworkMetered {
    throw UnimplementedError(
      'isActiveNetworkMetered has not been implemented.',
    );
  }
}
