import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/util/datetime_clamp_type.dart';
import 'package:immich_mobile/data/db/util/defaults_mixin.dart';

/// Queue of deletion intents. A row stays after the server move-to-trash, marked
/// by [trashedAt], until its server copy leaves the trash, so a file restored on
/// the device can bring the server copy back.
class LocalDeletionEntity extends Table with DriftDefaultsMixin {
  const LocalDeletionEntity();

  TextColumn get remoteId => text()();

  TextColumn get checksum => text()();

  TextColumn get ownerId => text()();

  DateTimeColumn get createdAt => customType(clampedDateTime).withDefault(currentDateAndTime)();

  DateTimeColumn get trashedAt => customType(clampedDateTime).nullable()();

  @override
  Set<Column> get primaryKey => {remoteId};
}

/// Local asset ids the app deleted itself while keeping the remote copy. The
/// deletion sync must not propagate these.
class LocalDeletionExclusionEntity extends Table with DriftDefaultsMixin {
  const LocalDeletionExclusionEntity();

  TextColumn get localId => text()();

  @override
  Set<Column> get primaryKey => {localId};
}
