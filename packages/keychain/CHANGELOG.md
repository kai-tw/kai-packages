## 0.1.0

First release.

- `KeychainRepository` — `create`, `generate`, `read`, `exists`, `delete`,
  `isAvailable` and `availabilityChanges` over 256-bit keys kept by the iOS
  Keychain and the Android Keystore. `KeychainRepository()` builds one backed
  by the platform; the implementation is not exported.
- `KeychainKeyEntity` — a key id and its 32 bytes of material; `toString`
  never prints the bytes.
- `KeychainException` — a sealed family with fixed messages and an optional
  numeric `diagnosticCode`. No logging dependency.
- Native plugin classes for iOS and Android, registered through
  `GeneratedPluginRegistrant`, with identifiers under `net.kaiwu.keychain`.
