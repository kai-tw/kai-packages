import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_system/log_system.dart';
// Not exported: the redactor is package-internal, and reaching it from a test
// inside the same package is the point of `src/`.
import 'package:log_system/src/data/adapters/log_error_redactor.dart';

class _DomainException implements Exception {
  const _DomainException();

  @override
  String toString() => 'customer 王小明, phone 0912345678';
}

/// Shaped like the real thing: a domain exception that translated a
/// `SocketException` and kept only its errno.
class _CloudSocketException extends LoggableException {
  const _CloudSocketException(int? code) : super(diagnosticCode: code);
}

void main() {
  tearDown(() => LogErrorRedactor.describeExtra = null);

  group('a host describer keeps a field this package cannot name', () {
    test('the field is appended and the type name is still prepended', () {
      LogErrorRedactor.describeExtra = (Object error) =>
          error is _DomainException ? 'status=404' : null;
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        '_DomainException status=404',
      );
    });

    test('two fields are allowed', () {
      LogErrorRedactor.describeExtra = (Object error) =>
          'status=404 connectionTimeout';
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        '_DomainException status=404 connectionTimeout',
      );
    });

    test('exactly three fields is still allowed — the boundary itself', () {
      LogErrorRedactor.describeExtra = (Object error) => 'a b c';
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        '_DomainException a b c',
      );
    });

    test('four fields is gated — one past the boundary', () {
      LogErrorRedactor.describeExtra = (Object error) => 'a b c d';
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        '_DomainException',
      );
    });

    test('a bare backslash with nothing else present is still gated', () {
      // Isolates one clause of `field.contains(r'\') || field.contains('\n')`:
      // a value with no space, no slash and no newline, but a backslash,
      // must still be caught by that clause alone.
      LogErrorRedactor.describeExtra = (Object error) => r'a\b';
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        '_DomainException',
      );
    });

    test('returning null falls through to the built-in arms', () {
      LogErrorRedactor.describeExtra = (Object error) => null;
      expect(
        LogErrorRedactor.redact(const OSError('EACCES', 13)).toString(),
        'OSError errno=13',
      );
    });

    test('a describer runs before the built-in arms, so it can override', () {
      LogErrorRedactor.describeExtra = (Object error) => 'overridden';
      expect(
        LogErrorRedactor.redact(const OSError('EACCES', 13)).toString(),
        'OSError overridden',
      );
    });

    test('a describer that returns a path is still gated', () {
      // The whole point is that nothing outside can widen the egress. A
      // describer written wrong is a mistake this boundary absorbs.
      LogErrorRedactor.describeExtra = (Object error) =>
          'path=/Users/someone/books/王小明.epub';
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        '_DomainException',
      );
    });

    test('a describer that returns a sentence is still gated', () {
      LogErrorRedactor.describeExtra = (Object error) =>
          'could not open the file';
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        '_DomainException',
      );
    });

    test('a describer that returns an over-long value is still gated', () {
      LogErrorRedactor.describeExtra = (Object error) => 'a' * 49;
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        '_DomainException',
      );
    });

    test('exactly 48 characters is still allowed — the boundary itself', () {
      final String value = 'a' * 48;
      LogErrorRedactor.describeExtra = (Object error) => value;
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        '_DomainException $value',
      );
    });
  });

  group('default-deny', () {
    test('an unrecognised type is reduced to its type name', () {
      final String redacted = LogErrorRedactor.redact(
        const _DomainException(),
      ).toString();
      expect(redacted, '_DomainException');
      expect(redacted, isNot(contains('王小明')));
      expect(redacted, isNot(contains('0912345678')));
    });

    test('the shape that actually leaks does not survive', () {
      // base64Decode's FormatException prints its entire source string. When
      // that source is key material, the exception *is* the key. Asserted
      // against the real exception rather than a stand-in, so a change to
      // Dart's formatting cannot quietly invalidate it.
      late final FormatException leaky;
      try {
        base64Decode('c2VjcmV0LWtleS1tYXRlcmlhbA==!!CORRUPT');
        fail('expected base64Decode to reject the input');
      } on FormatException catch (error) {
        leaky = error;
      }
      expect(leaky.toString(), contains('c2VjcmV0'));
      expect(
        LogErrorRedactor.redact(leaky).toString(),
        isNot(contains('c2VjcmV0')),
      );
    });

    test('no error object says so, rather than arriving as "null"', () {
      // `LogSystem.error('…')` with a message only is how this happens.
      // Leaving it null does not keep it out of the report: the plugin's last
      // line is `exception.toString()` on a `dynamic`, so the issue would be
      // titled `null` and every message-only call site would group under it.
      expect(
        LogErrorRedactor.redact(null).toString(),
        '<no error object>',
      );
    });

    test('the surrogate leads with the type name, so grouping survives', () {
      // flutterfire #3310: the reporter groups non-fatals on the exception
      // type/message. A surrogate that dropped the type name would collapse
      // every redacted error into a single issue.
      expect(
        LogErrorRedactor.redact(const SocketException('x')).toString(),
        startsWith('SocketException'),
      );
      expect(
        LogErrorRedactor.redact(const _DomainException()).toString(),
        startsWith('_DomainException'),
      );
    });
  });

  group('allow-listed structural fields', () {
    test('SocketException keeps errno and drops the address', () {
      const SocketException error = SocketException(
        'Connection refused',
        osError: OSError('Connection refused', 61),
        port: 443,
      );
      expect(
        LogErrorRedactor.redact(error).toString(),
        'SocketException errno=61',
      );
    });

    test('a missing OSError renders a dash rather than throwing', () {
      expect(
        LogErrorRedactor.redact(const SocketException('x')).toString(),
        'SocketException errno=-',
      );
    });

    test('FileSystemException keeps errno and drops the path', () {
      const FileSystemException error = FileSystemException(
        'Cannot open',
        '/Users/someone/Documents/customers.db',
        OSError('No space left on device', 28),
      );
      final String redacted = LogErrorRedactor.redact(error).toString();
      expect(redacted, 'FileSystemException errno=28');
      expect(redacted, isNot(contains('customers')));
    });

    test('OSError keeps its code', () {
      expect(
        LogErrorRedactor.redact(const OSError('EACCES', 13)).toString(),
        'OSError errno=13',
      );
    });
  });

  group('PlatformException.code is admitted only when it is a token', () {
    test('an opaque code survives', () {
      expect(
        LogErrorRedactor.redact(
          PlatformException(code: 'channel-error'),
        ).toString(),
        'PlatformException code=channel-error',
      );
    });

    test('a code containing a path degrades to type-name-only', () {
      expect(
        LogErrorRedactor.redact(
          PlatformException(code: '/Users/someone/file.txt'),
        ).toString(),
        'PlatformException',
      );
    });

    test('a code containing a sentence degrades', () {
      expect(
        LogErrorRedactor.redact(
          PlatformException(code: 'could not open the file'),
        ).toString(),
        'PlatformException',
      );
    });

    test('an over-long code degrades', () {
      expect(
        LogErrorRedactor.redact(PlatformException(code: 'a' * 49)).toString(),
        'PlatformException',
      );
    });

    test('exactly 48 characters still survives — the boundary itself', () {
      final String code = 'a' * 48;
      expect(
        LogErrorRedactor.redact(PlatformException(code: code)).toString(),
        'PlatformException code=$code',
      );
    });

    test('a code with nothing but a backslash still degrades', () {
      // Isolates one clause of `contains(r'\') || contains('\n')`: no space,
      // no slash, no newline, but a backslash — that clause alone must catch
      // it.
      expect(
        LogErrorRedactor.redact(PlatformException(code: r'a\b')).toString(),
        'PlatformException',
      );
    });
  });

  group('LoggableException — the template an app extends', () {
    test('a code in range survives, and toString is never read', () {
      final String redacted = LogErrorRedactor.redact(
        const _CloudSocketException(61),
      ).toString();
      expect(redacted, '_CloudSocketException code=61');
    });

    test('a null code renders a dash', () {
      expect(
        LogErrorRedactor.redact(const _CloudSocketException(null)).toString(),
        '_CloudSocketException code=-',
      );
    });

    test('an out-of-band code degrades to type-name-only', () {
      // The template must never be able to widen the egress, however it is
      // misused downstream — a timestamp or a row count is not a diagnostic.
      expect(
        LogErrorRedactor.redact(
          const _CloudSocketException(1700000000),
        ).toString(),
        '_CloudSocketException',
      );
      expect(
        LogErrorRedactor.redact(const _CloudSocketException(-1)).toString(),
        '_CloudSocketException',
      );
    });

    test('the band edges themselves survive — 0 and 65535', () {
      // `(code < 0 || code > 65535)`: -1 and 1700000000 above only prove the
      // OUTSIDE of the band is rejected. These two are the innermost values
      // still IN the band, which is what pins `<`/`>` against `<=`/`>=`.
      expect(
        LogErrorRedactor.redact(const _CloudSocketException(0)).toString(),
        '_CloudSocketException code=0',
      );
      expect(
        LogErrorRedactor.redact(const _CloudSocketException(65535)).toString(),
        '_CloudSocketException code=65535',
      );
    });

    test('the template itself prints no message', () {
      // The console sees this too, so the type is never given the chance to
      // describe itself in free text.
      expect(
        const _CloudSocketException(61).toString(),
        '_CloudSocketException(code=61)',
      );
      expect(
        const _CloudSocketException(null).toString(),
        '_CloudSocketException',
      );
    });
  });

  group('redactDetails', () {
    test('drops context and information, keeps stack and library', () {
      final StackTrace stack = StackTrace.current;
      final FlutterErrorDetails details = FlutterErrorDetails(
        exception: const _DomainException(),
        stack: stack,
        library: 'my_app',
        context: ErrorDescription('while building CustomerCard for 王小明'),
        informationCollector: () => <DiagnosticsNode>[
          ErrorDescription('phone 0912345678'),
        ],
      );

      final FlutterErrorDetails redacted = LogErrorRedactor.redactDetails(
        details,
      );

      expect(redacted.exception.toString(), '_DomainException');
      expect(redacted.stack, same(stack));
      expect(redacted.library, 'my_app');
      expect(redacted.context, isNull);
      expect(redacted.informationCollector, isNull);
    });
  });
}
