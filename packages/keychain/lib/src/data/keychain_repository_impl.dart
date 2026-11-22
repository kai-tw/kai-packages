import 'dart:typed_data';

import '../domain/keychain_exception.dart';
import '../domain/keychain_key_entity.dart';
import '../domain/keychain_key_id_entity.dart';
import '../domain/keychain_repository.dart';
import 'keychain_data_source.dart';
import 'keychain_data_source_impl.dart';

class KeychainRepositoryImpl implements KeychainRepository {
  const KeychainRepositoryImpl(this._dataSource);

  /// Backs [KeychainRepository]'s factory constructor: the platform channels
  /// through [KeychainDataSourceImpl].
  factory KeychainRepositoryImpl.create() =>
      KeychainRepositoryImpl(KeychainDataSourceImpl());

  final KeychainDataSource _dataSource;

  // `create` and `generate` deliberately share one path with no `exists`
  // pre-check: a check-then-create would race a concurrent create, so the
  // same-name rule is enforced by the native create itself.
  @override
  Future<void> create(String permanentKeyName) async {
    await _dataSource.create(_validated(permanentKeyName));
  }

  @override
  Future<void> generate(String keyId) async {
    await _dataSource.create(_validated(keyId));
  }

  @override
  Future<KeychainKeyEntity> read(String keyId) async {
    final String validId = _validated(keyId);
    final Uint8List material = await _dataSource.read(validId);
    return KeychainKeyEntity(keyId: validId, material: material);
  }

  @override
  Future<bool> exists(String keyId) async {
    return _dataSource.exists(_validated(keyId));
  }

  @override
  Future<void> delete(String keyId) async {
    await _dataSource.delete(_validated(keyId));
  }

  @override
  Future<bool> get isAvailable => _dataSource.isAvailable;

  @override
  Stream<bool> get availabilityChanges => _dataSource.availabilityChanges;

  String _validated(String keyId) {
    if (!KeychainKeyIdEntity(keyId).isValid) {
      throw const KeychainInvalidKeyIdException();
    }
    return keyId;
  }
}
