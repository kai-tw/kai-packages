# keychain

A local key store for Flutter apps. It creates, locates and deletes 256-bit
keys protected by the platform — iOS Keychain, Android Keystore — works
offline, and reports whether keys can be reached right now.

It manages keys only. Encrypting and decrypting data with them is the caller's
business.

```dart
final KeychainRepository keychain = KeychainRepository();

try {
  await keychain.create('demo.token');
} on KeychainKeyAlreadyExistsException {
  // The existing key is kept exactly as it was.
}

final KeychainKeyEntity key = await keychain.read('demo.token');
use(key.material); // 32 bytes; never log or persist them

await keychain.delete('demo.token');
```

`KeychainRepository()` builds a new repository on every call; every instance
reaches the same platform store, so whether it is a singleton is the consuming
app's DI decision:

```dart
sl.registerLazySingleton<KeychainRepository>(KeychainRepository.new); // get_it
```

## The API

| Member | Does |
|---|---|
| `create(name)` | Creates a key under a fixed name such as `demo.token`. |
| `generate(id)` | Creates a key under a dynamic id such as `demo.<uuid>`. Persist the id first: after an interrupted call it is how you find out, through `exists` or `read`, whether the key was made. |
| `read(id)` | The key stored under the id, as a `KeychainKeyEntity` (`keyId` + 32 bytes of `material`). Creates and changes nothing. |
| `exists(id)` | `true` / `false` only when the platform answered conclusively; otherwise it throws. Says nothing about usability — `read` answers that. |
| `delete(id)` | Removes the key. A key that is already absent counts as removed. |
| `isAvailable()` | Whether keys can be reached right now. |
| `availabilityChanges` | The current availability when listened to; on iOS, every change after it. Android: see below. |

Every id is `<feature>.<key-id>`: a lowercase snake_case namespace, one dot, and
a fixed name, record id or UUID; at most 128 characters. An id that does not
match is refused with `KeychainInvalidKeyIdException` before the platform is
touched — never normalised, so two spellings can never name one key.

`create` and `generate` share one name space and one rule: a key already
stored under the id is kept and `KeychainKeyAlreadyExistsException` is thrown,
including when a concurrent call created it. The platform makes the check and
the create one atomic step.

## What is stored where

| | iOS | Android |
|---|---|---|
| Key material | 32 random bytes from `SecRandomCopyBytes`, stored as a generic-password Keychain item | 32 random bytes from `SecureRandom`, sealed with AES-256-GCM by a Keystore key (StrongBox where the device has it, the TEE otherwise) |
| Where | The Keychain, item class `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable` false | One file per key in `noBackupFilesDir/keychain/`; the Keystore key under the alias `net.kaiwu.keychain.<id>` |
| Same-id atomicity | `SecItemAdd` | One process-wide thread runs every keychain call |

Native identifiers: the method channel `net.kaiwu.keychain`, the event channel
`net.kaiwu.keychain/availability`, the iOS Keychain service
`net.kaiwu.keychain`.

## Nothing is backed up

Keys never leave the device. The iOS item class is `ThisDeviceOnly` and is not
synchronised to iCloud Keychain; Android's `noBackupFilesDir` is excluded from
backup and device transfer whatever the app's manifest says, and a Keystore key
cannot be exported. After a restore or on a new device the keys are gone: a
caller has to be able to fetch or derive again whatever it protected with them.

## Unavailable is not absent

`isAvailable()` is `false` while the device is locked (iOS), or before the
first unlock after boot. The keys are still there. A caller must never delete
or re-create a key because the keychain is unavailable — it retries once keys
are available again. Likewise a `read` that throws
`KeychainTemporarilyUnavailableException` changed nothing.

On iOS, `availabilityChanges` tells when that is. On Android, a
`directBootAware` app is the only kind that can run before the first unlock;
for any other app `isAvailable()` is `true` whenever it runs, and
`availabilityChanges` emits that one value. This version sends no later change
on Android, so a `directBootAware` app that read `false` asks `isAvailable()`
again after the first unlock.

## Errors

Every failure is a `KeychainException`, a sealed family with fixed messages
that never include the key id (an id can be a stable record id), so a
`switch` over it is exhaustive:

| Exception | Meaning |
|---|---|
| `KeychainInvalidKeyIdException` | The id is not `<feature>.<key-id>`. Nothing was asked of the platform. |
| `KeychainKeyAlreadyExistsException` | A create met a stored key; that key is untouched. |
| `KeychainKeyNotFoundException` | The platform conclusively holds no key under the id. |
| `KeychainKeyInvalidatedException` | A key is stored but can no longer be used. It is left in place; only `delete` removes it. |
| `KeychainTemporarilyUnavailableException` | Locked or briefly busy; the same call may succeed later. |
| `KeychainUnsupportedException` | The platform has no key store this package supports. |
| `KeychainPlatformFailureException` | The platform failed without saying why. Never read it as "absent". |

The platform-reported variants carry `diagnosticCode`, the numeric `OSStatus`
or Keystore error code when one was sent. The package logs nothing itself; log
where you catch.

## Platform support

iOS and Android. On every other platform, web included, each call throws
`KeychainUnsupportedException` without reaching a channel, and
`availabilityChanges` emits nothing.

The plugin registers itself through `GeneratedPluginRegistrant`; there is no
native setup to do in a consuming app.
