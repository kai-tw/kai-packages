/// File reading, writing and directory sweeps for versioned JSON.
///
/// The only library in this package that imports `dart:io`, so it is
/// unavailable on the web; `package:versioned_json/versioned_json.dart` alone
/// works everywhere.
library;

export 'src/io/versioned_json_migrator_io.dart';
export 'src/io/versioned_json_schema_io.dart';
