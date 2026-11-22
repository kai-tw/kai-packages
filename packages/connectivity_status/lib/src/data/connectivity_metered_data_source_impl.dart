import 'package:flutter/services.dart';

import '../../connectivity_status_platform_interface.dart';
import 'connectivity_metered_data_source.dart';

/// Delegates to [ConnectivityStatusPlatform.instance] — the federated
/// plugin's own platform contract — rather than owning a [MethodChannel]
/// directly, so a future platform implementation registers itself here
/// with no change to this class.
class ConnectivityMeteredDataSourceImpl
    implements ConnectivityMeteredDataSource {
  static const Duration _timeout = Duration(seconds: 5);

  @override
  Future<bool?> get isActiveNetworkMetered async {
    try {
      return await ConnectivityStatusPlatform.instance.isActiveNetworkMetered
          .timeout(_timeout);
    } on MissingPluginException {
      // Platform-absence gate: desktop / web register no native handler, so a
      // missing plugin is the documented "no metered signal on this platform"
      // answer — the repository falls back to its type-list heuristic, not a
      // swallowed failure. Real mobile faults (PlatformException /
      // TimeoutException) are left to propagate to the repository.
      return null;
    }
  }
}
