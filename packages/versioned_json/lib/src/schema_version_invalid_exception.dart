/// Raised when the schema version field is present but is not an integer of at
/// least 1 — `0`, `-3`, `2.0`, `"2"` or `null`.
///
/// Rejected rather than read as version 1: a `"2"` taken for version 1 would
/// run the 1→2 step over data that is already in the version-2 shape.
///
/// Carries no copy of the offending value: the data usually comes from storage
/// this code does not control, and the message tends to end up in a log.
class SchemaVersionInvalidException extends FormatException {
  const SchemaVersionInvalidException()
    : super('schema version is not an integer of at least 1');

  @override
  String toString() => 'SchemaVersionInvalidException: $message';
}
