import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/domain/utils/cloud_id_resolver.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:immich_mobile/utils/datetime_helpers.dart';
import 'package:immich_mobile/utils/diff.dart';
import 'package:logging/logging.dart';

const String _kSyncCancelledCode = "SYNC_CANCELLED";
const int _kDeletionConfirmationMinAssets = 50;

typedef _DeletionSync = ({
  String ownerId,
  List<String> smartAlbumIds,
  Set<String> checkedLocalIds,
  Set<String> queuedRemoteIds,
});

class LocalSyncService {
  final LocalAlbumRepository _localAlbumRepository;
  final NativeSyncApi _nativeSyncApi;
  final TrashedLocalAssetRepository _trashedLocalAssetRepository;
  final AssetMediaRepository _assetMediaRepository;
  final DevicePermissionRepository _permissionRepository;
  final DevicePermissionService _devicePermissionService;
  final LocalDeletionRepository _localDeletionRepository;
  final Completer<void>? _cancellation;
  final Logger _log = Logger("DeviceSyncService");
  _DeletionSync? _deletionSync;

  LocalSyncService({
    required this._localAlbumRepository,
    required this._nativeSyncApi,
    required this._trashedLocalAssetRepository,
    required this._assetMediaRepository,
    required this._permissionRepository,
    required this._devicePermissionService,
    required this._localDeletionRepository,
    this._cancellation,
  }) {
    unawaited(_cancellation?.future.then((_) => _nativeSyncApi.cancelSync().onError(_log.warning)));
  }

  bool get _isCancelled => _cancellation?.isCompleted ?? false;

  Future<void> sync({bool full = false}) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      if (CurrentPlatform.isAndroid && Store.get(StoreKey.manageLocalMediaAndroid, false)) {
        final hasPermission = await _permissionRepository.hasManageMediaPermission();
        if (hasPermission) {
          try {
            await _syncTrashedAssets();
          } catch (e, s) {
            if (e is PlatformException && e.code == _kSyncCancelledCode) {
              rethrow;
            }
            _log.severe("Error syncing trashed assets", e, s);
          }
        } else {
          _log.warning("syncTrashedAssets cannot proceed because MANAGE_MEDIA permission is missing");
        }
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
      await _startDeletionSync(deviceAlbums);

      // Deleted and updated in one delta means restored, e.g. from Recently Deleted
      final updatedIds = {for (final asset in delta.updates) asset.id};
      // updateAll and processDelta remove the rows and album links that this needs
      await _queueRemovedAssets([
        for (final id in delta.deletes)
          if (!updatedIds.contains(id)) id,
      ], verifyOnDevice: CurrentPlatform.isAndroid);
      if (CurrentPlatform.isAndroid) {
        await _queueAssetsOfRemovedAlbums(deviceAlbums);
      }

      await _localAlbumRepository.updateAll(deviceAlbums.toLocalAlbums());
      final newAssets = delta.updates.toLocalAssets();

      await _localAlbumRepository.processDelta(
        updates: newAssets,
        deletes: delta.deletes,
        assetAlbums: delta.assetAlbums,
      );

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
          if (deviceIds.isNotEmpty) {
            await _queueRemovedAlbumAssets(album.id, keptIds: deviceIds);
          }
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

        await _resolveCloudIds(newAssets);
      }
      await _finishDeletionSync();
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

      final deviceAlbums = await _nativeSyncApi.getAlbums();
      await _startDeletionSync(deviceAlbums);
      final dbAlbums = await _localAlbumRepository.getAll(sortBy: {SortLocalAlbumsBy.id});

      await diffSortedLists(
        dbAlbums,
        deviceAlbums.toLocalAlbums(),
        compare: (a, b) => a.id.compareTo(b.id),
        both: updateAlbum,
        onlyFirst: removeAlbum,
        onlySecond: addAlbum,
      );

