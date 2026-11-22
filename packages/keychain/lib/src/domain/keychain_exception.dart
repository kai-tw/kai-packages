/// Why a keychain operation did not complete.
///
/// Sealed so a caller that turns the cause into a retry, a re-create or copy
/// switches over the whole family and is told when a cause is added. The
/// messages are fixed text and never carry the key id: an id can be a stable
/// record id, and these exceptions can reach a consumer's logs and error
/// reports.
///
/// This package logs nothing itself; a consumer that wants a record of a
/// failure logs it where it catches one.
sealed class KeychainException implements Exception {
  const KeychainException(this.message, {this.diagnosticCode});

  final String message;

  /// The platform's numeric status behind the failure (an iOS `OSStatus` or
  /// an Android Keystore error code), when it sent one. A closed numeric
  /// vocabulary, so it is safe to log.
  final int? diagnosticCode;

  @override
  String toString() => '$runtimeType: $message';
}

/// The key id is not `<feature>.<key-id>`. Raised before the platform store
/// is touched, so it says nothing about whether such a key exists.
class KeychainInvalidKeyIdException extends KeychainException {
  const KeychainInvalidKeyIdException()
    : super('The keychain key id is not a valid <feature>.<key-id>');
}

/// A create met a key already stored under the same id. The stored key is
/// left exactly as it was, including when the other key was created by a
/// concurrent call.
class KeychainKeyAlreadyExistsException extends KeychainException {
  const KeychainKeyAlreadyExistsException()
    : super('A keychain key with this id already exists');
}

/// The platform store conclusively holds no key under this id.
class KeychainKeyNotFoundException extends KeychainException {
  const KeychainKeyNotFoundException()
    : super('No keychain key exists with this id');
}

/// A key is stored under this id but the platform can no longer use it. It is
/// left in place: only an explicit delete removes it.
class KeychainKeyInvalidatedException extends KeychainException {
  const KeychainKeyInvalidatedException()
    : super('The keychain key exists but is no longer usable');
}

/// The platform reported a state it will leave on its own — the device is
/// locked, or the store is briefly busy. The same call may succeed once that
/// condition clears; nothing was changed.
class KeychainTemporarilyUnavailableException extends KeychainException {
  const KeychainTemporarilyUnavailableException({super.diagnosticCode})
    : super('The keychain is temporarily unavailable');
}

/// This platform confirmed it cannot provide the key store this package
/// needs. Every platform other than iOS and Android, web included, throws
/// this without calling anything.
class KeychainUnsupportedException extends KeychainException {
  const KeychainUnsupportedException({super.diagnosticCode})
    : super('The platform does not provide a supported keychain');
}

/// The platform failed for a reason it did not identify. Never read as "the
/// key is absent": whether it exists is unknown.
class KeychainPlatformFailureException extends KeychainException {
  const KeychainPlatformFailureException({super.diagnosticCode})
    : super('The keychain failed for an unidentified reason');
}
