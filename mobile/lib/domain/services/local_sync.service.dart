import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:immich_mobile/utils/datetime_helpers.dart';
import 'package:immich_mobile/utils/diff.dart';
import 'package:logging/logging.dart';

const String _kSyncCancelledCode = "SYNC_CANCELLED";

class LocalSyncService {
  final DriftLocalAlbumRepository _localAlbumRepository;
  final DriftLocalAssetRepository _localAssetRepository;
  final NativeSyncApi _nativeSyncApi;
  final DriftTrashedLocalAssetRepository _trashedLocalAssetRepository;
  final AssetMediaRepository _assetMediaRepository;
  final IPermissionRepository _permissionRepository;
  final AssetApiRepository _assetApiRepository;
  final RemoteAssetRepository _remoteAssetRepository;
  final DriftLocalDeletionRepository _localDeletionRepository;
  final Completer<void>? _cancellation;
  final Logger _log = Logger("DeviceSyncService");

  LocalSyncService({
    required this._localAlbumRepository,
    required this._localAssetRepository,
    required this._nativeSyncApi,
    required this._trashedLocalAssetRepository,
    required this._assetMediaRepository,
    required this._permissionRepository,
    required this._assetApiRepository,
    required this._remoteAssetRepository,
    required this._localDeletionRepository,
    this._cancellation,
  }) {
    _cancellation?.future.then((_) => _nativeSyncApi.cancelSync().onError(_log.warning));
  }

  bool get _isCancelled => _cancellation?.isCompleted ?? false;

  Future<void> sync({bool full = false}) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      if (CurrentPlatform.isAndroid && Store.get(StoreKey.manageLocalMediaAndroid, false)) {
        final hasPermission = await _permissionRepository.hasManageMediaPermission();
        if (hasPermission) {
          await _syncTrashedAssets();
        } else {
          _log.warning("syncTrashedAssets cannot proceed because MANAGE_MEDIA permission is missing");
        }
      }

      if (CurrentPlatform.isIOS) {
        // final assets = await _localAssetRepository.getEmptyCloudIdAssets();
        // await _mapIosCloudIds(assets);
      }

      if (full || await _nativeSyncApi.shouldFullSync()) {
        _log.fine("Full sync request from ${full ? "user" : "native"}");
        return await fullSync();
      }

      final delta = await _nativeSyncApi.getMediaChanges();
      if (!delta.hasChanges) {
        _log.fine("No media changes detected. Skipping sync");
        return;
      }

      _log.fine("Delta updated: ${delta.updates.length}");
      _log.fine("Delta deleted: ${delta.deletes.length}");

      final deviceAlbums = await _nativeSyncApi.getAlbums();
      await _localAlbumRepository.updateAll(deviceAlbums.toLocalAlbums());
      final newAssets = delta.updates.toLocalAssets();

      // Resolve deleted local assets with their own remote id via checksum.
      // Scoped to the current user so partner/shared assets are never affected.
      final ownerId = _syncLocalDeletionsEnabled ? _currentUserId : null;
      final deletedAssets = ownerId != null
          ? await _localAssetRepository.getByIds(delta.deletes, ownerId: ownerId)
          : const <LocalAsset>[];

      await _localAlbumRepository.processDelta(
        updates: newAssets,
        deletes: delta.deletes,
        assetAlbums: delta.assetAlbums,
      );

      if (ownerId != null) {
        await _localDeletionRepository.deleteForeignRows(ownerId);
        await recordLocallyDeletedFromDelta(deletedAssets, ownerId);
        await flushPendingDeletions(ownerId);
        await restoreLocallyPresentTrashed(ownerId);
      }

      final dbAlbums = await _localAlbumRepository.getAll();
      // On Android, we need to sync all albums since it is not possible to
      // detect album deletions from the native side
      if (CurrentPlatform.isAndroid) {
        for (final album in dbAlbums) {
          if (_isCancelled) {
            _log.warning("Local sync cancelled. Stopped processing albums.");
            return;
          }
          final deviceIds = await _nativeSyncApi.getAssetIdsForAlbum(album.id);
          await _localAlbumRepository.syncDeletes(album.id, deviceIds);
        }
      }