      await _finishDeletionSync();
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
      await _resolveCloudIds(assets);
      _log.fine("Successfully added device album ${album.name}");
    } catch (e, s) {
      _log.warning("Error while adding device album", e, s);
    }
  }

  Future<void> removeAlbum(LocalAlbum a) async {
    _log.fine("Removing device album ${a.name}");
    try {
      await _queueRemovedAlbumAssets(a.id);
      // Asset deletion is handled in the repository
      await _localAlbumRepository.deleteAlbum(a.id);
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

      // Faster path - only new assets added. Shared album dates don't show removals
      if (!dbAlbum.isIosSharedAlbum && await checkAddition(dbAlbum, deviceAlbum)) {
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

      await _resolveCloudIds(newAssets);
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
        final assetIdsInDb = assetsInDb.map((a) => a.id).toList();
        await _queueRemovedAssets(assetIdsInDb);
        await _localAlbumRepository.upsert(
          deviceAlbum.copyWith(backupSelection: dbAlbum.backupSelection),
          toDelete: assetIdsInDb,
        );
        return true;
      }

      final updatedDeviceAlbum = deviceAlbum.copyWith(backupSelection: dbAlbum.backupSelection);

      if (dbAlbum.assetCount == 0) {
        _log.fine("Device album ${deviceAlbum.name} is empty. Adding assets to DB.");
        await _localAlbumRepository.upsert(updatedDeviceAlbum, toUpsert: assetsInDevice);
        await _resolveCloudIds(assetsInDevice);
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

      await _queueRemovedAssets(assetsToDelete);
      await _localAlbumRepository.upsert(updatedDeviceAlbum, toUpsert: assetsToUpsert, toDelete: assetsToDelete);
      await _resolveCloudIds(assetsToUpsert);

      return true;
    } catch (e, s) {
      _log.warning("Error on full syncing local album: ${dbAlbum.name}", e, s);
    }
    return true;
  }

  Future<void> _resolveCloudIds(Iterable<LocalAsset> assets) =>
      resolveCloudIds(_nativeSyncApi, _localAlbumRepository, assets.map((a) => a.id), cancellation: _cancellation);

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

  bool get _syncLocalDeletionsInIosSharedAlbums =>
      SettingsRepository.instance.appConfig.backup.syncLocalDeletionsInIosSharedAlbums;

  // The settings page writes in another isolate
  Future<bool> _stillEnabled() async {
    await SettingsRepository.instance.refresh();
    return _syncLocalDeletionsEnabled;
  }

  Future<void> _startDeletionSync(List<PlatformAlbum> deviceAlbums) async {
    _deletionSync = null;
    final ownerId = Store.tryGet(StoreKey.currentUser)?.id;
    // Limited access hides assets, which would look deleted
    if (!_syncLocalDeletionsEnabled || ownerId == null || await _devicePermissionService.galleryStatus() != .granted) {
      return;
    }

    _deletionSync = (
      ownerId: ownerId,
      smartAlbumIds: [
        for (final album in deviceAlbums)
          if (album.isSmart) album.id,
      ],
      checkedLocalIds: {},
      queuedRemoteIds: {},
    );
  }

  Future<void> _finishDeletionSync() async {
    if (_deletionSync != null) {
      await _localDeletionRepository.consumeExcluded();
    }
  }

  Future<void> _queueAssetsOfRemovedAlbums(List<PlatformAlbum> deviceAlbums) async {
    if (_deletionSync == null) {
      return;
    }

    final deviceAlbumIds = {for (final album in deviceAlbums) album.id};
    for (final album in await _localAlbumRepository.getAll()) {
      if (!deviceAlbumIds.contains(album.id)) {
        await _queueRemovedAlbumAssets(album.id);
      }
    }
  }

  Future<void> _queueRemovedAlbumAssets(String albumId, {Iterable<String> keptIds = const []}) async {
    if (_deletionSync == null) {
      return;
    }

    final kept = keptIds.toSet();
    final assetIds = await _localAlbumRepository.getAssetIds(albumId);
    await _queueRemovedAssets([
      for (final id in assetIds)
        if (!kept.contains(id)) id,
    ]);
  }

  Future<void> _queueRemovedAssets(List<String> localIds, {bool verifyOnDevice = true}) async {
    final deletionSync = _deletionSync;
    if (deletionSync == null) {
      return;
    }

    final uncheckedIds = localIds.where(deletionSync.checkedLocalIds.add).toList();
    if (uncheckedIds.isEmpty) {
      return;
    }

    var removed = await _localDeletionRepository.getBackedUp(
      deletionSync.ownerId,
      uncheckedIds,
      includeIosSharedAlbums: _syncLocalDeletionsInIosSharedAlbums,
      smartAlbumIds: deletionSync.smartAlbumIds,
    );
    if (verifyOnDevice && removed.isNotEmpty) {
      final missing = (await _nativeSyncApi.getMissingAssetIds([
        for (final asset in removed) PlatformAssetFile(id: asset.localId, name: asset.name, albumId: asset.albumId),
      ])).toSet();
      if (missing.length < removed.length) {
        _log.info("${removed.length - missing.length} backed-up assets are still on the device or its volume");
      }
      removed = [
        for (final asset in removed)
          if (missing.contains(asset.localId)) asset,
      ];
    }
    if (removed.isEmpty || !await _stillEnabled()) {
      return;
    }

    // The shared albums option may have been turned off as well
    await _queueDeletions(deletionSync, {
      for (final asset in removed)
        if (_syncLocalDeletionsInIosSharedAlbums || !asset.inIosSharedAlbum)
          asset.remoteId: (checksum: asset.checksum, albumId: asset.albumId, albumName: asset.albumName),
    });
  }

  // From [_kDeletionConfirmationMinAssets] deletions on, a sync holds all of them for confirmation
  Future<void> _queueDeletions(_DeletionSync deletionSync, Map<String, DeletedAsset> deletions) async {
    if (deletions.isEmpty) {
      return;
    }

    final ownerId = deletionSync.ownerId;
    final queued = deletionSync.queuedRemoteIds;
    final queuedBefore = queued.toSet();
    queued.addAll(deletions.keys);
    final isReached = queued.length >= _kDeletionConfirmationMinAssets;
    await _localDeletionRepository.upsert(
      ownerId,
      deletions,
      awaitingConfirmation: isReached || await _localDeletionRepository.hasAwaitingConfirmation(ownerId),
    );
    if (isReached && queuedBefore.length < _kDeletionConfirmationMinAssets) {
      _log.warning("${queued.length} backed-up assets vanished at once. Holding them for confirmation");
      await _localDeletionRepository.holdForConfirmation(queuedBefore);
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
