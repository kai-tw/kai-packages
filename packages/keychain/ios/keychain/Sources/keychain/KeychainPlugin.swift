import Flutter
import Foundation
import Security
import UIKit

/// The iOS half of the Dart `KeychainDataSourceImpl`, over the
/// `net.kaiwu.keychain` MethodChannel and its `/availability` EventChannel.
///
/// Each key is a 256-bit random secret stored as a generic-password item
/// (service `keychainService`, account = the Dart key id), accessible only
/// while the device is unlocked and never migrated to another device by a
/// backup (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). `read` answers
/// with the secret itself: callers on every platform get a key they can use
/// directly.
///
/// Errors are the package's closed vocabulary — `alreadyExists`, `notFound`,
/// `invalidated`, `temporarilyUnavailable`, `unsupported` — or `failed` with
/// the numeric `OSStatus` as details. Never the key id: it can be a record id.
///
/// Registered automatically by `GeneratedPluginRegistrant`; a consuming app
/// makes no registration call of its own.
public final class KeychainPlugin: NSObject, FlutterPlugin {
  private static let channelName = "net.kaiwu.keychain"
  private let keychainService = "net.kaiwu.keychain"
  private let keyByteCount = 32
  /// The Dart `KeychainKeyIdEntity` format; its 128 length bound is checked
  /// beside it.
  private let keyIdFormat = "^[a-z][a-z0-9_]*\\.[A-Za-z0-9][A-Za-z0-9_-]*$"

  /// Keychain calls can block, so they run off the main thread. Serial, so a
  /// create and a delete of one id from this plugin instance apply in call
  /// order.
  private let queue = DispatchQueue(label: "net.kaiwu.keychain")

  private let availabilityHandler = KeychainAvailabilityStreamHandler()
  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = KeychainPlugin()
    let messenger = registrar.messenger()

    let events = FlutterEventChannel(name: channelName + "/availability", binaryMessenger: messenger)
    events.setStreamHandler(instance.availabilityHandler)
    instance.eventChannel = events

    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.methodChannel = channel
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    methodChannel?.setMethodCallHandler(nil)
    eventChannel?.setStreamHandler(nil)
    methodChannel = nil
    eventChannel = nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Answered on the main thread, where UIApplication must be read.
    if call.method == "isAvailable" {
      result(UIApplication.shared.isProtectedDataAvailable)
      return
    }
    // Dart validates the id; checked again so both native halves refuse
    // the same ids.
    guard let args = call.arguments as? [String: Any],
          let keyId = args["keyId"] as? String,
          keyId.count <= 128,
          keyId.range(of: keyIdFormat, options: .regularExpression) != nil else {
      result(FlutterError(code: "badArgs", message: "keyId is required", details: nil))
      return
    }
    let operation: () -> Any?
    switch call.method {
    case "create": operation = { self.create(keyId) }
    case "read": operation = { self.read(keyId) }
    case "exists": operation = { self.exists(keyId) }
    case "delete": operation = { self.delete(keyId) }
    default:
      result(FlutterMethodNotImplemented)
      return
    }
    queue.async {
      let answer = operation()
      DispatchQueue.main.async { result(answer) }
    }
  }

  private func baseQuery(_ keyId: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keyId,
    ]
  }

  /// `SecItemAdd` is atomic: when an item with the same service + account
  /// already exists it fails with `errSecDuplicateItem` and leaves that item
  /// untouched, so two concurrent creates can never overwrite each other.
  private func create(_ keyId: String) -> Any? {
    var bytes = [UInt8](repeating: 0, count: keyByteCount)
    defer { for index in bytes.indices { bytes[index] = 0 } }
    let randomStatus = SecRandomCopyBytes(kSecRandomDefault, keyByteCount, &bytes)
    guard randomStatus == errSecSuccess else {
      return failure(randomStatus)
    }
    var query = baseQuery(keyId)
    query[kSecValueData as String] = Data(bytes)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    query[kSecAttrSynchronizable as String] = false
    let status = SecItemAdd(query as CFDictionary, nil)
    return status == errSecSuccess ? nil : failure(status)
  }

  /// The item's protection class refuses the read while the device is
  /// locked, which surfaces as `temporarilyUnavailable`.
  private func read(_ keyId: String) -> Any? {
    var query = baseQuery(keyId)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else {
      return failure(status)
    }
    guard let data = item as? Data, data.count == keyByteCount else {
      return FlutterError(code: "invalidated", message: "stored key is unusable", details: nil)
    }
    return FlutterStandardTypedData(bytes: data)
  }

  private func exists(_ keyId: String) -> Any? {
    var query = baseQuery(keyId)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    switch status {
    case errSecSuccess: return true
    case errSecItemNotFound: return false
    default: return failure(status)
    }
  }

  /// An item that is already gone counts as deleted.
  private func delete(_ keyId: String) -> Any? {
    let status = SecItemDelete(baseQuery(keyId) as CFDictionary)
    switch status {
    case errSecSuccess, errSecItemNotFound: return nil
    default: return failure(status)
    }
  }

  private func failure(_ status: OSStatus) -> FlutterError {
    let code: String
    switch status {
    case errSecDuplicateItem: code = "alreadyExists"
    case errSecItemNotFound: code = "notFound"
    // The item's protection class is locked: the device is locked, or has not
    // been unlocked since boot. Clears on unlock.
    case errSecInteractionNotAllowed: code = "temporarilyUnavailable"
    // No keychain is available to this process at all.
    case errSecNotAvailable: code = "unsupported"
    default: code = "failed"
    }
    return FlutterError(code: code, message: "keychain operation failed", details: Int(status))
  }
}

/// Sends `true` / `false` each time protected data — and with it every
/// `WhenUnlocked` Keychain item — becomes available or is about to become
/// unavailable. Nothing is sent on listen: Dart asks `isAvailable` for that.
private final class KeychainAvailabilityStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    removeObservers()
    sink = events
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: UIApplication.protectedDataDidBecomeAvailableNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.sink?(true) },
      center.addObserver(
        forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.sink?(false) },
    ]
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    removeObservers()
    sink = nil
    return nil
  }

  private func removeObservers() {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
  }
}
