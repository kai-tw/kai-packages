import 'dart:typed_data';

/// The native key store behind the keychain, reached over platform channels.
///
/// Every id arrives already validated. Every failure is thrown as a
/// `KeychainException` variant; no channel or plugin type leaves this seam.
abstract class KeychainDataSource {
  /// Creates a key under [keyId] only if none is stored there. The native side
  /// makes the check and the create one atomic step, so a concurrent create
  /// can never overwrite the key.
  Future<void> create(String keyId);

  /// The usable key material stored under [keyId].
  Future<Uint8List> read(String keyId);

  Future<bool> exists(String keyId);

  Future<void> delete(String keyId);

  Future<bool> isAvailable();

  Stream<bool> get availabilityChanges;
}
