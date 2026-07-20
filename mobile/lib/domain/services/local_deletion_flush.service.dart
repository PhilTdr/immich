import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/device_permission.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
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
    final remoteIds = await _localDeletionRepository.getPending(ownerId, settledBefore: settledBefore);
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

    _log.fine("Moving ${remoteIds.length} locally deleted assets to the server trash");
    for (final chunk in remoteIds.slices(_kDeletionFlushChunkSize)) {
      if (_isCancelled) {
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

  Future<void> _flushIndividually(List<String> remoteIds) async {
    for (final remoteId in remoteIds) {
      try {
        await _assetService.trash([remoteId]);
      } on ApiException catch (e, s) {
        if (!_isServerRejection(e)) {
          _log.warning("Failed to move a deletion to the server trash. Will retry next sync", e, s);
          return;
        }
        // Permanently rejected (asset gone or inaccessible) -> drop the intent.
      } catch (e, s) {
        _log.warning("Failed to move a deletion to the server trash. Will retry next sync", e, s);
        return;
      }
      await _localDeletionRepository.deleteByRemoteIds([remoteId]);
    }
  }

  // The client wraps transport failures as ApiException with code 400. Only a
  // real HTTP response (no inner exception) is a rejection by the server.
  static bool _isServerRejection(ApiException e) => e.code == 400 && e.innerException == null;
}
