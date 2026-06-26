import 'package:drift/drift.dart';
import 'package:immich_mobile/infrastructure/utils/drift_default.mixin.dart';

/// Durable, per-account watch list of local assets that (re)appeared on this
/// device and are pending a checksum so they can be matched against the synced
/// remote trash.
///
/// A row means: this local asset showed up in a sync (a delta update or a
/// full-sync add) and has not been resolved yet. Once the asset is hashed, the
/// restore sweep checks whether its own remote twin is trashed on the server
/// and, if so, restores it — then the row is removed. Rows that turn out to
/// match nothing (or whose local asset disappears again) are removed as well.
///
/// This is what makes the restore direction survive a reinstall: it is driven by
/// the reappearance event, not by the local → server deletion queue
/// (`LocalDeletionEntity`).
class LocalRestoreEntity extends Table with DriftDefaultsMixin {
  const LocalRestoreEntity();

  /// Local asset id awaiting resolution.
  TextColumn get assetId => text()();

  /// Owner (user id) the watch belongs to. Scopes the list per account so it is
  /// cleared on account switch; intentionally NOT a foreign key, for the same
  /// reason as the local → server deletion queue's owner column.
  TextColumn get ownerId => text()();

  @override
  Set<Column> get primaryKey => {assetId};
}
