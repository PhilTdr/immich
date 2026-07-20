import 'package:drift/drift.dart';
import 'package:immich_mobile/infrastructure/utils/drift_default.mixin.dart';

/// Queue of deletion intents. A row is removed once the server move-to-trash
/// succeeded.
class LocalDeletionEntity extends Table with DriftDefaultsMixin {
  const LocalDeletionEntity();

  TextColumn get remoteId => text()();

  TextColumn get checksum => text()();

  TextColumn get ownerId => text()();

  DateTimeColumn get createdAt => dateTime()();

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
