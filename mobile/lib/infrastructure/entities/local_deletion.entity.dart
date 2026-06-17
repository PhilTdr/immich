import 'package:drift/drift.dart';
import 'package:immich_mobile/infrastructure/utils/drift_default.mixin.dart';

/// Durable, per-account queue of local → server deletions still to be pushed.
///
/// A row means: the local copy of a backed-up asset was deleted on this device,
/// so its remote counterpart should be moved to the server trash. The row is
/// removed once that move-to-trash has succeeded (the queue only ever holds
/// *pending* work) or cancelled when the same content reappears locally before
/// it was flushed.
///
/// The restore direction is NOT driven by this table — it is derived from the
/// synced remote trash state (a locally present asset whose own remote twin is
/// trashed), so it keeps working even after this table is empty (e.g. after a
/// reinstall).
@TableIndex.sql('CREATE INDEX IF NOT EXISTS idx_local_deletion_checksum ON local_deletion_entity (checksum)')
class LocalDeletionEntity extends Table with DriftDefaultsMixin {
  const LocalDeletionEntity();

  /// Remote asset id that is pending to be trashed on the server.
  TextColumn get remoteId => text()();

  /// Checksum of the deleted local asset. Used to cancel the pending deletion if
  /// the same content is still present locally (a duplicate row, or an undo
  /// before the deletion was flushed).
  TextColumn get checksum => text()();

  /// Owner (user id) of the remote asset. Scopes the queue per account so a
  /// logout / token-expiry reset neither strands the current user's pending
  /// deletions nor leaks them into the next account.
  ///
  /// Intentionally NOT a foreign key to `user_entity`: that row is wiped by the
  /// sync reset on logout, and an `ON DELETE CASCADE` would delete pending rows
  /// and defeat the durability this column exists to provide.
  TextColumn get ownerId => text()();

  @override
  Set<Column> get primaryKey => {remoteId};
}
