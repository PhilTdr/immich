import 'dart:math';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/deletion.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.drift.dart';

const Duration _kStaleSnapshotAge = Duration(hours: 1);
const _kNotInAnySnapshot = CustomExpression<bool>('local_id NOT IN (SELECT local_id FROM local_deletion_snapshot)');

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
    return (_db.delete(_db.localDeletionEntity)..where(
          (row) => existsQuery(
            _db.remoteAssetEntity.selectOnly()
              ..addColumns([_db.remoteAssetEntity.id])
              ..where(_db.remoteAssetEntity.id.equalsExp(row.remoteId) & _db.remoteAssetEntity.deletedAt.isNotNull()),
          ),
        ))
        .go();
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

  /// The files without checksum that share name and type with the remote asset of the given pending deletions, by
  /// remote id and with the checksum of the deleted file. Such a file can be a copy that was moved into a folder that
  /// is not backed up
  Future<Map<String, ({String checksum, List<String> localIds})>> getMoveCandidates(Iterable<String> remoteIds) async {
    final deletion = _db.localDeletionEntity;
    final remote = _db.remoteAssetEntity;
    final pending = <({String name, int type}), List<({String remoteId, String checksum})>>{};
    for (final slice in remoteIds.toSet().slices(kDriftMaxChunk)) {
      final query =
          _db.selectOnly(deletion).join([innerJoin(remote, remote.id.equalsExp(deletion.remoteId), useColumns: false)])
            ..addColumns([deletion.remoteId, deletion.checksum, remote.name, remote.type])
            ..where(deletion.remoteId.isIn(slice));
      for (final row in await query.get()) {
        final key = (name: row.read(remote.name)!, type: row.read(remote.type)!);
        (pending[key] ??= []).add((remoteId: row.read(deletion.remoteId)!, checksum: row.read(deletion.checksum)!));
      }
    }

    // A single pass over the unhashed assets, a join would scan them once per pending deletion
    final local = _db.localAssetEntity;
    final result = <String, ({String checksum, List<String> localIds})>{};
    for (final slice in pending.keys.map((key) => key.name).toSet().slices(kDriftMaxChunk)) {
      final query = local.selectOnly()
        ..addColumns([local.id, local.name, local.type])
        ..where(local.checksum.isNull() & local.name.isIn(slice));
      for (final row in await query.get()) {
        final key = (name: row.read(local.name)!, type: row.read(local.type)!);
        for (final deleted in pending[key] ?? const <({String remoteId, String checksum})>[]) {
          (result[deleted.remoteId] ??= (checksum: deleted.checksum, localIds: [])).localIds.add(row.read(local.id)!);
        }
      }
    }
    return result;
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

  /// Drops the exclusions of [localIds] whose rows are gone, unless a snapshot still needs them to skip the asset
  Future<void> consumeExcluded(Iterable<String> localIds) async {
    if (localIds.isEmpty) {
      return;
    }

    await _db.transaction(() async {
      await _createSnapshotTable();
      for (final slice in localIds.toSet().slices(kDriftMaxChunk)) {
        await (_db.delete(
          _db.localDeletionExclusionEntity,
        )..where((row) => row.localId.isIn(slice) & _kNotInAnySnapshot)).go();
      }
    });
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
  /// reconciliation removed their rows. Every engine shares the connection, so each sync gets its own snapshot id
  Future<int> snapshotBackedUpAssets(String ownerId) {
    return _db.transaction(() async {
      await _createSnapshotTable();
      // The id is the creation time, so the snapshots of syncs that never reached their detection expire
      final now = DateTime.now().microsecondsSinceEpoch;
      await _db.customStatement('DELETE FROM local_deletion_snapshot WHERE snapshot_id < ?', [
        now - _kStaleSnapshotAge.inMicroseconds,
      ]);
      final last = await _db
          .customSelect('SELECT COALESCE(MAX(snapshot_id), 0) AS id FROM local_deletion_snapshot')
          .getSingle();
      final snapshotId = max(now, last.read<int>('id') + 1);
      await _db.customStatement(
        '''
        INSERT INTO local_deletion_snapshot (snapshot_id, local_id, remote_id, checksum)
        SELECT ?, la.id, ra.id, la.checksum
        FROM local_asset_entity la
        INNER JOIN remote_asset_entity ra ON ra.checksum = la.checksum
        WHERE ra.owner_id = ? AND ra.deleted_at IS NULL AND ra.library_id IS NULL
          AND ra.visibility NOT IN (?, ?)
      ''',
        [snapshotId, ownerId, AssetVisibility.hidden.index, AssetVisibility.locked.index],
      );
      return snapshotId;
    });
  }

  /// The rows of [snapshotId] whose local asset is gone and that are not excluded, with the snapshot size so the
  /// caller can tell a whole volume disappearing apart from deletions
  Future<({List<({String localId, String remoteId, String checksum})> candidates, int total})>
  getSnapshotDeletionCandidates(int snapshotId) {
    return _db.transaction(() async {
      await _createSnapshotTable();
      final rows = await _db
          .customSelect(
            '''
        SELECT s.local_id AS local_id, s.remote_id AS remote_id, s.checksum AS checksum
        FROM local_deletion_snapshot s
        WHERE s.snapshot_id = ?
          AND NOT EXISTS (SELECT 1 FROM local_asset_entity la WHERE la.id = s.local_id)
          AND NOT EXISTS (SELECT 1 FROM local_deletion_exclusion_entity ex WHERE ex.local_id = s.local_id)
      ''',
            variables: [Variable.withInt(snapshotId)],
          )
          .get();
      final total = await _db
          .customSelect(
            'SELECT COUNT(*) AS c FROM local_deletion_snapshot WHERE snapshot_id = ?',
            variables: [Variable.withInt(snapshotId)],
          )
          .getSingle();
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

  /// Clears [snapshotId] and drops the exclusions of assets that no longer exist, unless another snapshot still
  /// needs them to skip the asset
  Future<void> clearSnapshotAndConsumeExclusions(int snapshotId) {
    return _db.transaction(() async {
      await _createSnapshotTable();
      await _db.customStatement('DELETE FROM local_deletion_snapshot WHERE snapshot_id = ?', [snapshotId]);
      await (_db.delete(_db.localDeletionExclusionEntity)..where(
            (row) =>
                row.localId.isNotInQuery(_db.localAssetEntity.selectOnly()..addColumns([_db.localAssetEntity.id])) &
                _kNotInAnySnapshot,
          ))
          .go();
    });
  }

  Future<void> _createSnapshotTable() {
    return _db.customStatement(
      'CREATE TEMP TABLE IF NOT EXISTS local_deletion_snapshot (snapshot_id INTEGER NOT NULL, '
      'local_id TEXT NOT NULL, remote_id TEXT NOT NULL, checksum TEXT NOT NULL, PRIMARY KEY (snapshot_id, local_id))',
    );
  }

  /// Clears the queue but keeps the exclusions, so app-initiated deletions stay skipped if the sync is enabled again
  Future<void> clearQueue() {
    return _db.delete(_db.localDeletionEntity).go();
  }
}
