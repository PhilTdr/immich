import 'dart:convert';
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
const _kIosSharedAlbumAssetIds = '''
  SELECT laa.asset_id FROM local_album_asset_entity laa
  INNER JOIN local_album_entity al ON al.id = laa.album_id
  WHERE al.is_ios_shared_album = 1
''';

/// The album of each local asset that matches [assetFilter], see [LocalDeletionRepository.getBackedUp]. The first
/// variable is the JSON array of the smart album ids
String _listingAlbumsSql(String assetFilter) =>
    '''
  SELECT asset_id, album_id, album_name FROM (
    SELECT laa.asset_id AS asset_id, laa.album_id AS album_id, al.name AS album_name, ROW_NUMBER() OVER (
      PARTITION BY laa.asset_id
      ORDER BY smart.value IS NOT NULL,
        CASE WHEN smart.value IS NULL THEN album_size.c ELSE -album_size.c END,
        laa.album_id
    ) AS pos
    FROM local_album_asset_entity laa
    INNER JOIN local_album_entity al ON al.id = laa.album_id
    INNER JOIN (SELECT album_id, COUNT(*) AS c FROM local_album_asset_entity GROUP BY album_id) album_size
      ON album_size.album_id = laa.album_id
    LEFT JOIN json_each(?) smart ON smart.value = laa.album_id
    WHERE $assetFilter
  ) WHERE pos = 1
''';

typedef PendingDeletion = ({
  String remoteId,
  String? name,
  String? thumbHash,
  DateTime createdAt,
  String? albumId,
  String? albumName,
  bool awaitingConfirmation,
});
typedef SnapshotCandidate = ({
  String localId,
  String remoteId,
  String checksum,
  bool inIosSharedAlbum,
  String? albumId,
  String? albumName,
});

/// A deletion to queue, by remote id: the checksum of the deleted file and the album it is listed under, see
/// [LocalDeletionRepository.getBackedUp]
typedef DeletedAsset = ({String checksum, String? albumId, String? albumName});

@DriftAccessor()
class LocalDeletionRepository extends DatabaseAccessor<Drift> with $LocalDeletionRepositoryMixin {
  LocalDeletionRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  /// Queues [deletions] of [ownerId] pending a server move-to-trash. A flushed deletion of the same asset is replaced,
  /// so a file that came back and was deleted again settles anew
  Future<void> upsert(String ownerId, Map<String, DeletedAsset> deletions, {bool awaitingConfirmation = false}) async {
    if (deletions.isEmpty) {
      return;
    }

    await _db.batch((batch) {
      for (final slice in deletions.keys.slices(kDriftMaxChunk)) {
        batch.deleteWhere(_db.localDeletionEntity, (row) => row.remoteId.isIn(slice) & row.trashedAt.isNotNull());
      }
      for (final MapEntry(key: remoteId, value: deleted) in deletions.entries) {
        final companion = LocalDeletionEntityCompanion.insert(
          remoteId: remoteId,
          checksum: deleted.checksum,
          ownerId: ownerId,
          albumId: Value(deleted.albumId),
          albumName: Value(deleted.albumName),
          awaitingConfirmation: Value(awaitingConfirmation),
        );
        batch.insert(_db.localDeletionEntity, companion, onConflict: DoUpdate((_) => companion));
      }
    });
  }

