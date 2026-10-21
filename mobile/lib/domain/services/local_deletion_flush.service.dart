import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' show ApiException;

const int _kDeletionFlushChunkSize = 1000;

class LocalDeletionFlushService {
  final LocalDeletionRepository _localDeletionRepository;
  final AssetService _assetService;
  final DevicePermissionService _devicePermissionService;
  final ServerInfoService _serverInfoService;
  final NativeSyncApi _nativeSyncApi;
  final Completer<void>? _cancellation;
  final Logger _log = Logger("LocalDeletionFlushService");

  LocalDeletionFlushService({
    required this._localDeletionRepository,
    required this._assetService,
    required this._devicePermissionService,
    required this._serverInfoService,
    required this._nativeSyncApi,
    this._cancellation,
  }) {
    unawaited(_cancellation?.future.then((_) => _nativeSyncApi.cancelHashing().onError(_log.warning)));
  }

  bool get _isCancelled => _cancellation?.isCompleted ?? false;

  bool get _syncLocalDeletionsEnabled => SettingsRepository.instance.appConfig.backup.syncLocalDeletions;

  bool get _syncLocalMovesOutOfBackupAsDeletion =>
      SettingsRepository.instance.appConfig.backup.syncLocalMovesOutOfBackupAsDeletion;

  Future<bool> _stillEnabled() async {
    await SettingsRepository.instance.refresh();
    return _syncLocalDeletionsEnabled;
  }

  String? get _currentUserId => Store.tryGet(StoreKey.currentUser)?.id;

  /// Flushes the current user's pending deletions when the feature is enabled and full media access is granted
  Future<void> flush() async {
    if (_isCancelled || !_syncLocalDeletionsEnabled) {
      return;
    }
    if (await _devicePermissionService.galleryStatus() != .granted) {
      return;
    }
    final ownerId = _currentUserId;
    if (ownerId == null) {
      return;
    }
    await flushPendingDeletions(ownerId);
  }

  /// Pushes pending deletions to the server trash. Rows are kept on transient failures and retried on the next flush
  @visibleForTesting
  Future<void> flushPendingDeletions(String ownerId) async {
    await _localDeletionRepository.pruneAlreadyTrashed();
    await _localDeletionRepository.pruneRestored(ownerId);
    final settledBefore = DateTime.now().subtract(kLocalDeletionSettleDuration);
    var remoteIds = await _localDeletionRepository.getPending(ownerId, settledBefore: settledBefore);
    if (remoteIds.isEmpty) {
      return;
    }

    // A move-to-trash is a permanent delete when the server has trash disabled.
    // Confirm the feature before touching remote assets and keep the queue for a
    // later retry when the check fails or trash is off.
    final features = await _serverInfoService.getServerFeatures();
    if (features == null) {
      _log.warning("Cannot confirm the server trash feature. Skipping the deletion flush, will retry next sync");
      return;
    }
    if (!features.trash) {
      _log.warning(
        "Server trash is disabled. Keeping ${remoteIds.length} pending deletions to avoid permanent deletion",
      );
      return;
    }

    // iOS albums only reference assets, so nothing is moved out of a backed-up album there
    if (CurrentPlatform.isAndroid && !_syncLocalMovesOutOfBackupAsDeletion) {
      final (:moved, :unresolved) = await _findMoved(remoteIds);
      if (moved.isNotEmpty) {
        await _localDeletionRepository.deleteByRemoteIds(moved);
      }
      remoteIds = [
        for (final id in remoteIds)
          if (!moved.contains(id) && !unresolved.contains(id)) id,
      ];
      if (remoteIds.isEmpty) {
        return;
      }
    }

    _log.fine("Moving ${remoteIds.length} locally deleted assets to the server trash");
    for (final chunk in remoteIds.slices(_kDeletionFlushChunkSize)) {
      if (_isCancelled || !await _stillEnabled()) {
        return;
      }
      try {
        await _assetService.trash(chunk);
      } on ApiException catch (e, s) {
        if (_isServerRejection(e)) {
          // The server rejects a batch if any id no longer exists.
          await _flushIndividually(chunk);
          continue;
        }
        _log.warning("Failed to move ${chunk.length} deletions to the server trash. Will retry next sync", e, s);
        return;
      } catch (e, s) {
        _log.warning("Failed to move ${chunk.length} deletions to the server trash. Will retry next sync", e, s);
        return;
      }
      await _localDeletionRepository.deleteByRemoteIds(chunk);
    }
  }

  /// Splits off the pending deletions that were moves into a folder that is not backed up. The copy there is never
  /// hashed, so files with the same name are hashed here and compared with the deleted file. Deletions whose
  /// look-alikes could not be hashed stay queued for the next flush
  Future<({Set<String> moved, Set<String> unresolved})> _findMoved(List<String> remoteIds) async {
    final candidates = await _localDeletionRepository.getMoveCandidates(remoteIds);
    if (candidates.isEmpty) {
      return (moved: const <String>{}, unresolved: const <String>{});
    }

    final hashes = <String, String>{};
    for (final slice in candidates.values.expand((c) => c.localIds).toSet().slices(kBatchHashFileLimit)) {
      if (_isCancelled) {
        break;
      }
      try {
        for (final result in await _nativeSyncApi.hashAssets(slice)) {
          final hash = result.hash;
          if (hash != null) {
            hashes[result.assetId] = hash;
          }
        }
      } catch (e, s) {
        _log.warning("Failed to hash possibly moved assets. Will retry next sync", e, s);
        break;
      }
    }

    final moved = <String>{};
    final unresolved = <String>{};
    for (final MapEntry(key: remoteId, value: candidate) in candidates.entries) {
      if (candidate.localIds.any((id) => hashes[id] == candidate.checksum)) {
        moved.add(remoteId);
      } else if (candidate.localIds.any((id) => !hashes.containsKey(id))) {
        unresolved.add(remoteId);
      }
    }
    if (moved.isNotEmpty) {
      _log.info("Keeping the server copy of ${moved.length} assets that were moved into a folder without backup");
    }
    return (moved: moved, unresolved: unresolved);
  }

  Future<void> _flushIndividually(List<String> remoteIds) async {
    for (final remoteId in remoteIds) {
      if (_isCancelled || !await _stillEnabled()) {
        return;
      }
      try {
        await _assetService.trash([remoteId]);
      } on ApiException catch (e, s) {
        if (!_isServerRejection(e)) {
          _log.warning("Failed to move a deletion to the server trash. Will retry next sync", e, s);
          return;
        }
        _log.warning("Dropping the deletion of $remoteId: rejected by the server");
      } catch (e, s) {
        _log.warning("Failed to move a deletion to the server trash. Will retry next sync", e, s);
        return;
      }
      await _localDeletionRepository.deleteByRemoteIds([remoteId]);
    }
  }

  static bool _isServerRejection(ApiException e) =>
      e.code == 400 &&
      e.innerException == null &&
      (e.message?.contains("Not found or no asset.delete access") ?? false);
}
