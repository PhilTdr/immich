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

    final now = DateTime.now();
    await _db.batch((batch) {
      for (final entry in remoteIdToChecksum.entries) {
        batch.insert(
          _db.localDeletionEntity,
          LocalDeletionEntityCompanion.insert(
            remoteId: entry.key,
            checksum: entry.value,
            ownerId: ownerId,
            createdAt: now,
          ),
          // do not update the createdAt value
          onConflict: DoUpdate(
            (_) => LocalDeletionEntityCompanion(checksum: Value(entry.value), ownerId: Value(ownerId)),
          ),
        );
      }
    });
  }

  Future<List<({String remoteId, String checksum, DateTime createdAt})>> getPending(String ownerId) {
    final query = _db.localDeletionEntity.select()..where((row) => row.ownerId.equals(ownerId));
    return query
        .map((row) => (remoteId: row.remoteId, checksum: row.checksum, createdAt: row.createdAt))
        .get();
  }

  /// Watches the pending deletions of [ownerId] together with their mirrored
  /// remote asset.
  Stream<List<({String remoteId, String? name, String? thumbHash, DateTime createdAt})>> watchPending(
    String ownerId,
  ) {
    final deletion = _db.localDeletionEntity;
    final remote = _db.remoteAssetEntity;
    final query = _db.selectOnly(deletion).join([leftOuterJoin(remote, remote.id.equalsExp(deletion.remoteId))])
      ..addColumns([deletion.remoteId, deletion.createdAt, remote.name, remote.thumbHash])
      ..where(deletion.ownerId.equals(ownerId))
      ..orderBy([OrderingTerm.asc(deletion.createdAt)]);
    return query
        .map(
          (row) => (
            remoteId: row.read(deletion.remoteId)!,
            name: row.read(remote.name),
            thumbHash: row.read(remote.thumbHash),
            createdAt: row.read(deletion.createdAt)!,
          ),
        )
        .watch();
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

  /// Returns the snapshot rows whose local asset is gone and that are not
  /// excluded, along with the total snapshot size so the caller can detect a
  /// whole volume disappearing before queuing anything.
  Future<({List<({String localId, String remoteId, String checksum})> candidates, int total})>
  getSnapshotDeletionCandidates() {
    return _db.transaction(() async {
      await _createSnapshotTable();
      final rows = await _db.customSelect('''
        SELECT s.local_id AS local_id, s.remote_id AS remote_id, s.checksum AS checksum
        FROM local_deletion_snapshot s
        WHERE NOT EXISTS (SELECT 1 FROM local_asset_entity la WHERE la.id = s.local_id)
          AND NOT EXISTS (SELECT 1 FROM local_deletion_exclusion_entity ex WHERE ex.local_id = s.local_id)
      ''').get();
      final total = await _db.customSelect('SELECT COUNT(*) AS c FROM local_deletion_snapshot').getSingle();
      final candidates = rows
          .map(
            (r) => (
              localId: r.read<String>('local_id'),
              remoteId: r.read<String>('remote_id'),
              checksum: r.read<String>('checksum'),
            ),
          )
          .toList();
      return (candidates: candidates, total: total.read<int>('c'));
    });
  }

  /// Consumes exclusions of assets that no longer exist and clears the snapshot.
  Future<void> clearSnapshotAndConsumeExclusions() {
    return _db.transaction(() async {
      await _createSnapshotTable();
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
