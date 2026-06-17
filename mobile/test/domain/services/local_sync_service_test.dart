import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../domain/service.mock.dart';
import '../../fixtures/asset.stub.dart';
import '../../fixtures/user.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';

void main() {
  late LocalSyncService sut;
  late DriftLocalAlbumRepository mockLocalAlbumRepository;
  late DriftLocalAssetRepository mockLocalAssetRepository;
  late DriftTrashedLocalAssetRepository mockTrashedLocalAssetRepository;
  late AssetMediaRepository mockAssetMediaRepository;
  late MockPermissionRepository mockPermissionRepository;
  late MockAssetApiRepository mockAssetApiRepository;
  late MockRemoteAssetRepository mockRemoteAssetRepository;
  late MockLocalDeletionRepository mockLocalDeletionRepository;
  late MockNativeSyncApi mockNativeSyncApi;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    registerFallbackValue(<LocalAsset>[]);
    registerFallbackValue(<String>[]);
    registerFallbackValue(Iterable<String>.empty());
    registerFallbackValue(<String, String>{});
    registerFallbackValue(<String, List<String>>{});

    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
    await SettingsRepository.ensureInitialized(db);
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await Store.clear();
    await db.close();
  });

  setUp(() async {
    mockLocalAlbumRepository = MockLocalAlbumRepository();
    mockLocalAssetRepository = MockLocalAssetRepository();
    mockTrashedLocalAssetRepository = MockTrashedLocalAssetRepository();
    mockAssetMediaRepository = MockAssetMediaRepository();
    mockPermissionRepository = MockPermissionRepository();
    mockAssetApiRepository = MockAssetApiRepository();
    mockRemoteAssetRepository = MockRemoteAssetRepository();
    mockLocalDeletionRepository = MockLocalDeletionRepository();
    mockNativeSyncApi = MockNativeSyncApi();

    when(() => mockNativeSyncApi.shouldFullSync()).thenAnswer((_) async => false);
    when(() => mockNativeSyncApi.getMediaChanges()).thenAnswer(
      (_) async => SyncDelta(hasChanges: false, updates: const [], deletes: const [], assetAlbums: const {}),
    );
    when(() => mockNativeSyncApi.getTrashedAssets()).thenAnswer((_) async => {});
    when(() => mockTrashedLocalAssetRepository.processTrashSnapshot(any())).thenAnswer((_) async {});
    when(() => mockTrashedLocalAssetRepository.getToRestore()).thenAnswer((_) async => []);
    when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer((_) async => {});
    when(() => mockTrashedLocalAssetRepository.applyRestoredAssets(any())).thenAnswer((_) async {});
    when(() => mockTrashedLocalAssetRepository.trashLocalAsset(any())).thenAnswer((_) async {});
    when(() => mockAssetMediaRepository.deleteAll(any())).thenAnswer((invocation) async {
      final ids = invocation.positionalArguments.first as List<String>;
      return ids;
    });

    sut = LocalSyncService(
      localAlbumRepository: mockLocalAlbumRepository,
      localAssetRepository: mockLocalAssetRepository,
      trashedLocalAssetRepository: mockTrashedLocalAssetRepository,
      assetMediaRepository: mockAssetMediaRepository,
      permissionRepository: mockPermissionRepository,
      assetApiRepository: mockAssetApiRepository,
      remoteAssetRepository: mockRemoteAssetRepository,
      localDeletionRepository: mockLocalDeletionRepository,
      nativeSyncApi: mockNativeSyncApi,
    );

    // Default: feature disabled and tracking repository quiescent.
    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);
    await Store.put(StoreKey.currentUser, UserStub.admin);
    when(() => mockLocalDeletionRepository.upsert(any(), any())).thenAnswer((_) async {});
    when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer((_) async => []);
    when(() => mockLocalDeletionRepository.deleteByRemoteIds(any())).thenAnswer((_) async {});
    when(() => mockLocalDeletionRepository.deleteForeignRows(any())).thenAnswer((_) async {});
    when(() => mockRemoteAssetRepository.getLocallyPresentTrashedRemoteIds(any())).thenAnswer((_) async => []);

    await Store.put(StoreKey.manageLocalMediaAndroid, false);
    when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => false);
  });

  group('LocalSyncService - syncTrashedAssets gating', () {
    test('invokes syncTrashedAssets when Android flag enabled and permission granted', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => true);

      await sut.sync();

      verify(() => mockNativeSyncApi.getTrashedAssets()).called(1);
      verify(() => mockTrashedLocalAssetRepository.processTrashSnapshot(any())).called(1);
    });

    test('skips syncTrashedAssets when store flag disabled', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, false);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => true);

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getTrashedAssets());
    });

    test('skips syncTrashedAssets when MANAGE_MEDIA permission absent', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => false);

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getTrashedAssets());
    });

    test('skips syncTrashedAssets on non-Android platforms', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => true);

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getTrashedAssets());
    });
  });

  group('LocalSyncService - syncTrashedAssets behavior', () {
    test('processes trashed snapshot, restores assets, and trashes local files', () async {
      final platformAsset = PlatformAsset(
        id: 'remote-id',
        name: 'remote.jpg',
        type: AssetType.image.index,
        durationMs: 0,
        orientation: 0,
        isFavorite: false,
        playbackStyle: PlatformAssetPlaybackStyle.image,
      );

      final assetsToRestore = [LocalAssetStub.image1];
      when(() => mockTrashedLocalAssetRepository.getToRestore()).thenAnswer((_) async => assetsToRestore);
      final restoredIds = ['image1'];
      when(() => mockAssetMediaRepository.restoreAssetsFromTrash(any())).thenAnswer((invocation) async {
        final Iterable<LocalAsset> requested = invocation.positionalArguments.first as Iterable<LocalAsset>;
        expect(requested, orderedEquals(assetsToRestore));
        return restoredIds;
      });

      final localAssetToTrash = LocalAssetStub.image2.copyWith(id: 'local-trash', checksum: 'checksum-trash');
      when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer(
        (_) async => {
          'album-a': [localAssetToTrash],
        },
      );

      await sut.processTrashedAssets({
        'album-a': [platformAsset],
      });

      final trashedSnapshot =
          verify(() => mockTrashedLocalAssetRepository.processTrashSnapshot(captureAny())).captured.single
              as Iterable<TrashedAsset>;
      expect(trashedSnapshot.length, 1);
      final trashedEntry = trashedSnapshot.single;
      expect(trashedEntry.albumId, 'album-a');
      expect(trashedEntry.asset.id, platformAsset.id);
      expect(trashedEntry.asset.name, platformAsset.name);
      verify(() => mockTrashedLocalAssetRepository.getToTrash()).called(1);

      verify(() => mockAssetMediaRepository.restoreAssetsFromTrash(any())).called(1);
      verify(() => mockTrashedLocalAssetRepository.applyRestoredAssets(restoredIds)).called(1);

      final moveArgs = verify(() => mockAssetMediaRepository.deleteAll(captureAny())).captured.single as List<String>;
      expect(moveArgs, ['local-trash']);
      final trashArgs =
          verify(() => mockTrashedLocalAssetRepository.trashLocalAsset(captureAny())).captured.single
              as Map<String, List<LocalAsset>>;
      expect(trashArgs.keys, ['album-a']);
      expect(trashArgs['album-a'], [localAssetToTrash]);
    });

    test('records only local assets that were moved to device trash', () async {
      final movedAsset = LocalAssetStub.image1.copyWith(id: 'moved-local', checksum: 'checksum-moved');
      final skippedAsset = LocalAssetStub.image2.copyWith(id: 'skipped-local', checksum: 'checksum-skipped');
      when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer(
        (_) async => {
          'album-a': [movedAsset],
          'album-b': [skippedAsset],
        },
      );
      when(() => mockAssetMediaRepository.deleteAll(any())).thenAnswer((_) async => ['moved-local']);

      await sut.processTrashedAssets({});

      final trashArgs =
          verify(() => mockTrashedLocalAssetRepository.trashLocalAsset(captureAny())).captured.single
              as Map<String, List<LocalAsset>>;
      expect(trashArgs.keys, ['album-a']);
      expect(trashArgs['album-a'], [movedAsset]);
    });

    test('does not attempt restore when repository has no assets to restore', () async {
      when(() => mockTrashedLocalAssetRepository.getToRestore()).thenAnswer((_) async => []);

      await sut.processTrashedAssets({});

      final trashedSnapshot =
          verify(() => mockTrashedLocalAssetRepository.processTrashSnapshot(captureAny())).captured.single
              as Iterable<TrashedAsset>;
      expect(trashedSnapshot, isEmpty);
      verifyNever(() => mockAssetMediaRepository.restoreAssetsFromTrash(any()));
      verifyNever(() => mockTrashedLocalAssetRepository.applyRestoredAssets(any()));
    });

    test('does not move local assets when repository finds nothing to trash', () async {
      when(() => mockTrashedLocalAssetRepository.getToTrash()).thenAnswer((_) async => {});

      await sut.processTrashedAssets({});

      verifyNever(() => mockAssetMediaRepository.deleteAll(any()));
      verifyNever(() => mockTrashedLocalAssetRepository.trashLocalAsset(any()));
    });
  });

  group('LocalSyncService - sync local deletions to server', () {
    test('records backed-up deleted assets as pending deletions (no server call yet)', () async {
      final deleted = [
        LocalAssetStub.image1.copyWith(id: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1'),
        LocalAssetStub.image1.copyWith(id: 'local-2', remoteId: 'remote-2', checksum: 'checksum-2'),
      ];

      await sut.recordLocallyDeletedFromDelta(deleted, 'owner-1');

      verify(
        () => mockLocalDeletionRepository.upsert('owner-1', {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'}),
      ).called(1);
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
    });

    test('ignores deleted assets without a remote counterpart', () async {
      final deleted = [LocalAssetStub.image1.copyWith(id: 'local-1')];

      await sut.recordLocallyDeletedFromDelta(deleted, 'owner-1');

      verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
    });

    test('full-sync snapshot records links whose local asset disappeared as pending', () async {
      final before = [
        (localId: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1'),
        (localId: 'local-2', remoteId: 'remote-2', checksum: 'checksum-2'),
      ];
      // local-1 survived reconciliation, local-2 is gone.
      when(() => mockLocalAssetRepository.getExistingAssetIds(any())).thenAnswer((_) async => {'local-1'});

      await sut.recordLocallyDeletedFromSnapshot(before, 'owner-1');

      verify(() => mockLocalDeletionRepository.upsert('owner-1', {'remote-2': 'checksum-2'})).called(1);
    });

    test('flush moves pending deletions to the server trash and clears their queue rows', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [(remoteId: 'remote-1', checksum: 'checksum-1'), (remoteId: 'remote-2', checksum: 'checksum-2')],
      );
      when(() => mockLocalAssetRepository.getExistingChecksums(any())).thenAnswer((_) async => <String>{});
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((_) async {});
      when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});

      await sut.flushPendingDeletions('owner-1');

      verify(() => mockAssetApiRepository.delete(['remote-1', 'remote-2'], false)).called(1);
      verify(() => mockRemoteAssetRepository.trash(['remote-1', 'remote-2'])).called(1);
      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-1', 'remote-2'])).called(1);
    });

    test('flush cancels pending deletions whose content is still present locally', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [(remoteId: 'remote-1', checksum: 'checksum-1'), (remoteId: 'remote-2', checksum: 'checksum-2')],
      );
      // checksum-1 still exists locally (duplicate / undo before sync) -> cancel remote-1.
      when(() => mockLocalAssetRepository.getExistingChecksums(any())).thenAnswer((_) async => {'checksum-1'});
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((_) async {});
      when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});

      await sut.flushPendingDeletions('owner-1');

      // remote-1 is cancelled (still present locally); remote-2 is trashed and its
      // queue row removed once the server confirms.
      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-1'])).called(1);
      verify(() => mockAssetApiRepository.delete(['remote-2'], false)).called(1);
      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-2'])).called(1);
    });

    test('flush leaves deletions queued when the server call fails', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1')]);
      when(() => mockLocalAssetRepository.getExistingChecksums(any())).thenAnswer((_) async => <String>{});
      when(() => mockAssetApiRepository.delete(any(), any())).thenThrow(Exception('network'));

      await sut.flushPendingDeletions('owner-1');

      // The queue row must survive a failed flush so it is retried on the next sync.
      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
    });

    test('restores locally present assets that sit in the server trash', () async {
      when(
        () => mockRemoteAssetRepository.getLocallyPresentTrashedRemoteIds(any()),
      ).thenAnswer((_) async => ['remote-1']);
      when(() => mockAssetApiRepository.restoreTrash(any())).thenAnswer((_) async {});
      when(() => mockRemoteAssetRepository.restoreTrash(any())).thenAnswer((_) async {});

      await sut.restoreLocallyPresentTrashed('owner-1');

      verify(() => mockRemoteAssetRepository.getLocallyPresentTrashedRemoteIds('owner-1')).called(1);
      // Offline-retry invariant: the server restore happens before the local
      // deletedAt is cleared.
      verifyInOrder([
        () => mockAssetApiRepository.restoreTrash(['remote-1']),
        () => mockRemoteAssetRepository.restoreTrash(['remote-1']),
      ]);
    });

    test('does nothing when no locally present asset is trashed on the server', () async {
      when(
        () => mockRemoteAssetRepository.getLocallyPresentTrashedRemoteIds(any()),
      ).thenAnswer((_) async => []);

      await sut.restoreLocallyPresentTrashed('owner-1');

      verifyNever(() => mockAssetApiRepository.restoreTrash(any()));
      verifyNever(() => mockRemoteAssetRepository.restoreTrash(any()));
    });

    test('does nothing in the delta path when the feature is disabled', () async {
      // feature disabled by default (see setUp)
      when(() => mockNativeSyncApi.getMediaChanges()).thenAnswer(
        (_) async => SyncDelta(hasChanges: true, updates: const [], deletes: const ['local-1'], assetAlbums: const {}),
      );
      when(() => mockNativeSyncApi.getAlbums()).thenAnswer((_) async => const []);
      when(() => mockLocalAlbumRepository.updateAll(any())).thenAnswer((_) async {});
      when(
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: any(named: 'deletes'),
          assetAlbums: any(named: 'assetAlbums'),
        ),
      ).thenAnswer((_) async {});
      when(() => mockLocalAlbumRepository.getAll()).thenAnswer((_) async => const []);
      when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async {});

      await sut.sync();

      verifyNever(() => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')));
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockLocalDeletionRepository.deleteForeignRows(any()));
      verifyNever(() => mockRemoteAssetRepository.getLocallyPresentTrashedRemoteIds(any()));
    });

    test('delta path resolves deletes before processDelta, then trashes and reconciles when enabled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));

      final deleted = LocalAssetStub.image1.copyWith(id: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1');
      when(() => mockNativeSyncApi.getMediaChanges()).thenAnswer(
        (_) async => SyncDelta(hasChanges: true, updates: const [], deletes: const ['local-1'], assetAlbums: const {}),
      );
      when(() => mockNativeSyncApi.getAlbums()).thenAnswer((_) async => const []);
      when(() => mockLocalAlbumRepository.updateAll(any())).thenAnswer((_) async {});
      when(
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: any(named: 'deletes'),
          assetAlbums: any(named: 'assetAlbums'),
        ),
      ).thenAnswer((_) async {});
      when(() => mockLocalAlbumRepository.getAll()).thenAnswer((_) async => const []);
      when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async {});
      when(
        () => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')),
      ).thenAnswer((_) async => [deleted]);
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1')]);
      when(() => mockLocalAssetRepository.getExistingChecksums(any())).thenAnswer((_) async => <String>{});
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((_) async {});
      when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});

      await sut.sync();

      // Deletes must be resolved (scoped to the current user) BEFORE processDelta
      // removes the rows; foreign-account rows are then purged, the deletion is
      // recorded, flushed to the server trash (and its queue row removed), and
      // finally the device-authoritative restore sweep runs.
      verifyInOrder([
        () => mockLocalAssetRepository.getByIds(['local-1'], ownerId: UserStub.admin.id),
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: any(named: 'deletes'),
          assetAlbums: any(named: 'assetAlbums'),
        ),
        () => mockLocalDeletionRepository.deleteForeignRows(UserStub.admin.id),
        () => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'}),
        () => mockLocalDeletionRepository.getPending(UserStub.admin.id),
        () => mockAssetApiRepository.delete(['remote-1'], false),
        () => mockRemoteAssetRepository.trash(['remote-1']),
        () => mockLocalDeletionRepository.deleteByRemoteIds(['remote-1']),
        () => mockRemoteAssetRepository.getLocallyPresentTrashedRemoteIds(UserStub.admin.id),
      ]);
    });

    test('delta path is disabled when there is no authenticated user even if enabled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));
      await Store.delete(StoreKey.currentUser);

      when(() => mockNativeSyncApi.getMediaChanges()).thenAnswer(
        (_) async => SyncDelta(hasChanges: true, updates: const [], deletes: const ['local-1'], assetAlbums: const {}),
      );
      when(() => mockNativeSyncApi.getAlbums()).thenAnswer((_) async => const []);
      when(() => mockLocalAlbumRepository.updateAll(any())).thenAnswer((_) async {});
      when(
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: any(named: 'deletes'),
          assetAlbums: any(named: 'assetAlbums'),
        ),
      ).thenAnswer((_) async {});
      when(() => mockLocalAlbumRepository.getAll()).thenAnswer((_) async => const []);
      when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async {});

      await sut.sync();

      verifyNever(() => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')));
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockLocalDeletionRepository.deleteForeignRows(any()));
    });

    test('full sync skips the deletion sweep when the run was cancelled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));

      final cancellation = Completer<void>()..complete();
      when(() => mockNativeSyncApi.cancelSync()).thenAnswer((_) async {});
      final cancelledSut = LocalSyncService(
        localAlbumRepository: mockLocalAlbumRepository,
        localAssetRepository: mockLocalAssetRepository,
        trashedLocalAssetRepository: mockTrashedLocalAssetRepository,
        assetMediaRepository: mockAssetMediaRepository,
        permissionRepository: mockPermissionRepository,
        assetApiRepository: mockAssetApiRepository,
        remoteAssetRepository: mockRemoteAssetRepository,
        localDeletionRepository: mockLocalDeletionRepository,
        nativeSyncApi: mockNativeSyncApi,
        cancellation: cancellation,
      );

      when(() => mockNativeSyncApi.getAlbums()).thenAnswer((_) async => const []);
      when(
        () => mockLocalAlbumRepository.getAll(sortBy: const {SortLocalAlbumsBy.id}),
      ).thenAnswer((_) async => const []);
      when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async {});
      when(
        () => mockLocalAssetRepository.getRemoteIdsForLocalAssets(ownerId: any(named: 'ownerId')),
      ).thenAnswer((_) async => [(localId: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1')]);

      await cancelledSut.fullSync();

      // Snapshot is still taken, but no deletion/restore is acted upon.
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockLocalDeletionRepository.deleteForeignRows(any()));
      verifyNever(() => mockRemoteAssetRepository.getLocallyPresentTrashedRemoteIds(any()));
    });
  });

  group('LocalSyncService - PlatformAsset conversion', () {
    test('toLocalAsset uses correct updatedAt timestamp', () {
      final platformAsset = PlatformAsset(
        id: 'test-id',
        name: 'test.jpg',
        type: AssetType.image.index,
        durationMs: 0,
        orientation: 0,
        isFavorite: false,
        createdAt: 1700000000,
        updatedAt: 1732000000,
        playbackStyle: PlatformAssetPlaybackStyle.image,
      );

      final localAsset = platformAsset.toLocalAsset();

      expect(localAsset.createdAt.millisecondsSinceEpoch ~/ 1000, 1700000000);
      expect(localAsset.updatedAt.millisecondsSinceEpoch ~/ 1000, 1732000000);
      expect(localAsset.updatedAt, isNot(localAsset.createdAt));
    });
  });
}
