/// Why a run is stopped before it starts: this engine is older than the
/// newest release, or the newest release could not be found out.
class OutdatedEngineException implements Exception {
  const OutdatedEngineException(this.message);

  final String message;

  @override
  String toString() => message;
}
