import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/dao/local_deletion.drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/deletion.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/deletion_exclusion.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/local_deletion.model.dart';

typedef BackedUpAsset = ({
  String localId,
  String remoteId,
  String checksum,
  String name,
  bool inIosSharedAlbum,
  String? albumId,
  String? albumName,
});

@DriftAccessor()
class LocalDeletionRepository extends DatabaseAccessor<Drift> with $LocalDeletionRepositoryMixin {
  LocalDeletionRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  Expression<bool> get _inServerTrash => existsQuery(
    _db.remoteAssetEntity.selectOnly()
      ..addColumns([_db.remoteAssetEntity.id])
      ..where(
        _db.remoteAssetEntity.id.equalsExp(_db.localDeletionEntity.remoteId) &
            _db.remoteAssetEntity.deletedAt.isNotNull(),
      ),
  );

  Expression<bool> get _inBackupAlbum => existsQuery(
    _db.localAssetEntity.selectOnly()
      ..addColumns([_db.localAssetEntity.id])
      ..where(
        _db.localAssetEntity.checksum.equalsExp(_db.localDeletionEntity.checksum) &
            existsQuery(
              _db.localAlbumAssetEntity.selectOnly()
                ..addColumns([_db.localAlbumAssetEntity.assetId])
                ..join([
                  innerJoin(_db.localAlbumEntity, _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id)),
                ])
                ..where(
                  _db.localAlbumAssetEntity.assetId.equalsExp(_db.localAssetEntity.id) &
                      _db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.selected),
                ),
            ),
      ),
  );

  Future<void> upsert(String ownerId, Iterable<BackedUpAsset> assets, {bool awaitingConfirmation = false}) async {
    if (assets.isEmpty) {
      return;
    }

    await _db.batch((batch) {
      // A deletion that was sent already is queued anew
      for (final slice in assets.map((asset) => asset.remoteId).slices(kDriftMaxChunk)) {
        batch.deleteWhere(_db.localDeletionEntity, (row) => row.remoteId.isIn(slice) & row.trashedAt.isNotNull());
      }
      for (final asset in assets) {
        final companion = LocalDeletionEntityCompanion.insert(
          remoteId: asset.remoteId,
          checksum: asset.checksum,
          ownerId: ownerId,
          albumId: Value(asset.albumId),
          albumName: Value(asset.albumName),
          awaitingConfirmation: Value(awaitingConfirmation),
        );
        batch.insert(_db.localDeletionEntity, companion, onConflict: DoUpdate((_) => companion));
      }
    });
  }

  Future<List<BackedUpAsset>> getBackedUp(
    String ownerId,
    Iterable<String> localIds, {
    bool includeIosSharedAlbums = false,
    Iterable<String> smartAlbumIds = const [],
  }) async {
    // Each asset is listed under its smallest album, or under its largest smart album if it is in no other
    const sql = '''
      WITH ios_shared AS (
        SELECT laa.asset_id
        FROM local_album_asset_entity laa
        INNER JOIN local_album_entity la ON la.id = laa.album_id
        WHERE la.is_ios_shared_album = 1
      )
      SELECT
        lae.id AS local_id,
        rae.id AS remote_id,
        lae.checksum,
        lae.name,
        lae.id IN (SELECT asset_id FROM ios_shared) AS in_ios_shared_album,
        listing.album_id,
        listing.album_name
      FROM local_asset_entity lae
      CROSS JOIN remote_asset_entity rae ON rae.checksum = lae.checksum
      LEFT JOIN (
        SELECT laa.asset_id, laa.album_id, la.name AS album_name, ROW_NUMBER() OVER (
          PARTITION BY laa.asset_id
          ORDER BY smart.value IS NOT NULL,
            CASE WHEN smart.value IS NULL THEN album_size.c ELSE -album_size.c END,
            laa.album_id
        ) AS pos
        FROM local_album_asset_entity laa
        INNER JOIN local_album_entity la ON la.id = laa.album_id
        INNER JOIN (SELECT album_id, COUNT(*) AS c FROM local_album_asset_entity GROUP BY album_id) album_size
          ON album_size.album_id = laa.album_id
        LEFT JOIN json_each(?3) smart ON smart.value = laa.album_id
        WHERE laa.asset_id IN (SELECT value FROM json_each(?1))
      ) listing ON listing.asset_id = lae.id AND listing.pos = 1
      WHERE lae.id IN (SELECT value FROM json_each(?1))
        AND lae.id NOT IN (SELECT local_id FROM local_deletion_exclusion_entity)
        AND rae.owner_id = ?2
        AND rae.deleted_at IS NULL
        AND rae.library_id IS NULL
        AND rae.visibility NOT IN (?4, ?5)
        AND (?6 OR lae.id NOT IN (SELECT asset_id FROM ios_shared))
        AND EXISTS (
          SELECT 1
          FROM local_album_asset_entity laa
          INNER JOIN local_album_entity la ON la.id = laa.album_id
          WHERE laa.asset_id = lae.id AND la.backup_selection = ?7
        )
    ''';

    final rows = await _db
        .customSelect(
          sql,
          variables: [
            Variable.withString(jsonEncode(localIds.toList())),
            Variable.withString(ownerId),
            Variable.withString(jsonEncode(smartAlbumIds.toList())),
            Variable.withInt(AssetVisibility.hidden.index),
            Variable.withInt(AssetVisibility.locked.index),
            Variable.withBool(includeIosSharedAlbums),
            Variable.withInt(BackupSelection.selected.index),
          ],
          readsFrom: {
            _db.localAssetEntity,
            _db.remoteAssetEntity,
            _db.localAlbumAssetEntity,
            _db.localAlbumEntity,
            _db.localDeletionExclusionEntity,
          },
        )
        .get();

    return rows
        .map(
          (row) => (
            localId: row.read<String>('local_id'),
            remoteId: row.read<String>('remote_id'),
            checksum: row.read<String>('checksum'),
            name: row.read<String>('name'),
            inIosSharedAlbum: row.read<bool>('in_ios_shared_album'),
            albumId: row.read<String?>('album_id'),
            albumName: row.read<String?>('album_name'),
          ),
        )
        .toList();
  }

  Future<List<String>> getToTrash(String ownerId, {required DateTime settledBefore}) {
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
          (row) => PendingDeletion(
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

  Future<bool> hasAwaitingConfirmation(String ownerId) {
    return _db.managers.localDeletionEntity
        .filter((e) => e.ownerId.equals(ownerId) & e.trashedAt.isNull() & e.awaitingConfirmation.equals(true))
        .exists();
  }

  Future<void> holdForConfirmation(Iterable<String> remoteIds) =>
      _setAwaitingConfirmation(remoteIds, awaitingConfirmation: true);

  Future<void> confirm(Iterable<String> remoteIds) => _setAwaitingConfirmation(remoteIds, awaitingConfirmation: false);

  Future<void> _setAwaitingConfirmation(Iterable<String> remoteIds, {required bool awaitingConfirmation}) async {
    for (final slice in remoteIds.slices(kDriftMaxChunk)) {
      await (_db.update(_db.localDeletionEntity)..where((row) => row.remoteId.isIn(slice) & row.trashedAt.isNull()))
          .write(LocalDeletionEntityCompanion(awaitingConfirmation: Value(awaitingConfirmation)));
    }
  }

  Future<void> deleteByRemoteIds(Iterable<String> remoteIds) async {
    for (final slice in remoteIds.slices(kDriftMaxChunk)) {
      await (_db.delete(_db.localDeletionEntity)..where((row) => row.remoteId.isIn(slice))).go();
    }
  }

  /// Drops pending deletions whose server copy is already trashed or whose file is still in a backup album,
  /// and sent ones whose server copy left the trash.
  Future<void> prune(String ownerId) {
    return (_db.delete(_db.localDeletionEntity)..where(
          (row) =>
              row.ownerId.equals(ownerId) &
              ((row.trashedAt.isNull() & (_inServerTrash | _inBackupAlbum)) |
                  (row.trashedAt.isNotNull() & _inServerTrash.not())),
        ))
        .go();
  }

  Future<void> markTrashed(Iterable<String> remoteIds) async {
    for (final slice in remoteIds.slices(kDriftMaxChunk)) {
      await (_db.update(_db.localDeletionEntity)..where((row) => row.remoteId.isIn(slice))).write(
        LocalDeletionEntityCompanion(trashedAt: Value(DateTime.now())),
      );
    }
  }

  Future<List<String>> getToRestore(String ownerId) {
    final deletion = _db.localDeletionEntity;
    final query = deletion.selectOnly()
      ..addColumns([deletion.remoteId])
      ..where(deletion.ownerId.equals(ownerId) & deletion.trashedAt.isNotNull() & _inServerTrash & _inBackupAlbum);
    return query.map((row) => row.read(deletion.remoteId)!).get();
  }

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
    for (final slice in localIds.slices(kDriftMaxChunk)) {
      await (_db.delete(_db.localDeletionExclusionEntity)..where((row) => row.localId.isIn(slice))).go();
    }
  }

  Future<void> deleteExclusionsOfRemovedAssets() {
    return (_db.delete(_db.localDeletionExclusionEntity)..where(
          (row) => row.localId.isNotInQuery(_db.localAssetEntity.selectOnly()..addColumns([_db.localAssetEntity.id])),
        ))
        .go();
  }

  Future<void> clearQueue() {
    return _db.delete(_db.localDeletionEntity).go();
  }

  Future<void> clearPending() {
    return (_db.delete(_db.localDeletionEntity)..where((row) => row.trashedAt.isNull())).go();
  }
}
