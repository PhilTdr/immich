import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/data/db/main/dao/local_deletion.dart';
import 'package:immich_mobile/data/db/main/table/local/deletion.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/user.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';
import '../../service.mocks.dart';
import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late MockNativeSyncApi nativeSyncApi;
  late MockDevicePermissionService devicePermissionService;
  late LocalDeletionRepository localDeletionRepository;
  late LocalSyncService sut;
  final ownerId = UserStub.admin.id;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    ctx = MediumRepositoryContext();
    await StoreService.init(storeRepository: StoreRepository(ctx.db));
    await SettingsRepository.ensureInitialized(ctx.db);
    await ctx.newUser(id: ownerId);
    await Store.put(StoreKey.currentUser, UserStub.admin);
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await Store.clear();
    await ctx.dispose();
  });

  setUp(() async {
    await ctx.db.delete(ctx.db.localAlbumEntity).go();
    await ctx.db.delete(ctx.db.localAssetEntity).go();
    await ctx.db.delete(ctx.db.remoteAssetEntity).go();
    await ctx.db.delete(ctx.db.localDeletionEntity).go();
    await ctx.db.delete(ctx.db.localDeletionExclusionEntity).go();

    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, false);

    nativeSyncApi = MockNativeSyncApi();
    when(() => nativeSyncApi.shouldFullSync()).thenAnswer((_) async => false);
    when(() => nativeSyncApi.getCloudIdForAssetIds(any())).thenAnswer((_) async => const []);
    when(() => nativeSyncApi.checkpointSync()).thenAnswer((_) async {});
    when(() => nativeSyncApi.getAssetIdsForAlbum(any())).thenAnswer((_) async => const []);
    when(() => nativeSyncApi.getMissingAssetIds(any(), any())).thenAnswer(
      (invocation) async => [
        for (final asset in invocation.positionalArguments.first as List<PlatformAssetFile>) asset.id,
      ],
    );
    devicePermissionService = MockDevicePermissionService();
    when(() => devicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.granted);

    localDeletionRepository = LocalDeletionRepository(ctx.db);
    sut = LocalSyncService(
      localAlbumRepository: LocalAlbumRepository(ctx.db),
      trashedLocalAssetRepository: MockTrashedLocalAssetRepository(),
      assetMediaRepository: MockAssetMediaRepository(),
      permissionRepository: MockPermissionRepository(),
      devicePermissionService: devicePermissionService,
      localDeletionRepository: localDeletionRepository,
      nativeSyncApi: nativeSyncApi,
    );
  });

  Future<void> newBackupAlbum(String id, {String? name, bool isIosSharedAlbum = false}) => ctx.newLocalAlbum(
    id: id,
    name: name,
    backupSelection: BackupSelection.selected,
    isIosSharedAlbum: isIosSharedAlbum,
  );

  Future<void> newBackedUpAsset(String id, List<String> albumIds) async {
    await ctx.newRemoteAsset(id: 'remote-$id', ownerId: ownerId, checksum: 'checksum-$id');
    await ctx.newLocalAsset(id: id, checksum: 'checksum-$id');
    for (final albumId in albumIds) {
      await ctx.newLocalAlbumAsset(albumId: albumId, assetId: id);
    }
  }

  Future<Set<String>> localAssetIds() async {
    final rows = await ctx.db.select(ctx.db.localAssetEntity).get();
    return rows.map((row) => row.id).toSet();
  }

  Future<List<LocalDeletionEntityData>> queued() => ctx.db.select(ctx.db.localDeletionEntity).get();

  Future<Map<String, String?>> queuedAlbumNames() async => {
    for (final row in await queued()) row.remoteId: row.albumName,
  };

  Future<void> turnOffInAnotherIsolate(SettingsKey<bool> key) =>
      (ctx.db.delete(ctx.db.settingsEntity)..where((row) => row.key.equals(key.name))).go();

  PlatformAlbum deviceAlbum(String id, String name, {required int assetCount, bool isCloud = false}) => PlatformAlbum(
    id: id,
    name: name,
    updatedAt: 1800000000,
    isCloud: isCloud,
    assetCount: assetCount,
    isSmart: id == 'recents',
  );

  PlatformAsset deviceAsset(String id) => PlatformAsset(
    id: id,
    name: '$id.jpg',
    type: AssetType.image.index,
    createdAt: 1700000000,
    updatedAt: 1700000000,
    durationMs: 0,
    orientation: 0,
    isFavorite: false,
    playbackStyle: PlatformAssetPlaybackStyle.image,
  );

  void stubDevice(
    List<PlatformAlbum> albums, {
    List<String> deltaDeletes = const [],
    List<PlatformAsset> deltaUpdates = const [],
    Map<String, List<String>> deltaAssetAlbums = const {},
  }) {
    when(() => nativeSyncApi.getAlbums()).thenAnswer((_) async => albums);
    when(() => nativeSyncApi.getMediaChanges()).thenAnswer(
      (_) async =>
          SyncDelta(hasChanges: true, updates: deltaUpdates, deletes: deltaDeletes, assetAlbums: deltaAssetAlbums),
    );
    for (final album in albums) {
      when(() => nativeSyncApi.getAssetIdsForAlbum(album.id)).thenAnswer((_) async => ['kept']);
      when(() => nativeSyncApi.getAssetsForAlbum(album.id)).thenAnswer((_) async => [deviceAsset('kept')]);
    }
  }

  group('Android', () {
    setUp(() async {
      await newBackupAlbum('camera', name: 'Camera');
      await newBackupAlbum('card', name: 'Card');
      await newBackedUpAsset('kept', ['camera']);
      await newBackedUpAsset('deleted', ['camera']);
      await newBackedUpAsset('on-card', ['card']);
      stubDevice([deviceAlbum('camera', 'Camera', assetCount: 1)]);
    });

    for (final full in [false, true]) {
      test('${full ? 'full' : 'delta'} sync queues every backed-up asset that it removes', () async {
        await sut.sync(full: full);

        expect(await localAssetIds(), {'kept'});
        expect(await queuedAlbumNames(), {'remote-deleted': 'Camera', 'remote-on-card': 'Card'});
      });
    }

    test('removes but does not queue the assets that the device check finds', () async {
      when(() => nativeSyncApi.getMissingAssetIds(any(), any())).thenAnswer(
        (invocation) async => [
          for (final asset in invocation.positionalArguments.first as List<PlatformAssetFile>)
            if (asset.albumId != 'card') asset.id,
        ],
      );

      await sut.sync();

      expect(await localAssetIds(), {'kept'});
      expect(await queuedAlbumNames(), {'remote-deleted': 'Camera'});
    });

    test('skips the assets that the app deleted itself and drops their exclusions', () async {
      await localDeletionRepository.markExcluded(['deleted', 'kept']);

      await sut.sync();

      expect(await queuedAlbumNames(), {'remote-on-card': 'Card'});
      final exclusions = await ctx.db.select(ctx.db.localDeletionExclusionEntity).get();
      expect(exclusions.map((row) => row.localId), ['kept']);
    });

    test('does not queue the assets removed from an album without backup', () async {
      await ctx.newLocalAlbum(id: 'downloads', name: 'Downloads');
      await newBackedUpAsset('downloaded', ['downloads']);

      await sut.sync();

      expect(await localAssetIds(), {'kept'});
      expect(await queuedAlbumNames(), {'remote-deleted': 'Camera', 'remote-on-card': 'Card'});
    });

    test('delta sync queues an asset that moved to an album without backup', () async {
      stubDevice(
        [deviceAlbum('camera', 'Camera', assetCount: 1), deviceAlbum('downloads', 'Downloads', assetCount: 1)],
        deltaUpdates: [deviceAsset('deleted')],
        deltaAssetAlbums: {
          'deleted': ['downloads'],
        },
      );
      when(() => nativeSyncApi.getAssetIdsForAlbum('downloads')).thenAnswer((_) async => ['deleted']);

      await sut.sync();

      expect(await localAssetIds(), {'kept', 'deleted'});
      expect(await queuedAlbumNames(), {'remote-deleted': 'Camera', 'remote-on-card': 'Card'});
      final backupAlbumIds = verify(() => nativeSyncApi.getMissingAssetIds(any(), captureAny())).captured.first;
      expect(backupAlbumIds, unorderedEquals(['camera', 'card']));
    });

    test('delta sync leaves an album alone whose assets cannot be listed', () async {
      when(() => nativeSyncApi.getAssetIdsForAlbum('camera')).thenAnswer((_) async => const []);

      await sut.sync();

      expect(await localAssetIds(), {'kept', 'deleted'});
      expect(await queuedAlbumNames(), {'remote-on-card': 'Card'});
    });

    test('full sync queues the assets of an emptied album', () async {
      stubDevice([deviceAlbum('camera', 'Camera', assetCount: 0)]);

      await sut.sync(full: true);

      expect(await localAssetIds(), isEmpty);
      expect((await queuedAlbumNames()).keys, unorderedEquals(['remote-kept', 'remote-deleted', 'remote-on-card']));
    });

    test('queues nothing while the option is off', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);

      await sut.sync();

      expect(await localAssetIds(), {'kept'});
      expect(await queued(), isEmpty);
    });

    test('queues nothing when the option was turned off during the sync', () async {
      await turnOffInAnotherIsolate(SettingsKey.backupSyncLocalDeletions);

      await sut.sync();

      expect(await queued(), isEmpty);
    });

    test('queues nothing without full photo access', () async {
      when(() => devicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.limited);

      await sut.sync();

      expect(await queued(), isEmpty);
    });
  });

  group('confirmation', () {
    Future<void> newRemovedAlbum(String albumId, int assetCount) async {
      await newBackupAlbum(albumId);
      for (int i = 0; i < assetCount; i++) {
        await newBackedUpAsset('$albumId-$i', [albumId]);
      }
    }

    Future<int> heldCount() async => (await queued()).where((row) => row.awaitingConfirmation).length;

    setUp(() => stubDevice(const []));

    test('holds back the deletions of a sync once they reach 50', () async {
      await newRemovedAlbum('camera', 30);
      await newRemovedAlbum('downloads', 20);

      await sut.sync();

      expect(await heldCount(), 50);
    });

    test('does not count the assets that the device check finds', () async {
      await newRemovedAlbum('camera', 60);
      when(() => nativeSyncApi.getMissingAssetIds(any(), any())).thenAnswer(
        (invocation) async => [
          for (final asset in (invocation.positionalArguments.first as List<PlatformAssetFile>).skip(11)) asset.id,
        ],
      );

      await sut.sync();

      expect(await queued(), hasLength(49));
      expect(await heldCount(), 0);
    });

    test('holds back every deletion while others await confirmation', () async {
      await ctx.newLocalDeletion(remoteId: 'remote-held', ownerId: ownerId, awaitingConfirmation: true);
      await newRemovedAlbum('camera', 1);

      await sut.sync();

      expect(await heldCount(), 2);
    });
  });

  group('iOS', () {
    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

      await newBackupAlbum('recents', name: 'Recents');
      await newBackupAlbum('trip', name: 'Trip');
      await newBackedUpAsset('kept', ['recents', 'trip']);
      await newBackedUpAsset('deleted', ['recents', 'trip']);
    });

    test('delta sync queues the reported deletions under the album they were in', () async {
      stubDevice(
        [deviceAlbum('recents', 'Recents', assetCount: 1), deviceAlbum('trip', 'Trip', assetCount: 1)],
        deltaDeletes: ['deleted'],
      );

      await sut.sync();

      expect(await localAssetIds(), {'kept'});
      expect(await queuedAlbumNames(), {'remote-deleted': 'Trip'});
    });

    test('delta sync does not queue a deletion that the same delta brings back', () async {
      stubDevice(
        [deviceAlbum('recents', 'Recents', assetCount: 2), deviceAlbum('trip', 'Trip', assetCount: 2)],
        deltaDeletes: ['deleted'],
        deltaUpdates: [deviceAsset('deleted')],
      );
      when(() => nativeSyncApi.getMissingAssetIds(any(), any())).thenAnswer((_) async => const []);

      await sut.sync();

      expect(await localAssetIds(), {'kept', 'deleted'});
      expect(await queued(), isEmpty);
    });

    test('full sync queues an asset under the album it was in before any album dropped it', () async {
      stubDevice([deviceAlbum('recents', 'Recents', assetCount: 1), deviceAlbum('trip', 'Trip', assetCount: 1)]);

      await sut.sync(full: true);

      expect(await localAssetIds(), {'kept'});
      expect(await queuedAlbumNames(), {'remote-deleted': 'Trip'});
    });

    group('shared albums', () {
      setUp(() async {
        await newBackupAlbum('shared', name: 'Shared', isIosSharedAlbum: true);
        await newBackedUpAsset('removed', ['shared']);
        await ctx.newLocalAlbumAsset(albumId: 'shared', assetId: 'kept');
        stubDevice([
          deviceAlbum('recents', 'Recents', assetCount: 2),
          deviceAlbum('trip', 'Trip', assetCount: 2),
          deviceAlbum('shared', 'Shared', assetCount: 1, isCloud: true),
        ]);
      });

      test('delta sync queues their removals when the option is on', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);

        await sut.sync();

        expect(await localAssetIds(), {'kept', 'deleted'});
        expect(await queuedAlbumNames(), {'remote-removed': 'Shared'});
      });

      test('delta sync notices a removal next to additions that carry old dates', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubDevice([deviceAlbum('shared', 'Shared', assetCount: 3, isCloud: true)]);
        when(() => nativeSyncApi.getAssetsCountSince('shared', any())).thenAnswer((_) async => 1);
        when(
          () => nativeSyncApi.getAssetsForAlbum('shared', updatedTimeCond: any(named: 'updatedTimeCond')),
        ).thenAnswer((_) async => [deviceAsset('kept'), deviceAsset('added-1'), deviceAsset('added-2')]);

        await sut.sync();

        expect(await queuedAlbumNames(), {'remote-removed': 'Shared'});
      });

      test('delta sync does not queue their removals while the option is off', () async {
        await sut.sync();

        expect(await localAssetIds(), {'kept', 'deleted'});
        expect(await queued(), isEmpty);
      });

      test('delta sync queues only the other deletions when the option was turned off during the sync', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        await turnOffInAnotherIsolate(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums);
        stubDevice(
          [
            deviceAlbum('recents', 'Recents', assetCount: 1),
            deviceAlbum('trip', 'Trip', assetCount: 1),
            deviceAlbum('shared', 'Shared', assetCount: 1, isCloud: true),
          ],
          deltaDeletes: ['deleted', 'removed'],
        );

        await sut.sync();

        expect(await queuedAlbumNames(), {'remote-deleted': 'Trip'});
      });
    });
  });
}
