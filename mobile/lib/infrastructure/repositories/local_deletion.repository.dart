import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/infrastructure/entities/local_deletion.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class DriftLocalDeletionRepository extends DriftDatabaseRepository {
  final Drift _db;

  const DriftLocalDeletionRepository(this._db) : super(_db);

  /// Queues [remoteIdToChecksum] as deletions of [ownerId] pending a server
  /// move-to-trash.
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

  /// Drops intents whose remote asset is already in the server trash.
  Future<void> pruneAlreadyTrashed() {
    final trashedRemotes = _db.remoteAssetEntity.selectOnly()
      ..addColumns([_db.remoteAssetEntity.id])
      ..where(_db.remoteAssetEntity.deletedAt.isNotNull());
    return (_db.delete(_db.localDeletionEntity)..where((row) => row.remoteId.isInQuery(trashedRemotes))).go();
  }

  /// Marks app-initiated local deletions (remote copy kept) so the deletion
  /// sync skips them.
  Future<void> markExcluded(Iterable<String> localIds) async {
    if (localIds.isEmpty) {
      return;
    }

    await _db.batch((batch) {
      for (final id in localIds) {
        batch.insert(
          _db.localDeletionExclusionEntity,
          LocalDeletionExclusionEntityCompanion.insert(localId: id),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> unmarkExcluded(Iterable<String> localIds) async {
    if (localIds.isEmpty) {
      return;
    }

    for (final slice in localIds.toSet().slices(kDriftMaxChunk)) {
      await (_db.delete(_db.localDeletionExclusionEntity)..where((row) => row.localId.isIn(slice))).go();
    }
  }

  /// Returns the subset of [localIds] that are marked as excluded.
  Future<Set<String>> getExcluded(Iterable<String> localIds) async {
    final result = <String>{};
    for (final slice in localIds.toSet().slices(kDriftMaxChunk)) {
      final query = _db.localDeletionExclusionEntity.selectOnly()
        ..addColumns([_db.localDeletionExclusionEntity.localId])
        ..where(_db.localDeletionExclusionEntity.localId.isIn(slice));
      result.addAll(await query.map((row) => row.read(_db.localDeletionExclusionEntity.localId)!).get());
    }
    return result;
  }

  /// Captures the current assets of [ownerId] into a temp table, so deletions
  /// can be detected after the reconciliation mutated the rows.
  Future<void> snapshotBackedUpAssets(String ownerId) {
    return _db.transaction(() async {
      await _createSnapshotTable();
      await _db.customStatement('DELETE FROM local_deletion_snapshot');
      await _db.customStatement(
        '''
        INSERT INTO local_deletion_snapshot (local_id, remote_id, checksum)
        SELECT la.id, ra.id, la.checksum
        FROM local_asset_entity la
        INNER JOIN remote_asset_entity ra ON ra.checksum = la.checksum
        WHERE ra.owner_id = ? AND ra.deleted_at IS NULL AND ra.library_id IS NULL
      ''',
        [ownerId],
      );
    });
  }

  /// Queues snapshot whose local asset is gone and cleans up exclusions of
  /// assets that no longer exist.
  Future<void> queueDeletionsFromSnapshot(String ownerId) {
    return _db.transaction(() async {
      await _createSnapshotTable();
      await _db.customStatement(
        '''
        INSERT OR REPLACE INTO local_deletion_entity (remote_id, checksum, owner_id)
        SELECT s.remote_id, s.checksum, ?
        FROM local_deletion_snapshot s
        WHERE NOT EXISTS (SELECT 1 FROM local_asset_entity la WHERE la.id = s.local_id)
          AND NOT EXISTS (SELECT 1 FROM local_deletion_exclusion_entity ex WHERE ex.local_id = s.local_id)
      ''',
        [ownerId],
      );
      await _db.customStatement(
        'DELETE FROM local_deletion_exclusion_entity WHERE local_id NOT IN (SELECT id FROM local_asset_entity)',
      );
      await _db.customStatement('DELETE FROM local_deletion_snapshot');
    });
  }

  Future<void> _createSnapshotTable() {
    return _db.customStatement(
      'CREATE TEMP TABLE IF NOT EXISTS local_deletion_snapshot '
      '(local_id TEXT NOT NULL PRIMARY KEY, remote_id TEXT NOT NULL, checksum TEXT NOT NULL)',
    );
  }

  /// Clears the queue and all exclusions.
  Future<void> deleteAll() {
    return _db.transaction(() async {
      await _db.delete(_db.localDeletionEntity).go();
      await _db.delete(_db.localDeletionExclusionEntity).go();
    });
  }
}
