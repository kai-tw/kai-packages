import 'package:versioned_json/versioned_json.dart';

/// A migrator at version 3, so a version-1 input exercises the loop across
/// two steps. Each step leaves a marker, and the first records the
/// `modifiedAt` it was handed.
class ThreeVersionMigrator extends VersionedJsonMigrator {
  const ThreeVersionMigrator();

  @override
  int get currentVersion => 3;

  @override
  Map<String, dynamic> migrateOneStep(
    Map<String, dynamic> source,
    int sourceVersion,
    DateTime modifiedAt,
  ) {
    final Map<String, dynamic> next = Map<String, dynamic>.of(source);
    switch (sourceVersion) {
      case 1:
        next['step1to2'] = true;
        next['migratedAt'] = modifiedAt.toUtc().toIso8601String();
        next[VersionedJsonMigrator.versionKey] = 2;
        return next;
      case 2:
        next['step2to3'] = true;
        next[VersionedJsonMigrator.versionKey] = 3;
        return next;
      default:
        throw StateError('no step from version $sourceVersion');
    }
  }
}
