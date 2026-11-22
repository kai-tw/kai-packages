import 'package:connectivity_status/src/data/connectivity_metered_data_source.dart';

/// Hand-written fake for [ConnectivityMeteredDataSource].
///
/// A single-method interface with no stream or listenable surface — a
/// programmable fake is the simplest correct seam. Returns the configured
/// [response] or throws [throwWith] on each call. [callCount] lets tests
/// verify the offline short-circuit: the metered channel must NOT be probed
/// when the connection-type list contains only `ConnectivityResult.none`.
class FakeConnectivityMeteredDataSource
    implements ConnectivityMeteredDataSource {
  bool? response;
  Object? throwWith;
  int callCount = 0;

  @override
  Future<bool?> get isActiveNetworkMetered async {
    callCount++;
    final Object? err = throwWith;
    if (err != null) {
      throw err;
    }
    return response;
  }
}
