import 'dart:async';

import 'package:collection/collection.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/dao/local_deletion.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' show ApiException;

const int _kDeletionFlushChunkSize = 1000;

class LocalDeletionFlushService {
  final LocalDeletionRepository _localDeletionRepository;
  final AssetService _assetService;
  final DevicePermissionService _devicePermissionService;
  final ServerInfoService _serverInfoService;
  final Completer<void>? _cancellation;
  final Logger _log = Logger("LocalDeletionFlushService");

  LocalDeletionFlushService({
    required this._localDeletionRepository,
    required this._assetService,
    required this._devicePermissionService,
    required this._serverInfoService,
    this._cancellation,
  });

  bool get _isCancelled => _cancellation?.isCompleted ?? false;

  bool get _syncLocalDeletionsEnabled => SettingsRepository.instance.appConfig.backup.syncLocalDeletions;

  bool get _syncLocalDeletionsInIosSharedAlbums =>
      SettingsRepository.instance.appConfig.backup.syncLocalDeletionsInIosSharedAlbums;

  // The settings page writes in another isolate and clears the queue when an option is turned off
  Future<bool> _stillEnabled() async {
    final includedIosSharedAlbums = _syncLocalDeletionsInIosSharedAlbums;
    await SettingsRepository.instance.refresh();
    return _syncLocalDeletionsEnabled && (_syncLocalDeletionsInIosSharedAlbums || !includedIosSharedAlbums);
  }

  Future<void> flush() async {
    final ownerId = Store.tryGet(StoreKey.currentUser)?.id;
    if (_isCancelled || !_syncLocalDeletionsEnabled || ownerId == null) {
      return;
    }

    try {
      if (await _devicePermissionService.galleryStatus() != .granted) {
        return;
      }

      await _restoreReturned(ownerId);
      await _localDeletionRepository.prune(ownerId);
      if (await _localDeletionRepository.hasAwaitingConfirmation(ownerId)) {
        _log.info("Deletions await confirmation, skipping the flush");
        return;
      }
      final settledBefore = DateTime.now().subtract(kLocalDeletionSettleDuration);
      final remoteIds = await _localDeletionRepository.getToTrash(ownerId, settledBefore: settledBefore);
      if (remoteIds.isEmpty) {
        return;
      }

      // Without the trash the server would delete the assets permanently
      final features = await _serverInfoService.getServerFeatures();
      if (features == null) {
        _log.warning("Cannot fetch server features, skipping the deletion flush");
        return;
      }
      if (!features.trash) {
        _log.warning("Server trash is disabled, keeping ${remoteIds.length} pending deletions");
        return;
      }

      _log.fine("Moving ${remoteIds.length} locally deleted assets to the server trash");
      await _send(
        remoteIds,
        _assetService.trash,
        onAccepted: _localDeletionRepository.markTrashed,
        onRejected: _localDeletionRepository.deleteByRemoteIds,
        isEnabled: _stillEnabled,
      );
    } catch (e, s) {
      _log.severe("Error flushing local deletions", e, s);
    }
  }

  // A file that is back on the device is not uploaded again while its server copy is in the trash
  Future<void> _restoreReturned(String ownerId) async {
    final remoteIds = await _localDeletionRepository.getToRestore(ownerId);
    if (remoteIds.isEmpty) {
      return;
    }

    _log.info("Restoring ${remoteIds.length} assets that are back on the device");
    // A rejected row stays, it keeps the trash sync from removing the file again
    await _send(remoteIds, _assetService.restoreTrash, onAccepted: _localDeletionRepository.deleteByRemoteIds);
  }

  /// Returns false if it stopped early. The server rejects a whole chunk for one unknown id,
  /// so such a chunk is sent again in halves.
  Future<bool> _send(
    List<String> remoteIds,
    Future<void> Function(List<String> remoteIds) send, {
    required Future<void> Function(List<String> remoteIds) onAccepted,
    Future<void> Function(List<String> remoteIds)? onRejected,
    Future<bool> Function()? isEnabled,
    int chunkSize = _kDeletionFlushChunkSize,
  }) async {
    for (final chunk in remoteIds.slices(chunkSize)) {
      if (_isCancelled || !(await isEnabled?.call() ?? true)) {
        return false;
      }
      try {
        await send(chunk);
      } catch (e, s) {
        if (!_isServerRejection(e)) {
          _log.warning("Failed to sync ${chunk.length} deletions with the server", e, s);
          return false;
        }
        if (chunk.length == 1) {
          _log.warning("The server rejected the deleted asset ${chunk.single}");
          await onRejected?.call(chunk);
        } else if (!await _send(
          chunk,
          send,
          onAccepted: onAccepted,
          onRejected: onRejected,
          isEnabled: isEnabled,
          chunkSize: (chunk.length + 1) ~/ 2,
        )) {
          return false;
        }
        continue;
      }
      await onAccepted(chunk);
    }
    return true;
  }

  // The client reports connection errors as code 400 with an inner exception
  static bool _isServerRejection(Object e) => e is ApiException && e.code == 400 && e.innerException == null;
}
