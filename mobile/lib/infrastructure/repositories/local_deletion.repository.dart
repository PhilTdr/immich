import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/infrastructure/entities/local_deletion.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

/// Durable, per-account queue of remote assets pending a move to the server
/// trash because their local copy was deleted on this device (see
/// [LocalDeletionEntity]). The restore direction is derived from the synced
/// remote trash state and does not consult this table.
class DriftLocalDeletionRepository extends DriftDatabaseRepository {
  final Drift _db;

  const DriftLocalDeletionRepository(this._db) : super(_db);

  /// Records [remoteIdToChecksum] (remote asset id → checksum of the deleted
  /// local asset) as pending deletions owned by [ownerId]. A row is kept until
  /// the server move-to-trash succeeds (then deleted) or the same content
  /// reappears locally before flushing (then cancelled). Re-recording an
  /// existing remote id simply overwrites its checksum/owner.
  Future<void> upsert(String ownerId, Map<String, String> remoteIdToChecksum) async {
    if (remoteIdToChecksum.isEmpty) {
      return;
    }

    await _db.batch((batch) {
      for (final entry in remoteIdToChecksum.entries) {
        final companion = LocalDeletionEntityCompanion.insert(
          remoteId: entry.key,
          checksum: entry.value,
          ownerId: ownerId,
        );
        batch.insert(_db.localDeletionEntity, companion, onConflict: DoUpdate((_) => companion));
      }
    });
  }

  /// Pending deletions owned by [ownerId]. Every row is pending by definition
  /// (confirmed deletions are removed), and they are retried on every sync so a
  /// transient failure of the server move-to-trash is never lost.
  Future<List<({String remoteId, String checksum})>> getPending(String ownerId) {
    final query = _db.localDeletionEntity.select()..where((row) => row.ownerId.equals(ownerId));
    return query.map((row) => (remoteId: row.remoteId, checksum: row.checksum)).get();
  }

  Future<void> deleteByRemoteIds(Iterable<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    for (final slice in remoteIds.toSet().slices(kDriftMaxChunk)) {
      await (_db.delete(_db.localDeletionEntity)..where((row) => row.remoteId.isIn(slice))).go();
    }
  }

  /// Removes queue rows belonging to any account other than [ownerId]. Called at
  /// the start of an owner-scoped sync so a previous account's pending deletions
  /// cannot linger on the device or act on the current session.
  Future<void> deleteForeignRows(String ownerId) {
    return (_db.delete(_db.localDeletionEntity)..where((row) => row.ownerId.equals(ownerId).not())).go();
  }

  /// Clears all queue rows (hard wipe).
  Future<void> deleteAll() => _db.delete(_db.localDeletionEntity).go();
}
