import '../data/keychain_repository_impl.dart';
import 'keychain_key_entity.dart';

/// A local key store: creates, locates and deletes keys protected by the
/// platform (iOS Keychain, Android Keystore). Works offline and needs no
/// account. Nothing it stores is part of a system backup: after a restore or
/// on a new device the keys are gone, and a caller fetches or derives what it
/// needs again.
///
/// Key management only — encrypting and decrypting data is not here. Every
/// key id is the full `<feature>.<key-id>`; a malformed one throws
/// `KeychainInvalidKeyIdException` before the platform is touched. Every
/// failure is a `KeychainException` variant, and an unidentified platform
/// failure is never reported as "absent".
///
/// Never implemented outside this package. The concrete class stays internal
/// on purpose: a consumer that never has to spell its name can't couple to it
/// instead of this contract.
abstract class KeychainRepository {
  /// Builds a repository backed by the platform key store.
  ///
  /// This package takes no view on whether the result should be a singleton;
  /// every instance reaches the same platform store, so register it however
  /// the consuming app's DI does:
  ///
  /// ```dart
  /// // get_it
  /// sl.registerLazySingleton<KeychainRepository>(KeychainRepository.new);
  ///
  /// // no DI framework — build it once and pass it down
  /// final KeychainRepository keychain = KeychainRepository();
  /// ```
  factory KeychainRepository() = KeychainRepositoryImpl.create;

  /// Creates a key under a fixed, full name such as `demo.token`.
  ///
  /// A key already stored under the name is kept as it is and
  /// `KeychainKeyAlreadyExistsException` is thrown — also when a concurrent
  /// call created it. After a delete, the name is created again by the same
  /// rule.
  Future<void> create(String permanentKeyName);

  /// Creates a key under a full dynamic id such as `demo.<uuid>`.
  ///
  /// Persist [keyId] before calling: if the call is interrupted, the same id
  /// is how the caller finds out, through [exists] or [read], whether the key
  /// was made. Same rules as [create].
  Future<void> generate(String keyId);

  /// The usable key stored under [keyId]. Creates and changes nothing; a key
  /// that cannot be located or used is left as it is.
  Future<KeychainKeyEntity> read(String keyId);

  /// Whether a key is stored under [keyId]: `true` or `false` only when the
  /// platform answered conclusively, otherwise it throws. Says nothing about
  /// whether the key is usable — [read] answers that.
  Future<bool> exists(String keyId);

  /// Removes the key stored under [keyId]. A key that is already absent
  /// counts as removed.
  Future<void> delete(String keyId);

  /// Whether keys can be reached right now: `false` while the device is
  /// locked, or has not been unlocked since boot. The keys are still there.
  ///
  /// Unavailable never means absent: a caller must not delete or re-create a
  /// key because of it, only retry once keys are available again (see
  /// [availabilityChanges]).
  Future<bool> get isAvailable;

  /// The current availability when listened to. On iOS every change follows.
  /// On Android only an app that is `directBootAware` could see a change, and
  /// this version sends none: such an app asks [isAvailable] again after the
  /// first unlock. A platform without a keychain emits nothing.
  Stream<bool> get availabilityChanges;
}