  /// The backed-up copies of [localIds] by remote id: the user's own uploads that are not trashed, hidden or locked,
  /// never partner or external library assets that share a checksum. Like free up space, assets of iOS shared albums
  /// are left out unless [includeIosSharedAlbums], they also vanish when another member removes them from the album.
  /// Each one is listed under the smallest album it is in, so an album deleted as a whole shows by its name. Assets
  /// that are only in [smartAlbumIds] go to the largest of these, which is Recents on iOS
  Future<Map<String, DeletedAsset>> getBackedUp(
    String ownerId,
    Iterable<String> localIds, {
    bool includeIosSharedAlbums = false,
    Iterable<String> smartAlbumIds = const [],
  }) async {
    final result = <String, DeletedAsset>{};
    for (final slice in localIds.toSet().slices(kDriftMaxChunk)) {
      final query = _db.localAssetEntity.selectOnly()
        ..addColumns([_db.localAssetEntity.id, _db.remoteAssetEntity.id, _db.remoteAssetEntity.checksum])
        ..join([_backedUpCopy(ownerId)])
        ..where(_db.localAssetEntity.id.isIn(slice));
      if (!includeIosSharedAlbums) {
        query.where(_db.localAssetEntity.id.isNotInQuery(_iosSharedAlbumAssets()));
      }
      final rows = await query.get();
      final albums = await _getListingAlbums(rows.map((row) => row.read(_db.localAssetEntity.id)!), smartAlbumIds);
      for (final row in rows) {
        final album = albums[row.read(_db.localAssetEntity.id)!];
        result[row.read(_db.remoteAssetEntity.id)!] = (
          checksum: row.read(_db.remoteAssetEntity.checksum)!,
          albumId: album?.id,
          albumName: album?.name,
        );
      }
    }
    return result;
  }

  /// The album that each of [localIds] is listed under, see [getBackedUp]
  Future<Map<String, ({String id, String name})>> _getListingAlbums(
    Iterable<String> localIds,
    Iterable<String> smartAlbumIds,
  ) async {
    final rows = await _db
        .customSelect(
          _listingAlbumsSql('laa.asset_id IN (SELECT value FROM json_each(?))'),
          variables: [
            Variable.withString(jsonEncode(smartAlbumIds.toList())),
            Variable.withString(jsonEncode(localIds.toList())),
          ],
        )
        .get();
    return {
      for (final row in rows)
        row.read<String>('asset_id'): (id: row.read<String>('album_id'), name: row.read<String>('album_name')),
    };
  }

  Join _backedUpCopy(String ownerId) => innerJoin(
    _db.remoteAssetEntity,
    _db.remoteAssetEntity.checksum.equalsExp(_db.localAssetEntity.checksum) &
        _db.remoteAssetEntity.ownerId.equals(ownerId) &
        _db.remoteAssetEntity.deletedAt.isNull() &
        _db.remoteAssetEntity.libraryId.isNull() &
        _db.remoteAssetEntity.visibility.isNotInValues(const [AssetVisibility.hidden, AssetVisibility.locked]),
    useColumns: false,
  );

