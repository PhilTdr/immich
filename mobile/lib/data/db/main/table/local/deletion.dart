import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/util/datetime_clamp_type.dart';
import 'package:immich_mobile/data/db/util/defaults_mixin.dart';

class LocalDeletionEntity extends Table with DriftDefaultsMixin {
  const LocalDeletionEntity();

  TextColumn get remoteId => text()();

  TextColumn get checksum => text()();

  TextColumn get ownerId => text()();

  DateTimeColumn get createdAt => customType(clampedDateTime).withDefault(currentDateAndTime)();

  // Set once the server copy is trashed. The row stays to restore that copy if the file comes back
  DateTimeColumn get trashedAt => customType(clampedDateTime).nullable()();

  // The album the deletion is listed under on the confirmation page
  TextColumn get albumId => text().nullable()();

  TextColumn get albumName => text().nullable()();

  BoolColumn get awaitingConfirmation => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {remoteId};
}
