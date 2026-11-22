# keychain_example

Demonstrates the keychain plugin: shows the current availability and creates
or reads one key, `demo.token`.

`integration_test/keychain_roundtrip_test.dart` runs a key through create,
read, refuse, delete and absence against the real platform store:

```bash
flutter test integration_test -d <device>
```
