import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';

final cleanupServiceProvider = Provider<CleanupService>((ref) {
  return CleanupService(
    ref.watch(localAssetRepository),
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(localDeletionRepository),
  );
});

class CleanupService {
  static final int _deleteBatchSize = CurrentPlatform.isAndroid ? 2000 : 10000;

  final DriftLocalAssetRepository _localAssetRepository;
  final AssetMediaRepository _assetMediaRepository;
  final DriftLocalDeletionRepository _localDeletionRepository;

  const CleanupService(this._localAssetRepository, this._assetMediaRepository, this._localDeletionRepository);

  Future<RemovalCandidatesResult> getRemovalCandidates(
    String userId,
    DateTime cutoffDate, {
    AssetKeepType keepMediaType = AssetKeepType.none,
    bool keepFavorites = true,
    Set<String> keepAlbumIds = const {},
  }) {
    return _localAssetRepository.getRemovalCandidates(
      userId,
      cutoffDate,
      keepMediaType: keepMediaType,
      keepFavorites: keepFavorites,
      keepAlbumIds: keepAlbumIds,
    );
  }

  Future<int> deleteLocalAssets(List<String> localIds) async {
    if (localIds.isEmpty) {
      return 0;
    }

    // These deletions keep the remote copy. The deletion sync must skip them.
    final exclude = SettingsRepository.instance.appConfig.backup.syncLocalDeletions;
    int deletedCount = 0;

    for (int index = 0; index < localIds.length; index += _deleteBatchSize) {
      final end = index + _deleteBatchSize < localIds.length ? index + _deleteBatchSize : localIds.length;
      final batch = localIds.sublist(index, end);

      if (exclude) {
        await _localDeletionRepository.markExcluded(batch);
      }
      final List<String> deletedIds;
      try {
        deletedIds = await _assetMediaRepository.deleteAll(batch);
      } catch (_) {
        if (exclude) {
          await _localDeletionRepository.unmarkExcluded(batch);
        }
        rethrow;
      }
      if (exclude && deletedIds.length != batch.length) {
        await _localDeletionRepository.unmarkExcluded(batch.toSet().difference(deletedIds.toSet()));
      }
      if (deletedIds.isNotEmpty) {
        await _localAssetRepository.delete(deletedIds);
        deletedCount += deletedIds.length;
      }
    }

    return deletedCount;
  }

  /// Returns album IDs that should be kept by default (e.g., messaging app albums)
  Set<String> getDefaultKeepAlbumIds(List<(String id, String name)> albums) {
    const messagingApps = ['whatsapp', 'telegram', 'signal', 'messenger', 'viber', 'wechat', 'line'];

    final toKeep = <String>{};
    for (final (id, name) in albums) {
      final albumName = name.toLowerCase();
      if (messagingApps.any((app) => albumName.contains(app))) {
        toKeep.add(id);
      }
    }
    return toKeep;
  }
}
