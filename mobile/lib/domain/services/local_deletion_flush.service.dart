import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' show ApiException;

const int _kDeletionFlushChunkSize = 1000;

class LocalDeletionFlushService {
  final DriftLocalDeletionRepository _localDeletionRepository;
  final DriftLocalAssetRepository _localAssetRepository;
  final AssetApiRepository _assetApiRepository;
  final RemoteAssetRepository _remoteAssetRepository;
  final IPermissionRepository _permissionRepository;
  final ServerInfoService _serverInfoService;
  final Completer<void>? _cancellation;
  final Logger _log = Logger("LocalDeletionFlushService");

  LocalDeletionFlushService({
    required this._localDeletionRepository,
    required this._localAssetRepository,
    required this._assetApiRepository,
    required this._remoteAssetRepository,
    required this._permissionRepository,
    required this._serverInfoService,
    this._cancellation,
  });

  bool get _isCancelled => _cancellation?.isCompleted ?? false;

  bool get _syncLocalDeletionsEnabled => SettingsRepository.instance.appConfig.backup.syncLocalDeletions;

  Future<bool> _stillEnabled() async {
    await SettingsRepository.instance.refresh();
    return _syncLocalDeletionsEnabled;
  }

  String? get _currentUserId => Store.tryGet(StoreKey.currentUser)?.id;

  /// Flushes the current user's pending deletions when the feature is enabled
  /// and full media access is granted. Limited/selected access hides assets from
  /// the media queries and must not be mistaken for deletions.
  Future<void> flush() async {
    if (_isCancelled || !_syncLocalDeletionsEnabled) {
      return;
    }
    if (!await _permissionRepository.hasFullMediaPermission()) {
      return;
    }
    final ownerId = _currentUserId;
    if (ownerId == null) {
      return;
    }
    await flushPendingDeletions(ownerId);
  }

  /// Pushes pending deletions to the server trash. Rows are kept on transient
  /// failures and retried on the next flush.
  @visibleForTesting
  Future<void> flushPendingDeletions(String ownerId) async {
    await _localDeletionRepository.pruneAlreadyTrashed();
    final pending = await _localDeletionRepository.getPending(ownerId);
    if (pending.isEmpty) {
      return;
    }

    // Cancel intents whose content is still present locally.
    final present = await _localAssetRepository.getExistingChecksums(pending.map((e) => e.checksum));
    final cancel = [
      for (final e in pending)
        if (present.contains(e.checksum)) e.remoteId,
    ];
    if (cancel.isNotEmpty) {
      await _localDeletionRepository.deleteByRemoteIds(cancel);
    }

    final settledBefore = DateTime.now().subtract(kLocalDeletionSettleDuration);
    final remoteIds = [
      for (final e in pending)
        if (!present.contains(e.checksum) && e.createdAt.isBefore(settledBefore)) e.remoteId,
    ];
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
      if (_isCancelled || !await _stillEnabled()) {
        return;
      }
      try {
        await _assetApiRepository.delete(chunk, false);
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
      await _remoteAssetRepository.trash(chunk);
      await _localDeletionRepository.deleteByRemoteIds(chunk);
    }
  }

  Future<void> _flushIndividually(List<String> remoteIds) async {
    for (final remoteId in remoteIds) {
      if (_isCancelled || !await _stillEnabled()) {
        return;
      }
      try {
        await _assetApiRepository.delete([remoteId], false);
        await _remoteAssetRepository.trash([remoteId]);
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
      e.code == 400 && e.innerException == null && (e.message?.contains("Not found or no asset.delete access") ?? false);
}