  BaseSelectStatement _iosSharedAlbumAssets() => _db.localAlbumAssetEntity.selectOnly()
    ..addColumns([_db.localAlbumAssetEntity.assetId])
    ..join([
      innerJoin(
        _db.localAlbumEntity,
        _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id),
        useColumns: false,
      ),
    ])
    ..where(_db.localAlbumEntity.isIosSharedAlbum.equals(true));

  /// The remote ids of the intents of [ownerId] that were queued before [settledBefore] and do not await confirmation
  Future<List<String>> getPending(String ownerId, {required DateTime settledBefore}) {
    final query = _db.localDeletionEntity.selectOnly()
      ..addColumns([_db.localDeletionEntity.remoteId])
      ..where(
        _db.localDeletionEntity.ownerId.equals(ownerId) &
            _db.localDeletionEntity.trashedAt.isNull() &
            _db.localDeletionEntity.awaitingConfirmation.equals(false) &
            _db.localDeletionEntity.createdAt.isSmallerThanValue(settledBefore),
      );
    return query.map((row) => row.read(_db.localDeletionEntity.remoteId)!).get();
  }

  /// Watches the pending deletions of [ownerId] together with their remote asset
  Stream<List<PendingDeletion>> watchPending(String ownerId) {
    final deletion = _db.localDeletionEntity;
    final remote = _db.remoteAssetEntity;
    final query = _db.selectOnly(deletion).join([leftOuterJoin(remote, remote.id.equalsExp(deletion.remoteId))])
      ..addColumns([
        deletion.remoteId,
        deletion.createdAt,
        deletion.albumId,
        deletion.albumName,
        deletion.awaitingConfirmation,
        remote.name,
        remote.thumbHash,
      ])
      ..where(deletion.ownerId.equals(ownerId) & deletion.trashedAt.isNull())
      ..orderBy([OrderingTerm.asc(deletion.createdAt)]);
    return query
        .map(
          (row) => (
            remoteId: row.read(deletion.remoteId)!,
            name: row.read(remote.name),
            thumbHash: row.read(remote.thumbHash),
            createdAt: row.read(deletion.createdAt)!,
            albumId: row.read(deletion.albumId),
            albumName: row.read(deletion.albumName),
            awaitingConfirmation: row.read(deletion.awaitingConfirmation)!,
          ),
        )
        .watch();
  }

  /// Whether deletions of [ownerId] await the user's confirmation, which holds back the whole queue
  Future<bool> hasAwaitingConfirmation(String ownerId) {
    final query = _db.localDeletionEntity.selectOnly()
      ..addColumns([_db.localDeletionEntity.remoteId])
      ..where(
        _db.localDeletionEntity.ownerId.equals(ownerId) &
            _db.localDeletionEntity.trashedAt.isNull() &
            _db.localDeletionEntity.awaitingConfirmation.equals(true),
      )
      ..limit(1);
    return query.get().then((rows) => rows.isNotEmpty);
  }

  /// Makes the pending deletions among [remoteIds] await the user's confirmation
  Future<void> holdForConfirmation(Iterable<String> remoteIds) =>
      _setAwaitingConfirmation(remoteIds, awaitingConfirmation: true);

  /// Releases the deletions among [remoteIds] that await confirmation to the server trash
  Future<void> confirm(Iterable<String> remoteIds) => _setAwaitingConfirmation(remoteIds, awaitingConfirmation: false);

  Future<void> _setAwaitingConfirmation(Iterable<String> remoteIds, {required bool awaitingConfirmation}) async {
    for (final slice in remoteIds.toSet().slices(kDriftMaxChunk)) {
      await (_db.update(_db.localDeletionEntity)..where((row) => row.remoteId.isIn(slice) & row.trashedAt.isNull()))
          .write(LocalDeletionEntityCompanion(awaitingConfirmation: Value(awaitingConfirmation)));
    }
  }

  /// Drops the deletions among [remoteIds] that await confirmation, so their server copies are kept
  Future<void> discard(Iterable<String> remoteIds) async {
    for (final slice in remoteIds.toSet().slices(kDriftMaxChunk)) {
      await (_db.delete(_db.localDeletionEntity)
            ..where((row) => row.remoteId.isIn(slice) & row.trashedAt.isNull() & row.awaitingConfirmation.equals(true)))
          .go();
    }
  }

  Future<void> deleteByRemoteIds(Iterable<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    for (final slice in remoteIds.toSet().slices(kDriftMaxChunk)) {
      await (_db.delete(_db.localDeletionEntity)..where((row) => row.remoteId.isIn(slice))).go();
    }
  }

  /// Drops pending intents whose remote asset is already in the server trash
  Future<void> pruneAlreadyTrashed() {
    return (_db.delete(_db.localDeletionEntity)..where(
          (row) =>
              row.trashedAt.isNull() &
              existsQuery(
                _db.remoteAssetEntity.selectOnly()
                  ..addColumns([_db.remoteAssetEntity.id])
                  ..where(
                    _db.remoteAssetEntity.id.equalsExp(row.remoteId) & _db.remoteAssetEntity.deletedAt.isNotNull(),
                  ),
              ),
        ))
        .go();
  }

  /// Drops pending intents of [ownerId] whose content is still on the device, e.g. restored or moved copies
  Future<void> pruneRestored(String ownerId) {
    return (_db.delete(_db.localDeletionEntity)..where(
          (row) =>
              row.ownerId.equals(ownerId) &
              row.trashedAt.isNull() &
              existsQuery(
                _db.localAssetEntity.selectOnly()
                  ..addColumns([_db.localAssetEntity.id])
                  ..where(_db.localAssetEntity.checksum.equalsExp(row.checksum)),
              ),
        ))
        .go();
  }

  /// Marks the given deletions as flushed. They stay while their server copy is in the trash, see [getRestored]
  Future<void> markTrashed(Iterable<String> remoteIds) async {
    for (final slice in remoteIds.toSet().slices(kDriftMaxChunk)) {
      await (_db.update(_db.localDeletionEntity)..where((row) => row.remoteId.isIn(slice))).write(
        LocalDeletionEntityCompanion(trashedAt: Value(DateTime.now())),
      );
    }
  }

  /// The flushed deletions of [ownerId] whose content is back on the device while their server copy is still in the
  /// trash, e.g. a file restored from the device trash
  Future<List<String>> getRestored(String ownerId) {
    final deletion = _db.localDeletionEntity;
    final remote = _db.remoteAssetEntity;
    final query =
        _db.selectOnly(deletion).join([innerJoin(remote, remote.id.equalsExp(deletion.remoteId), useColumns: false)])
          ..addColumns([deletion.remoteId])
          ..where(
            deletion.ownerId.equals(ownerId) &
                deletion.trashedAt.isNotNull() &
                remote.deletedAt.isNotNull() &
                existsQuery(
                  _db.localAssetEntity.selectOnly()
                    ..addColumns([_db.localAssetEntity.id])
                    ..where(_db.localAssetEntity.checksum.equalsExp(deletion.checksum)),
                ),
          );
    return query.map((row) => row.read(deletion.remoteId)!).get();
  }

  /// Drops the flushed deletions whose server copy left the trash, restored or permanently deleted
  Future<void> pruneFlushed() {
    return (_db.delete(_db.localDeletionEntity)..where(
          (row) =>
              row.trashedAt.isNotNull() &
              notExistsQuery(
                _db.remoteAssetEntity.selectOnly()
                  ..addColumns([_db.remoteAssetEntity.id])
                  ..where(
                    _db.remoteAssetEntity.id.equalsExp(row.remoteId) & _db.remoteAssetEntity.deletedAt.isNotNull(),
                  ),
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

  /// The checksum, type and file size of the remote asset of the given pending deletions, by remote id. Deletions
  /// whose remote asset has no file size yet are left out
  Future<Map<String, ({String checksum, int type, int fileSize})>> getPendingFileSizes(
    Iterable<String> remoteIds,
  ) async {
    final deletion = _db.localDeletionEntity;
    final remote = _db.remoteAssetEntity;
    final exif = _db.remoteExifEntity;
    final result = <String, ({String checksum, int type, int fileSize})>{};
    for (final slice in remoteIds.toSet().slices(kDriftMaxChunk)) {
      final query =
          _db.selectOnly(deletion).join([
              innerJoin(remote, remote.id.equalsExp(deletion.remoteId), useColumns: false),
              innerJoin(exif, exif.assetId.equalsExp(deletion.remoteId), useColumns: false),
            ])
            ..addColumns([deletion.remoteId, deletion.checksum, remote.type, exif.fileSize])
            ..where(deletion.remoteId.isIn(slice) & exif.fileSize.isNotNull());
      for (final row in await query.get()) {
        result[row.read(deletion.remoteId)!] = (
          checksum: row.read(deletion.checksum)!,
          type: row.read(remote.type)!,
          fileSize: row.read(exif.fileSize)!,
        );
      }
    }
    return result;
  }

  /// The type of those of [localIds] that have no checksum yet, by local id
  Future<Map<String, int>> getUnhashedByIds(Iterable<String> localIds) async {
    final local = _db.localAssetEntity;
    final result = <String, int>{};
    for (final slice in localIds.toSet().slices(kDriftMaxChunk)) {
      final query = local.selectOnly()
        ..addColumns([local.id, local.type])
        ..where(local.id.isIn(slice) & local.checksum.isNull());
      for (final row in await query.get()) {
        result[row.read(local.id)!] = row.read(local.type)!;
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

  /// Captures the backed-up assets of [ownerId] with their album, as in [getBackedUp], into a temp table, so deletions
  /// can be detected after the reconciliation removed their rows. Every engine shares the connection, so each sync gets
  /// its own snapshot id
  Future<int> snapshotBackedUpAssets(
    String ownerId, {
    bool includeIosSharedAlbums = false,
    Iterable<String> smartAlbumIds = const [],
  }) {
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
        INSERT INTO local_deletion_snapshot
          (snapshot_id, local_id, remote_id, checksum, in_ios_shared_album, album_id, album_name)
        SELECT ?, la.id, ra.id, la.checksum, la.id IN ($_kIosSharedAlbumAssetIds), listing.album_id, listing.album_name
        FROM local_asset_entity la
        INNER JOIN remote_asset_entity ra ON ra.checksum = la.checksum
        LEFT JOIN (${_listingAlbumsSql('laa.asset_id IN (SELECT id FROM local_asset_entity WHERE checksum IS NOT NULL)')})
          listing ON listing.asset_id = la.id
        WHERE ra.owner_id = ? AND ra.deleted_at IS NULL AND ra.library_id IS NULL
          AND ra.visibility NOT IN (?, ?)
          AND (? OR la.id NOT IN ($_kIosSharedAlbumAssetIds))
      ''',
        [
          snapshotId,
          jsonEncode(smartAlbumIds.toList()),
          ownerId,
          AssetVisibility.hidden.index,
          AssetVisibility.locked.index,
          if (includeIosSharedAlbums) 1 else 0,
        ],
      );
      return snapshotId;
    });
  }

  /// The rows of [snapshotId] whose local asset is gone and that are not excluded
  Future<List<SnapshotCandidate>> getSnapshotDeletionCandidates(int snapshotId) {
    return _db.transaction(() async {
      await _createSnapshotTable();
      final rows = await _db
          .customSelect(
            '''
        SELECT s.local_id AS local_id, s.remote_id AS remote_id, s.checksum AS checksum,
          s.in_ios_shared_album AS in_ios_shared_album, s.album_id AS album_id, s.album_name AS album_name
        FROM local_deletion_snapshot s
        WHERE s.snapshot_id = ?
          AND NOT EXISTS (SELECT 1 FROM local_asset_entity la WHERE la.id = s.local_id)
          AND NOT EXISTS (SELECT 1 FROM local_deletion_exclusion_entity ex WHERE ex.local_id = s.local_id)
      ''',
            variables: [Variable.withInt(snapshotId)],
          )
          .get();
      return rows
          .map(
            (r) => (
              localId: r.read<String>('local_id'),
              remoteId: r.read<String>('remote_id'),
              checksum: r.read<String>('checksum'),
              inIosSharedAlbum: r.read<bool>('in_ios_shared_album'),
              albumId: r.read<String?>('album_id'),
              albumName: r.read<String?>('album_name'),
            ),
          )
          .toList();
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
      'local_id TEXT NOT NULL, remote_id TEXT NOT NULL, checksum TEXT NOT NULL, in_ios_shared_album INTEGER NOT NULL, '
      'album_id TEXT, album_name TEXT, PRIMARY KEY (snapshot_id, local_id))',
    );
  }

  /// Clears the queue but keeps the exclusions, so app-initiated deletions stay skipped if the sync is enabled again
  Future<void> clearQueue() {
    return _db.delete(_db.localDeletionEntity).go();
  }

  /// Clears the deletions that were not sent yet, but keeps the flushed ones so their server copies are still restored
  /// when the files come back
  Future<void> clearPending() {
    return (_db.delete(_db.localDeletionEntity)..where((row) => row.trashedAt.isNull())).go();
  }
}
