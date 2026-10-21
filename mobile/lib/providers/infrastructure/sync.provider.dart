import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/domain/services/local_deletion_flush.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/sync_stream.service.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_api.repository.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/cancel.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';
import 'package:immich_mobile/services/server_info.service.dart';

final syncStreamServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  return SyncStreamService(
    syncApiRepository: ref.watch(syncApiRepositoryProvider),
    syncStreamRepository: db.syncStreamRepository,
    localAssetRepository: db.localAssetRepository,
    trashedLocalAssetRepository: db.trashedLocalAssetRepository,
    assetMediaRepository: ref.watch(assetMediaRepositoryProvider),
    permissionRepository: ref.watch(permissionRepositoryProvider),
    syncMigrationRepository: db.syncMigrationRepository,
    api: ref.watch(apiServiceProvider),
    cancellation: ref.watch(cancellationProvider),
  );
});

final syncApiRepositoryProvider = Provider((ref) => SyncApiRepository(ref.watch(apiServiceProvider)));

final localSyncServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  return LocalSyncService(
    localAlbumRepository: db.localAlbumRepository,
    trashedLocalAssetRepository: db.trashedLocalAssetRepository,
    assetMediaRepository: ref.watch(assetMediaRepositoryProvider),
    permissionRepository: ref.watch(permissionRepositoryProvider),
    devicePermissionService: ref.watch(galleryPermissionServiceProvider),
    localDeletionRepository: db.localDeletionRepository,
    nativeSyncApi: ref.watch(nativeSyncApiProvider),
    cancellation: ref.watch(cancellationProvider),
  );
});

final localDeletionFlushServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  return LocalDeletionFlushService(
    localDeletionRepository: db.localDeletionRepository,
    assetService: ref.watch(assetServiceProvider),
    devicePermissionService: ref.watch(galleryPermissionServiceProvider),
    serverInfoService: ref.watch(serverInfoServiceProvider),
    nativeSyncApi: ref.watch(nativeSyncApiProvider),
    cancellation: ref.watch(cancellationProvider),
  );
});

final hashServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  return HashService(
    localAlbumRepository: db.localAlbumRepository,
    localAssetRepository: db.localAssetRepository,
    nativeSyncApi: ref.watch(nativeSyncApiProvider),
    trashedLocalAssetRepository: db.trashedLocalAssetRepository,
    cancellation: ref.watch(cancellationProvider),
  );
});
