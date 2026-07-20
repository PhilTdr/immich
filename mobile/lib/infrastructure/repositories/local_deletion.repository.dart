import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/deletion.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.drift.dart';

typedef PendingDeletion = ({String remoteId, String? name, String? thumbHash, DateTime createdAt});

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
  /// hidden or locked, never partner or external library assets that share a checksum
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
                _db.remoteAssetEntity.libraryId.isNull() &
                _db.remoteAssetEntity.visibility.isNotInValues(const [AssetVisibility.hidden, AssetVisibility.locked]),
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

  /// The remote ids of the intents of [ownerId] that were queued before [settledBefore]
  Future<List<String>> getPending(String ownerId, {required DateTime settledBefore}) {
    final query = _db.localDeletionEntity.selectOnly()
      ..addColumns([_db.localDeletionEntity.remoteId])
      ..where(
        _db.localDeletionEntity.ownerId.equals(ownerId) &
            _db.localDeletionEntity.createdAt.isSmallerThanValue(settledBefore),
      );
    return query.map((row) => row.read(_db.localDeletionEntity.remoteId)!).get();
  }

  /// Watches the pending deletions of [ownerId] together with their remote asset
  Stream<List<PendingDeletion>> watchPending(String ownerId) {
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
          AND ra.visibility NOT IN (?, ?)
      ''',
        [ownerId, AssetVisibility.hidden.index, AssetVisibility.locked.index],
      );
    });
  }

  /// The snapshot rows whose local asset is gone and that are not excluded, with the snapshot size so the caller can
  /// tell a whole volume disappearing apart from deletions
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

  /// Drops the exclusions of assets that no longer exist and clears the snapshot
  Future<void> clearSnapshotAndConsumeExclusions() {
    return _db.transaction(() async {
      await _createSnapshotTable();
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

  /// Clears the queue but keeps the exclusions, so app-initiated deletions stay skipped if the sync is enabled again
  Future<void> clearQueue() {
    return _db.delete(_db.localDeletionEntity).go();
  }
}