      if (CurrentPlatform.isIOS) {
        // On iOS, we need to full sync albums that are marked as cloud as the delta sync
        // does not include changes for cloud albums.
        final cloudAlbums = deviceAlbums.where((a) => a.isCloud).toLocalAlbums();
        for (final album in cloudAlbums) {
          if (_isCancelled) {
            _log.warning("Local sync cancelled. Stopped processing cloud albums.");
            return;
          }
          final dbAlbum = dbAlbums.firstWhereOrNull((a) => a.id == album.id);
          if (dbAlbum == null) {
            _log.warning("Cloud album ${album.name} not found in local database. Skipping sync.");
            continue;
          }
          await updateAlbum(dbAlbum, album);
        }

        await _mapIosCloudIds(newAssets);
      }
      await _nativeSyncApi.checkpointSync();
    } on PlatformException catch (e, s) {
      if (e.code == _kSyncCancelledCode) {
        _log.warning("Local sync cancelled");
      } else {
        _log.severe("Error performing device sync", e, s);
      }
    } catch (e, s) {
      _log.severe("Error performing device sync", e, s);
    } finally {
      stopwatch.stop();
      _log.info("Device sync took - ${stopwatch.elapsedMilliseconds}ms");
    }
  }

  Future<void> fullSync() async {
    try {
      final Stopwatch stopwatch = Stopwatch()..start();

      // Snapshot the ids before reconciliation so locally deleted assets can be
      // detected by comparing against the surviving rows.
      final ownerId = _syncLocalDeletionsEnabled ? _currentUserId : null;
      final remoteIdsBefore = ownerId != null
          ? await _localAssetRepository.getRemoteIdsForLocalAssets(ownerId: ownerId)
          : const <({String localId, String remoteId, String checksum})>[];

      final deviceAlbums = await _nativeSyncApi.getAlbums();
      final dbAlbums = await _localAlbumRepository.getAll(sortBy: {SortLocalAlbumsBy.id});

      await diffSortedLists(
        dbAlbums,
        deviceAlbums.toLocalAlbums(),
        compare: (a, b) => a.id.compareTo(b.id),
        both: updateAlbum,
        onlyFirst: removeAlbum,
        onlySecond: addAlbum,
      );

      if (ownerId != null && !_isCancelled) {
        await _localDeletionRepository.deleteForeignRows(ownerId);
        await recordLocallyDeletedFromSnapshot(remoteIdsBefore, ownerId);
        await flushPendingDeletions(ownerId);
        await restoreLocallyPresentTrashed(ownerId);
      }

      await _nativeSyncApi.checkpointSync();
      stopwatch.stop();
      _log.info("Full device sync took - ${stopwatch.elapsedMilliseconds}ms");
    } on PlatformException catch (e, s) {
      if (e.code == _kSyncCancelledCode) {
        _log.warning("Full device sync cancelled");
      } else {
        _log.severe("Error performing full device sync", e, s);
      }
    } catch (e, s) {
      _log.severe("Error performing full device sync", e, s);
    }
  }

  Future<void> addAlbum(LocalAlbum album) async {
    if (_isCancelled) {
      return;
    }
    try {
      _log.fine("Adding device album ${album.name}");

      final assets = album.assetCount > 0
          ? await _nativeSyncApi.getAssetsForAlbum(album.id).then((a) => a.toLocalAssets())
          : <LocalAsset>[];

      await _localAlbumRepository.upsert(album, toUpsert: assets);
      await _mapIosCloudIds(assets);
      _log.fine("Successfully added device album ${album.name}");
    } catch (e, s) {
      _log.warning("Error while adding device album", e, s);
    }
  }

  Future<void> removeAlbum(LocalAlbum a) async {
    _log.fine("Removing device album ${a.name}");
    try {
      // Asset deletion is handled in the repository
      await _localAlbumRepository.delete(a.id);
    } catch (e, s) {
      _log.warning("Error while removing device album", e, s);
    }
  }

  // The deviceAlbum is ignored since we are going to refresh it anyways
  FutureOr<bool> updateAlbum(LocalAlbum dbAlbum, LocalAlbum deviceAlbum) async {
    if (_isCancelled) {
      return false;
    }
    try {
      _log.fine("Syncing device album ${dbAlbum.name}");

      if (_albumsEqual(deviceAlbum, dbAlbum)) {
        _log.fine("Device album ${dbAlbum.name} has not changed. Skipping sync.");
        return false;
      }

      _log.fine("Device album ${dbAlbum.name} has changed. Syncing...");

      // Faster path - only new assets added
      if (await checkAddition(dbAlbum, deviceAlbum)) {
        _log.fine("Fast synced device album ${dbAlbum.name}");
        return true;
      }

      // Slower path - full sync
      return await fullDiff(dbAlbum, deviceAlbum);
    } catch (e, s) {
      _log.warning("Error while diff device album", e, s);
    }
    return true;
  }

  @visibleForTesting
  // The [deviceAlbum] is expected to be refreshed before calling this method
  // with modified time and asset count
  Future<bool> checkAddition(LocalAlbum dbAlbum, LocalAlbum deviceAlbum) async {
    try {
      _log.fine("Fast syncing device album ${dbAlbum.name}");
      // Assets has been modified
      if (deviceAlbum.assetCount <= dbAlbum.assetCount) {
        _log.fine("Local album has modifications. Proceeding to full sync");
        return false;
      }

      final updatedTime = (dbAlbum.updatedAt.millisecondsSinceEpoch ~/ 1000) + 1;
      final newAssetsCount = await _nativeSyncApi.getAssetsCountSince(deviceAlbum.id, updatedTime);

      // Early return if no new assets were found
      if (newAssetsCount == 0) {
        _log.fine("No new assets found despite album having changes. Proceeding to full sync for ${dbAlbum.name}");
        return false;
      }

      // Check whether there is only addition or if there has been deletions
      if (deviceAlbum.assetCount != dbAlbum.assetCount + newAssetsCount) {
        _log.fine("Local album has modifications. Proceeding to full sync");
        return false;
      }

      final newAssets = await _nativeSyncApi
          .getAssetsForAlbum(deviceAlbum.id, updatedTimeCond: updatedTime)
          .then((a) => a.toLocalAssets());

      await _localAlbumRepository.upsert(
        deviceAlbum.copyWith(backupSelection: dbAlbum.backupSelection),
        toUpsert: newAssets,
      );

      await _mapIosCloudIds(newAssets);
      return true;
    } catch (e, s) {
      _log.warning("Error on fast syncing local album: ${dbAlbum.name}", e, s);
    }
    return false;
  }

  @visibleForTesting
  // The [deviceAlbum] is expected to be refreshed before calling this method
  // with modified time and asset count
  Future<bool> fullDiff(LocalAlbum dbAlbum, LocalAlbum deviceAlbum) async {
    try {
      final assetsInDevice = deviceAlbum.assetCount > 0
          ? await _nativeSyncApi.getAssetsForAlbum(deviceAlbum.id).then((a) => a.toLocalAssets())
          : <LocalAsset>[];
      final assetsInDb = dbAlbum.assetCount > 0 ? await _localAlbumRepository.getAssets(dbAlbum.id) : <LocalAsset>[];

      if (deviceAlbum.assetCount == 0) {
        _log.fine("Device album ${deviceAlbum.name} is empty. Removing assets from DB.");
        await _localAlbumRepository.upsert(
          deviceAlbum.copyWith(backupSelection: dbAlbum.backupSelection),
          toDelete: assetsInDb.map((a) => a.id),
        );
        return true;
      }

      final updatedDeviceAlbum = deviceAlbum.copyWith(backupSelection: dbAlbum.backupSelection);

      if (dbAlbum.assetCount == 0) {
        _log.fine("Device album ${deviceAlbum.name} is empty. Adding assets to DB.");
        await _localAlbumRepository.upsert(updatedDeviceAlbum, toUpsert: assetsInDevice);
        await _mapIosCloudIds(assetsInDevice);
        return true;
      }

      assert(assetsInDb.isSortedBy((a) => a.id));
      assetsInDevice.sort((a, b) => a.id.compareTo(b.id));

      final assetsToUpsert = <LocalAsset>[];
      final assetsToDelete = <String>[];

      diffSortedListsSync(
        assetsInDb,
        assetsInDevice,
        compare: (a, b) => a.id.compareTo(b.id),
        both: (dbAsset, deviceAsset) {
          // Custom comparison to check if the asset has been modified without
          // comparing the checksum
          if (!_assetsEqual(dbAsset, deviceAsset)) {
            assetsToUpsert.add(deviceAsset);
            return true;
          }
          return false;
        },
        onlyFirst: (dbAsset) => assetsToDelete.add(dbAsset.id),
        onlySecond: (deviceAsset) => assetsToUpsert.add(deviceAsset),
      );

      _log.fine(
        "Syncing ${deviceAlbum.name}. ${assetsToUpsert.length} assets to add/update and ${assetsToDelete.length} assets to delete",
      );

      if (assetsToUpsert.isEmpty && assetsToDelete.isEmpty) {
        _log.fine("No asset changes detected in album ${deviceAlbum.name}. Updating metadata.");
        await _localAlbumRepository.upsert(updatedDeviceAlbum);
        return true;
      }

      await _localAlbumRepository.upsert(updatedDeviceAlbum, toUpsert: assetsToUpsert, toDelete: assetsToDelete);
      await _mapIosCloudIds(assetsToUpsert);

      return true;
    } catch (e, s) {
      _log.warning("Error on full syncing local album: ${dbAlbum.name}", e, s);
    }
    return true;
  }

  // ignore: avoid-unused-parameters
  Future<void> _mapIosCloudIds(List<LocalAsset> assets) async {
    // if (!CurrentPlatform.isIOS || assets.isEmpty) {
    return;
    // }

    // final assetIds = assets.map((a) => a.id).toList();
    // final cloudMapping = <String, String>{};
    // final cloudIds = await _nativeSyncApi.getCloudIdForAssetIds(assetIds);
    // for (int i = 0; i < cloudIds.length; i++) {
    //   final cloudIdResult = cloudIds[i];
    //   if (cloudIdResult.cloudId != null) {
    //     cloudMapping[cloudIdResult.assetId] = cloudIdResult.cloudId!;
    //   } else {
    //     final asset = assets.firstWhereOrNull((a) => a.id == cloudIdResult.assetId);
    //     _log.fine(
    //       "Cannot fetch cloudId for asset with id: ${cloudIdResult.assetId}, name: ${asset?.name}, createdAt: ${asset?.createdAt}. Error: ${cloudIdResult.error ?? "unknown"}",
    //     );
    //   }
    // }

    // await _localAlbumRepository.updateCloudMapping(cloudMapping);
  }

  bool _assetsEqual(LocalAsset a, LocalAsset b) {
    if (CurrentPlatform.isAndroid) {
      return a.updatedAt.isAtSameMomentAs(b.updatedAt) &&
          a.createdAt.isAtSameMomentAs(b.createdAt) &&
          a.width == b.width &&
          a.height == b.height &&
          a.durationMs == b.durationMs;
    }

    final firstAdjustment = a.adjustmentTime?.millisecondsSinceEpoch ?? 0;
    final secondAdjustment = b.adjustmentTime?.millisecondsSinceEpoch ?? 0;
    return firstAdjustment == secondAdjustment &&
        a.createdAt.isAtSameMomentAs(b.createdAt) &&
        a.width == b.width &&
        a.height == b.height &&
        a.durationMs == b.durationMs &&
        a.latitude == b.latitude &&
        a.longitude == b.longitude;
  }

  bool _albumsEqual(LocalAlbum a, LocalAlbum b) {
    return a.name == b.name && a.assetCount == b.assetCount && a.updatedAt.isAtSameMomentAs(b.updatedAt);
  }

  bool get _syncLocalDeletionsEnabled => SettingsRepository.instance.appConfig.backup.syncLocalDeletions;

  String? get _currentUserId => Store.tryGet(StoreKey.currentUser)?.id;

  @visibleForTesting
  Future<void> recordLocallyDeletedFromDelta(List<LocalAsset> deletedAssets, String ownerId) async {
    // Only assets that were backed up to the server (have a remote counterpart
    // resolved via checksum) are relevant.
    final candidates = deletedAssets.where((a) => a.remoteId != null && a.checksum != null).toList();
    if (candidates.isEmpty) {
      return;
    }

    await _localDeletionRepository.upsert(ownerId, {for (final a in candidates) a.remoteId!: a.checksum!});
  }

  @visibleForTesting
  Future<void> recordLocallyDeletedFromSnapshot(
    List<({String localId, String remoteId, String checksum})> remoteIdsBefore,
    String ownerId,
  ) async {
    if (remoteIdsBefore.isEmpty) {
      return;
    }

    final present = await _localAssetRepository.getExistingAssetIds(remoteIdsBefore.map((e) => e.localId));
    final gone = remoteIdsBefore.where((e) => !present.contains(e.localId)).toList();
    if (gone.isEmpty) {
      return;
    }

    await _localDeletionRepository.upsert(ownerId, {for (final e in gone) e.remoteId: e.checksum});
  }

  /// Propagates pending deletions to the server trash (soft delete) and removes
  /// them from the queue. So a transient API failure can never silently drop it.
  @visibleForTesting
  Future<void> flushPendingDeletions(String ownerId) async {
    final pending = await _localDeletionRepository.getPending(ownerId);
    if (pending.isEmpty) {
      return;
    }

    // Cancel intents whose content is still present locally.
    final present = await _localAssetRepository.getExistingChecksums(pending.map((e) => e.checksum));
    final cancel = [for (final e in pending) if (present.contains(e.checksum)) e.remoteId];
    if (cancel.isNotEmpty) {
      await _localDeletionRepository.deleteByRemoteIds(cancel);
    }

    final remoteIds = [for (final e in pending) if (!present.contains(e.checksum)) e.remoteId];
    if (remoteIds.isEmpty) {
      return;
    }

    _log.fine("Moving ${remoteIds.length} locally deleted assets to the server trash: $remoteIds");
    try {
      await _assetApiRepository.delete(remoteIds, false);
      await _remoteAssetRepository.trash(remoteIds);
      await _localDeletionRepository.deleteByRemoteIds(remoteIds);
    } catch (e, s) {
      _log.warning("Failed to move ${remoteIds.length} deletions to the server trash; will retry next sync", e, s);
    }
  }

  /// Restores on the server any of the current user's own assets that are present
  /// on the device but sit in the server trash. Device-authoritative: a present
  /// local copy means the asset should not be trashed. Derived purely from synced
  /// state, so it keeps working after the deletion queue is gone (logout,
  /// token-expiry, reinstall) and regardless of where the asset was trashed.
  ///
  /// Reappearance is detected by checksum, which a reappeared asset only gains
  /// once it has been re-hashed; restoration is therefore deferred to a later
  /// sync pass (after hashing) rather than happening the instant the asset
  /// reappears.
  ///
  /// Offline-retry invariant: the local `deletedAt` (via [_remoteAssetRepository])
  /// is cleared only after the server restore succeeds. On failure the local
  /// trash state is left intact so the same condition is re-derived and retried
  /// on the next sync.
  @visibleForTesting
  Future<void> restoreLocallyPresentTrashed(String ownerId) async {
    final restorable = await _remoteAssetRepository.getLocallyPresentTrashedRemoteIds(ownerId);
    if (restorable.isEmpty) {
      return;
    }

    _log.fine("Restoring ${restorable.length} locally present trashed assets on the server: $restorable");
    try {
      await _assetApiRepository.restoreTrash(restorable);
      await _remoteAssetRepository.restoreTrash(restorable);
    } catch (e, s) {
      _log.warning("Failed to restore ${restorable.length} assets on the server; will retry next sync", e, s);
    }
  }

  Future<void> _syncTrashedAssets() async {
    final trashedAssetMap = await _nativeSyncApi.getTrashedAssets();
    await processTrashedAssets(trashedAssetMap);
  }

  @visibleForTesting
  Future<void> processTrashedAssets(Map<String, List<PlatformAsset>> trashedAssetMap) async {
    if (trashedAssetMap.isEmpty) {
      _log.info("syncTrashedAssets, No trashed assets found");
    }
    final trashedAssets = trashedAssetMap.cast<String, List<Object?>>().entries.expand(
      (entry) => entry.value.cast<PlatformAsset>().toTrashedAssets(entry.key),
    );

    _log.fine("syncTrashedAssets, trashedAssets: ${trashedAssets.map((e) => e.asset.id)}");
    await _trashedLocalAssetRepository.processTrashSnapshot(trashedAssets);

    final assetsToRestore = await _trashedLocalAssetRepository.getToRestore();
    if (assetsToRestore.isNotEmpty) {
      final restoredIds = await _assetMediaRepository.restoreAssetsFromTrash(assetsToRestore);
      await _trashedLocalAssetRepository.applyRestoredAssets(restoredIds);
    } else {
      _log.info("syncTrashedAssets, No remote assets found for restoration");
    }

    final localAssetsToTrash = await _trashedLocalAssetRepository.getToTrash();
    if (localAssetsToTrash.isNotEmpty) {
      final localIds = localAssetsToTrash.values.expand((assets) => assets).map((asset) => asset.id).toList();
      _log.info("Moving to trash ${localIds.join(", ")} assets");
      final movedIds = await _assetMediaRepository.deleteAll(localIds);
      if (movedIds.isNotEmpty) {
        final movedAssetsByAlbum = localAssetsToTrash.map(
          (albumId, assets) => MapEntry(albumId, assets.where((asset) => movedIds.contains(asset.id)).toList()),
        )..removeWhere((_, assets) => assets.isEmpty);

        await _trashedLocalAssetRepository.trashLocalAsset(movedAssetsByAlbum);
      }
    } else {
      _log.info("syncTrashedAssets, No assets found in backup-enabled albums for move to trash");
    }
  }
}

