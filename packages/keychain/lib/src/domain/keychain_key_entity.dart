import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// A usable key read from the keychain: the 32 bytes of key material stored
/// under [keyId], the same shape on every platform.
///
/// iOS keeps the material in the Keychain itself; Android keeps it wrapped by
/// a Keystore key that never leaves the Keystore. The caller does not need to
/// know which: either way it gets bytes it can use directly. Hold them only
/// as long as the use needs, and never log or persist them.
class KeychainKeyEntity extends Equatable {
  const KeychainKeyEntity({required this.keyId, required this.material});

  /// The full `<feature>.<key-id>` the key was created under.
  final String keyId;

  final Uint8List material;

  @override
  List<Object?> get props => <Object?>[keyId, material];

  /// Never prints [material]: an entity that reaches a log or an error report
  /// must not carry the key with it.
  @override
  String toString() => 'KeychainKeyEntity($keyId)';

  KeychainKeyEntity copyWith({String? keyId, Uint8List? material}) {
    return KeychainKeyEntity(
      keyId: keyId ?? this.keyId,
      material: material ?? this.material,
    );
  }
}
