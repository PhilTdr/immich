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
// A sync that finds almost every backed-up library asset gone is treated as a
// device state change (volume ejected, access revoked, iCloud Photos removed
// from the device), not as deletions.
const int _kDeletionGuardMinAssets = 50;
const double _kDeletionGuardMaxVanishedRatio = 0.9;

typedef _DeletionSnapshot = ({String ownerId, int id});

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
          } on PlatformException catch (e, s) {
            if (e.code == _kSyncCancelledCode) {
              rethrow;
            }
            // A failure here (e.g. a trashed asset that no longer resolves) must
            // not abort the device sync and its deletion detection.
            _log.severe("Error syncing trashed assets", e, s);
          } catch (e, s) {
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

      // The Android delta does not report deletions. Snapshot the backed-up assets so the rows that the album
      // reconciliation below removes can be detected afterwards, like in the full sync
      final snapshot = CurrentPlatform.isAndroid ? await _takeDeletionSnapshot() : null;

      final deviceAlbums = await _nativeSyncApi.getAlbums();

      // Record deletion intents before processDelta removes the local rows, and before updateAll drops the vanished
      // albums that are not selected for backup, whose links tell the assets of iOS shared albums apart.
      final ownerId = CurrentPlatform.isIOS && delta.deletes.isNotEmpty ? await _deletionSyncOwner() : null;
      if (ownerId != null) {
        // The delta also reports the assets of a shared album that left the device
        await _excludeVanishedIosSharedAlbums(deviceAlbums);
      }
      final excluded = ownerId != null ? await recordLocallyDeletedFromDelta(delta.deletes, ownerId) : const <String>{};

      await _localAlbumRepository.updateAll(deviceAlbums.toLocalAlbums());
      final newAssets = delta.updates.toLocalAssets();

      await _localAlbumRepository.processDelta(
        updates: newAssets,
        deletes: delta.deletes,
        assetAlbums: delta.assetAlbums,
      );

      if (ownerId != null) {
        await _localDeletionRepository.consumeExcluded(excluded);
      }

      final dbAlbums = await _localAlbumRepository.getAll();
      // On Android, we need to sync all albums since it is not possible to
      // detect album deletions from the native side
      if (CurrentPlatform.isAndroid) {
        for (final album in dbAlbums) {
          if (_isCancelled) {
            _log.warning("Local sync cancelled. Stopped processing albums.");
            break;
          }
          final deviceIds = await _nativeSyncApi.getAssetIdsForAlbum(album.id);
          await _localAlbumRepository.syncDeletes(album.id, deviceIds);
        }

        // Also when cancelled, as no later sync can detect the rows removed so far
        if (snapshot != null) {
          await _detectAndQueueDeletionsFromSnapshot(snapshot);
        }
        if (_isCancelled) {
          return;
        }
      }

      if (CurrentPlatform.isIOS) {
        // On iOS, we need to full sync albums that are marked as cloud as the delta sync
        // does not include changes for cloud albums.
        final cloudAlbums = deviceAlbums.where((a) => a.isCloud).toLocalAlbums();
        // The cloud album sync below removes the rows of assets that left a shared album, so snapshot them when their
        // deletions are synced, like the Android delta
        final cloudSnapshot = cloudAlbums.isNotEmpty && _syncLocalDeletionsInIosSharedAlbums
            ? await _takeDeletionSnapshot()
            : null;
        for (final album in cloudAlbums) {
          if (_isCancelled) {
            _log.warning("Local sync cancelled. Stopped processing cloud albums.");
            break;
          }
          final dbAlbum = dbAlbums.firstWhereOrNull((a) => a.id == album.id);
          if (dbAlbum == null) {
            _log.warning("Cloud album ${album.name} not found in local database. Skipping sync.");
            continue;
          }
          await updateAlbum(dbAlbum, album);
        }

        // Also when cancelled, as no later sync can detect the rows removed so far
        if (cloudSnapshot != null) {
          await _detectAndQueueDeletionsFromSnapshot(cloudSnapshot);
        }
        if (_isCancelled) {
          return;
        }

        await _resolveCloudIds(newAssets);
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

      // Snapshot before reconciliation so deletions can be detected afterwards.
      final snapshot = await _takeDeletionSnapshot();

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

      if (snapshot != null) {
        await _detectAndQueueDeletionsFromSnapshot(snapshot);
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
      await _resolveCloudIds(assets);
      _log.fine("Successfully added device album ${album.name}");
    } catch (e, s) {
      _log.warning("Error while adding device album", e, s);
    }
  }

  Future<void> removeAlbum(LocalAlbum a) async {
    _log.fine("Removing device album ${a.name}");
    try {
      await _excludeWholeIosSharedAlbum(a);
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

      // Faster path - only new assets added. Not for iOS shared albums, whose dates cannot tell additions apart from
      // removals reliably
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

      // Also when the album was counted but vanished before its assets were read
      if (assetsInDevice.isEmpty) {
        _log.fine("Device album ${deviceAlbum.name} is empty. Removing assets from DB.");
        await _excludeWholeIosSharedAlbum(dbAlbum);
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

  String? get _currentUserId => Store.tryGet(StoreKey.currentUser)?.id;

  Future<String?> _deletionSyncOwner() async {
    if (!_syncLocalDeletionsEnabled) {
      return null;
    }
    // Limited photo access hides assets from the media queries, which must not be mistaken for deletions
    if (await _devicePermissionService.galleryStatus() != .granted) {
      return null;
    }
    return _currentUserId;
  }

  /// Turning the setting off clears the queue, which a running sync must not fill again. The sync runs in another
  /// isolate, whose cached settings miss the change, so they are read again right before queueing
  Future<bool> _stillEnabled() async {
    await SettingsRepository.instance.refresh();
    return _syncLocalDeletionsEnabled;
  }

  Future<_DeletionSnapshot?> _takeDeletionSnapshot() async {
    final ownerId = await _deletionSyncOwner();
    if (ownerId == null) {
      return null;
    }
    final id = await _localDeletionRepository.snapshotBackedUpAssets(
      ownerId,
      includeIosSharedAlbums: _syncLocalDeletionsInIosSharedAlbums,
    );
    return (ownerId: ownerId, id: id);
  }

  /// A shared album that leaves the device or empties as a whole (Shared Albums turned off, album left, iCloud signed
  /// out) is a device state change, not removals by its members. Its assets are excluded before their rows go, so
  /// their server copies are not trashed. Only while deletions are detected, which consumes the exclusions again
  Future<void> _excludeWholeIosSharedAlbum(LocalAlbum album) async {
    if (!album.isIosSharedAlbum || !_syncLocalDeletionsInIosSharedAlbums || await _deletionSyncOwner() == null) {
      return;
    }
    await _localDeletionRepository.markExcluded(await _localAlbumRepository.getAssetIds(album.id));
  }

  /// Like [_excludeWholeIosSharedAlbum] for the stored shared albums that [deviceAlbums] no longer lists or lists
  /// empty, once the caller resolved the deletion sync owner
  Future<void> _excludeVanishedIosSharedAlbums(List<PlatformAlbum> deviceAlbums) async {
    if (!_syncLocalDeletionsInIosSharedAlbums) {
      return;
    }
    final remaining = {
      for (final album in deviceAlbums)
        if (album.assetCount > 0) album.id,
    };
    for (final album in await _localAlbumRepository.getAll()) {
      if (album.isIosSharedAlbum && !remaining.contains(album.id)) {
        await _localDeletionRepository.markExcluded(await _localAlbumRepository.getAssetIds(album.id));
      }
    }
  }

  /// Detects deletions from the pre-reconciliation snapshot, re-verifying each
  /// candidate against the device before queuing so hidden or moved assets that
  /// merely lost their local row are not mistaken for deletions.
  Future<void> _detectAndQueueDeletionsFromSnapshot(_DeletionSnapshot snapshot) async {
    final result = await _localDeletionRepository.getSnapshotDeletionCandidates(snapshot.id);
    try {
      final candidates = result.candidates;
      if (candidates.isEmpty) {
        return;
      }

      final present = (await _nativeSyncApi.getExistingAssetIds(candidates.map((c) => c.localId).toList())).toSet();
      final gone = [
        for (final c in candidates)
          if (!present.contains(c.localId)) c,
      ];
      if (gone.isEmpty) {
        return;
      }

      final vanished = gone.where((c) => !c.inIosSharedAlbum).length;
      if (_isMassVanish(vanished, result.total)) {
        _log.warning("Skipping deletion sync: $vanished of ${result.total} backed-up assets vanished at once");
        return;
      }

      if (!await _stillEnabled()) {
        return;
      }
      // Turning the shared album option off drops the pending deletions, so the copies in shared albums are left out
      final includeIosSharedAlbums = _syncLocalDeletionsInIosSharedAlbums;
      await _localDeletionRepository.upsert(snapshot.ownerId, {
        for (final c in gone)
          if (includeIosSharedAlbums || !c.inIosSharedAlbum) c.remoteId: c.checksum,
      });
    } finally {
      await _localDeletionRepository.clearSnapshotAndConsumeExclusions(snapshot.id);
    }
  }

  /// Both counts leave out the copies in iOS shared albums, which stay on the device or leave it with their album, so
  /// they do not water down the share of the library that vanished
  bool _isMassVanish(int vanished, int total) =>
      total >= _kDeletionGuardMinAssets && vanished > total * _kDeletionGuardMaxVanishedRatio;

  /// Queues the backed-up assets among [deletedIds] for a server move-to-trash,
  /// unless the setting was turned off meanwhile or almost every backed-up
  /// asset of the library is among them, and returns the app-initiated
  /// deletions that were skipped. Callers must
  /// [LocalDeletionRepository.consumeExcluded] those once the local rows
  /// are gone.
  @visibleForTesting
  Future<Set<String>> recordLocallyDeletedFromDelta(List<String> deletedIds, String ownerId) async {
    if (deletedIds.isEmpty) {
      return const {};
    }

    final excluded = await _localDeletionRepository.getExcluded(deletedIds);
    final ids = [
      for (final id in deletedIds)
        if (!excluded.contains(id)) id,
    ];
    if (ids.isEmpty) {
      return excluded;
    }

    // The cached option, which also decided whether the shared albums that left the device were excluded
    final includeIosSharedAlbums = _syncLocalDeletionsInIosSharedAlbums;
    var backedUp = await _localDeletionRepository.getBackedUp(
      ownerId,
      ids,
      includeIosSharedAlbums: includeIosSharedAlbums,
    );
    // Everyday deletions are too few to trip the guard, so they skip the counts
    if (backedUp.length > _kDeletionGuardMinAssets * _kDeletionGuardMaxVanishedRatio) {
      // Without the copies in iOS shared albums, see [_isMassVanish]
      final vanished = includeIosSharedAlbums
          ? (await _localDeletionRepository.getBackedUp(ownerId, ids)).length
          : backedUp.length;
      final total = await _localDeletionRepository.countBackedUp(ownerId);
      if (_isMassVanish(vanished, total)) {
        _log.warning("Skipping deletion sync: $vanished of $total backed-up assets vanished at once");
        return excluded;
      }
    }
    if (!await _stillEnabled()) {
      return excluded;
    }
    // Turning the shared album option off drops the pending deletions, so the copies in shared albums are left out
    if (includeIosSharedAlbums && !_syncLocalDeletionsInIosSharedAlbums) {
      backedUp = await _localDeletionRepository.getBackedUp(ownerId, ids);
    }
    await _localDeletionRepository.upsert(ownerId, backedUp);
    return excluded;
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
