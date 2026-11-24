import 'dart:async';

import 'package:async/async.dart' show Result;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/keychain_exception.dart';
import 'keychain_data_source.dart';

/// Talks to this package's `KeychainPlugin` on iOS and Android and translates
/// their closed set of error codes into the [KeychainException] family.
class KeychainDataSourceImpl implements KeychainDataSource {
  KeychainDataSourceImpl({bool isWeb = kIsWeb}) : _isWeb = isWeb;

  static const String _channelName = 'net.kaiwu.keychain';

  /// Every key is 256 bits on both platforms.
  static const int keyByteCount = 32;

  /// A safety net for a hung native handler, not a pacing wait: a StrongBox
  /// key generation can take a few seconds on its own.
  static const Duration _timeout = Duration(seconds: 15);

  final MethodChannel _channel = const MethodChannel(_channelName);

  /// The native side sends nothing on listen; after that, iOS sends one event
  /// per availability change and Android none. One channel stream is shared
  /// by every listener: a second `receiveBroadcastStream` on the same channel
  /// would take over the native sink from the first.
  late final Stream<bool> _changes =
      const EventChannel('$_channelName/availability')
          .receiveBroadcastStream()
          .map(_asAvailability)
          .transform(
            StreamTransformer<bool, bool>.fromHandlers(
              handleError: (Object e, StackTrace s, EventSink<bool> sink) {
                sink.addError(e is PlatformException ? _translate(e) : e, s);
              },
            ),
          );

  /// Taken by constructor because `kIsWeb` is a compile-time constant: on a
  /// web build `defaultTargetPlatform` names the host OS, so the platform
  /// switch alone would send web to a channel nothing answers.
  final bool _isWeb;

  @override
  Future<void> create(String keyId) async {
    await _invoke<void>('create', keyId: keyId);
  }

  @override
  Future<void> store(String keyId, Uint8List material) async {
    await _invoke<void>(
      'store',
      keyId: keyId,
      extra: <String, Object>{'material': material},
    );
  }

  @override
  Future<Uint8List> read(String keyId) async {
    final Uint8List? material = await _invoke<Uint8List>('read', keyId: keyId);
    // The native handler answers `read` with the key or an error, never with
    // nothing or a key of another size; either means the two sides drifted.
    if (material == null || material.length != keyByteCount) {
      throw const KeychainPlatformFailureException();
    }
    return material;
  }

  @override
  Future<bool> exists(String keyId) async {
    final bool? exists = await _invoke<bool>('exists', keyId: keyId);
    // Same contract drift as `read`: absent is `false`, never null.
    if (exists == null) {
      throw const KeychainPlatformFailureException();
    }
    return exists;
  }

  @override
  Future<void> delete(String keyId) async {
    await _invoke<void>('delete', keyId: keyId);
  }

  @override
  Future<bool> get isAvailable async {
    final bool? available = await _invoke<bool>('isAvailable');
    if (available == null) {
      throw const KeychainPlatformFailureException();
    }
    return available;
  }

  /// Subscribes to the native changes first, then asks for the current state,
  /// so no change can fall between the two.
  @override
  Stream<bool> get availabilityChanges {
    if (!_isSupportedPlatform) {
      return const Stream<bool>.empty();
    }
    late final StreamController<bool> controller;
    StreamSubscription<bool>? subscription;
    bool changed = false;
    controller = StreamController<bool>(
      onListen: () {
        subscription = _changes.listen((bool available) {
          changed = true;
          controller.add(available);
        }, onError: controller.addError);
        // The answer, value or error, reaches the listener through the
        // controller.
        unawaited(_addCurrentAvailability(controller, () => changed));
      },
      // A cancelled single-subscription controller drops whatever is added
      // later, so a late state answer needs no guard and no close.
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream.distinct();
  }

  /// The answer, value or error, is dropped if [hasChanged] by the time it
  /// lands: it may predate that change.
  Future<void> _addCurrentAvailability(
    StreamController<bool> controller,
    bool Function() hasChanged,
  ) async {
    final Result<bool> answer = await Result.capture(isAvailable);
    if (!hasChanged()) {
      answer.addTo(controller);
    }
  }

  bool _asAvailability(Object? event) {
    if (event is! bool) {
      throw const KeychainPlatformFailureException();
    }
    return event;
  }

  Future<T?> _invoke<T>(
    String method, {
    String? keyId,
    Map<String, Object> extra = const <String, Object>{},
  }) async {
    if (!_isSupportedPlatform) {
      throw const KeychainUnsupportedException();
    }

    try {
      return await _channel
          .invokeMethod<T>(
            method,
            keyId == null ? null : <String, Object>{'keyId': keyId, ...extra},
          )
          .timeout(_timeout);
    } on PlatformException catch (e, s) {
      Error.throwWithStackTrace(_translate(e), s);
    } on MissingPluginException catch (_, s) {
      // The plugin registers its handler on both supported platforms, so a
      // missing one is a build fault, not a platform without a key store.
      Error.throwWithStackTrace(const KeychainPlatformFailureException(), s);
    } on TimeoutException catch (_, s) {
      // A timeout does not confirm a temporary state, and the native call may
      // still land: the caller re-checks with the same id.
      Error.throwWithStackTrace(const KeychainPlatformFailureException(), s);
    }
  }

  /// Only the platforms whose native half exists: iOS Keychain and Android
  /// Keystore. The rest have no key store this package can stand behind.
  bool get _isSupportedPlatform {
    if (_isWeb) {
      return false;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS || TargetPlatform.android:
        return true;
      case TargetPlatform.fuchsia ||
          TargetPlatform.linux ||
          TargetPlatform.macOS ||
          TargetPlatform.windows:
        return false;
    }
  }

  /// The native side's codes are this package's own closed vocabulary; any
  /// other code is an unidentified failure, never "not found".
  KeychainException _translate(PlatformException e) {
    final Object? details = e.details;
    final int? code = details is int ? details : null;
    switch (e.code) {
      case 'alreadyExists':
        return const KeychainKeyAlreadyExistsException();
      case 'notFound':
        return const KeychainKeyNotFoundException();
      case 'invalidated':
        return const KeychainKeyInvalidatedException();
      case 'temporarilyUnavailable':
        return KeychainTemporarilyUnavailableException(diagnosticCode: code);
      case 'unsupported':
        return KeychainUnsupportedException(diagnosticCode: code);
      case _:
        return KeychainPlatformFailureException(diagnosticCode: code);
    }
  }
}
