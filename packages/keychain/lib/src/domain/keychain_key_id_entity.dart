import 'package:equatable/equatable.dart';

/// The `<feature>.<key-id>` format every keychain key id must follow.
///
/// The first segment is the owning feature's namespace in snake_case; the
/// second is a fixed name, a stable record id or a UUID. Exactly one dot
/// separates them, so a namespace can never be spelled into the second
/// segment. The format is strict on purpose: an id that does not match is
/// refused, never normalised, so two spellings can never name one key.
class KeychainKeyIdEntity extends Equatable {
  const KeychainKeyIdEntity(this.value);

  /// Long enough for `<feature>.<uuid>`; bounded so an id never grows into a
  /// payload on its way to the platform store.
  static const int maxLength = 128;

  static final RegExp _format = RegExp(
    r'^[a-z][a-z0-9_]*\.[A-Za-z0-9][A-Za-z0-9_-]*$',
  );

  final String value;

  bool get isValid => value.length <= maxLength && _format.hasMatch(value);

  @override
  List<Object?> get props => <Object?>[value];

  KeychainKeyIdEntity copyWith({String? value}) {
    return KeychainKeyIdEntity(value ?? this.value);
  }
}