extension on Iterable<PlatformAlbum> {
  List<LocalAlbum> toLocalAlbums() {
    return map(
      (e) => LocalAlbum(
        id: e.id,
        name: e.name,
        updatedAt: tryFromSecondsSinceEpoch(e.updatedAt, isUtc: true) ?? DateTime.timestamp(),
        assetCount: e.assetCount,
        isIosSharedAlbum: e.isCloud,
      ),
    ).toList();
  }
}

extension on Iterable<PlatformAsset> {
  List<LocalAsset> toLocalAssets() {
    return map((e) => e.toLocalAsset()).toList();
  }

  Iterable<TrashedAsset> toTrashedAssets(String albumId) {
    return map((e) => (albumId: albumId, asset: e.toLocalAsset()));
  }
}

extension PlatformToLocalAsset on PlatformAsset {
  LocalAsset toLocalAsset() => LocalAsset(
    id: id,
    name: name,
    checksum: null,
    type: AssetType.values.elementAtOrNull(type) ?? AssetType.other,
    createdAt: tryFromSecondsSinceEpoch(createdAt, isUtc: true) ?? DateTime.timestamp(),
    updatedAt: tryFromSecondsSinceEpoch(updatedAt, isUtc: true) ?? DateTime.timestamp(),
    width: width,
    height: height,
    durationMs: durationMs,
    isFavorite: isFavorite,
    orientation: orientation,
    playbackStyle: _toPlaybackStyle(playbackStyle),
    adjustmentTime: tryFromSecondsSinceEpoch(adjustmentTime, isUtc: true),
    latitude: latitude,
    longitude: longitude,
    isEdited: false,
  );
}

AssetPlaybackStyle _toPlaybackStyle(PlatformAssetPlaybackStyle style) => switch (style) {
  PlatformAssetPlaybackStyle.unknown => AssetPlaybackStyle.unknown,
  PlatformAssetPlaybackStyle.image => AssetPlaybackStyle.image,
  PlatformAssetPlaybackStyle.video => AssetPlaybackStyle.video,
  PlatformAssetPlaybackStyle.imageAnimated => AssetPlaybackStyle.imageAnimated,
  PlatformAssetPlaybackStyle.livePhoto => AssetPlaybackStyle.livePhoto,
  PlatformAssetPlaybackStyle.videoLooping => AssetPlaybackStyle.videoLooping,
};
