import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/deletion.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.drift.dart';

@DriftAccessor()
class LocalDeletionRepository extends DatabaseAccessor<Drift> with $LocalDeletionRepositoryMixin {
  LocalDeletionRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  /// Queues [remoteIdToChecksum] as deletions of [ownerId] pending a server move-to-trash
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

  /// The remote id and checksum of the backed-up copies of [localIds]: the user's own uploads that are not trashed,
  /// never partner or external library assets that share a checksum
  Future<Map<String, String>> getBackedUp(String ownerId, Iterable<String> localIds) async {
    final result = <String, String>{};
    for (final slice in localIds.toSet().slices(kDriftMaxChunk)) {
      final query = _db.localAssetEntity.selectOnly()
        ..addColumns([_db.remoteAssetEntity.id, _db.remoteAssetEntity.checksum])
        ..join([
          innerJoin(
            _db.remoteAssetEntity,
            _db.remoteAssetEntity.checksum.equalsExp(_db.localAssetEntity.checksum) &
                _db.remoteAssetEntity.ownerId.equals(ownerId) &
                _db.remoteAssetEntity.deletedAt.isNull() &
                _db.remoteAssetEntity.libraryId.isNull(),
            useColumns: false,
          ),
        ])
        ..where(_db.localAssetEntity.id.isIn(slice));
      for (final row in await query.get()) {
        result[row.read(_db.remoteAssetEntity.id)!] = row.read(_db.remoteAssetEntity.checksum)!;
      }
    }
    return result;
  }

  Future<List<String>> getPending(String ownerId) {
    final query = _db.localDeletionEntity.selectOnly()
      ..addColumns([_db.localDeletionEntity.remoteId])
      ..where(_db.localDeletionEntity.ownerId.equals(ownerId));
    return query.map((row) => row.read(_db.localDeletionEntity.remoteId)!).get();
  }

  Future<void> deleteByRemoteIds(Iterable<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    for (final slice in remoteIds.toSet().slices(kDriftMaxChunk)) {
      await (_db.delete(_db.localDeletionEntity)..where((row) => row.remoteId.isIn(slice))).go();
    }
  }

  /// Drops intents whose remote asset is already in the server trash
  Future<void> pruneAlreadyTrashed() {
    final trashedRemotes = _db.remoteAssetEntity.selectOnly()
      ..addColumns([_db.remoteAssetEntity.id])
      ..where(_db.remoteAssetEntity.deletedAt.isNotNull());
    return (_db.delete(_db.localDeletionEntity)..where((row) => row.remoteId.isInQuery(trashedRemotes))).go();
  }

  /// Drops intents of [ownerId] whose content is still on the device, e.g. restored or moved copies
  Future<void> pruneRestored(String ownerId) {
    return (_db.delete(_db.localDeletionEntity)..where(
          (row) =>
              row.ownerId.equals(ownerId) &
              existsQuery(
                _db.localAssetEntity.selectOnly()
                  ..addColumns([_db.localAssetEntity.id])
                  ..where(_db.localAssetEntity.checksum.equalsExp(row.checksum)),
              ),
        ))
        .go();
  }

  /// Marks app-initiated local deletions, which keep the remote copy, so the deletion sync skips them
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

  /// The subset of [localIds] that are marked as excluded
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

  /// Captures the backed-up assets of [ownerId] into a temp table, so deletions can be detected after the
  /// reconciliation removed their rows
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

  /// Queues the snapshot rows whose local asset is gone and drops the exclusions of assets that no longer exist
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
      await (_db.delete(_db.localDeletionExclusionEntity)..where(
            (row) => row.localId.isNotInQuery(_db.localAssetEntity.selectOnly()..addColumns([_db.localAssetEntity.id])),
          ))
          .go();
      await _db.customStatement('DELETE FROM local_deletion_snapshot');
    });
  }

  Future<void> _createSnapshotTable() {
    return _db.customStatement(
      'CREATE TEMP TABLE IF NOT EXISTS local_deletion_snapshot '
      '(local_id TEXT NOT NULL PRIMARY KEY, remote_id TEXT NOT NULL, checksum TEXT NOT NULL)',
    );
  }

  /// Clears the queue and all exclusions
  Future<void> deleteAll() {
    return _db.transaction(() async {
      await _db.delete(_db.localDeletionEntity).go();
      await _db.delete(_db.localDeletionExclusionEntity).go();
    });
  }
}
