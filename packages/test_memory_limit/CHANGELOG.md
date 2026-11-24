## 0.1.0

First release.

- `limitMemory({int gigabytes = 4})` kills the test process once it uses more
  memory than that, from an isolate of its own, so it also stops a test
  stuck in a synchronous loop. Call it from `test/flutter_test_config.dart`.
- `MemoryLimit` takes the limit in bytes and how often to check.
