import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/app/settings.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/asset.stub.dart';
import '../../fixtures/user.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';
import '../../service.mocks.dart';

void main() {
  late LocalSyncService sut;
  late LocalAlbumRepository mockLocalAlbumRepository;
  late TrashedLocalAssetRepository mockTrashedLocalAssetRepository;
  late AssetMediaRepository mockAssetMediaRepository;
  late MockPermissionRepository mockPermissionRepository;
  late MockDevicePermissionService mockDevicePermissionService;
  late MockLocalDeletionRepository mockLocalDeletionRepository;
  late MockNativeSyncApi mockNativeSyncApi;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await SettingsRepository.ensureInitialized(db);
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await Store.clear();
    await db.close();
  });

  setUp(() async {
    mockLocalAlbumRepository = MockLocalAlbumRepository();
    mockTrashedLocalAssetRepository = MockTrashedLocalAssetRepository();
    mockAssetMediaRepository = MockAssetMediaRepository();
    mockPermissionRepository = MockPermissionRepository();
    mockDevicePermissionService = MockDevicePermissionService();
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
      trashedLocalAssetRepository: mockTrashedLocalAssetRepository,
      assetMediaRepository: mockAssetMediaRepository,
      permissionRepository: mockPermissionRepository,
      devicePermissionService: mockDevicePermissionService,
      localDeletionRepository: mockLocalDeletionRepository,
      nativeSyncApi: mockNativeSyncApi,
    );

    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);
    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, false);
    await Store.put(StoreKey.currentUser, UserStub.admin);
    when(() => mockLocalDeletionRepository.upsert(any(), any())).thenAnswer((_) async {});
    when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => <String>{});
    when(() => mockLocalDeletionRepository.consumeExcluded(any())).thenAnswer((_) async {});
    when(
      () => mockLocalDeletionRepository.snapshotBackedUpAssets(
        any(),
        includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
      ),
    ).thenAnswer((_) async => 1);
    when(
      () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()),
    ).thenAnswer((_) async => (candidates: <SnapshotCandidate>[], total: 0));
    when(() => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions(any())).thenAnswer((_) async {});
    when(() => mockNativeSyncApi.getExistingAssetIds(any())).thenAnswer((_) async => <String>[]);
    when(
      () => mockLocalDeletionRepository.getBackedUp(
        any(),
        any(),
        includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
      ),
    ).thenAnswer((_) async => {});

    await Store.put(StoreKey.manageLocalMediaAndroid, false);
    when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => false);
    when(() => mockDevicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.granted);
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

    test('continues the device sync when syncTrashedAssets fails', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => true);
      when(() => mockNativeSyncApi.getTrashedAssets()).thenThrow(PlatformException(code: 'deleteWithIds failed'));

      await sut.sync();

      // The rest of the sync, including deletion detection, must still run.
      verify(() => mockNativeSyncApi.getMediaChanges()).called(1);
    });

    test('aborts the device sync when syncTrashedAssets reports cancellation', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => true);
      when(() => mockNativeSyncApi.getTrashedAssets()).thenThrow(PlatformException(code: 'SYNC_CANCELLED'));

      await sut.sync();

      verifyNever(() => mockNativeSyncApi.getMediaChanges());
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

  List<String> localIds(int count) => [for (int i = 0; i < count; i++) 'local-$i'];
  Map<String, String> backedUp(int count) => {for (int i = 0; i < count; i++) 'remote-$i': 'checksum-$i'};

  // [vanished] of the [total] backed-up library assets are among the deletions, plus [shared] backed-up copies in iOS
  // shared albums, which only count when those are included
  void stubBackedUp(int vanished, {required int total, int shared = 0}) {
    when(
      () => mockLocalDeletionRepository.getBackedUp(any(), any(), includeIosSharedAlbums: false),
    ).thenAnswer((_) async => backedUp(vanished));
    when(
      () => mockLocalDeletionRepository.getBackedUp(any(), any(), includeIosSharedAlbums: true),
    ).thenAnswer((_) async => backedUp(vanished + shared));
    when(() => mockLocalDeletionRepository.countBackedUp(any())).thenAnswer((_) async => total);
  }

  // The settings page runs in the main isolate, the sync in a worker isolate whose cached settings do not see the change
  Future<void> changeOnSettingsPage(SettingsKey<bool> key, {required bool enabled}) async {
    await (db.delete(db.settingsEntity)..where((row) => row.key.equals(key.name))).go();
    if (enabled) {
      await db
          .into(db.settingsEntity)
          .insert(
            SettingsEntityCompanion.insert(
              key: key.name,
              value: drift.Value(key.encode(true)),
              updatedAt: drift.Value(DateTime.now()),
            ),
          );
    }
  }

  group('LocalSyncService - record locally deleted assets', () {
    setUp(() async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
    });

    test('queues backed-up deleted assets as pending deletions', () async {
      when(
        () => mockLocalDeletionRepository.getBackedUp(
          any(),
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      ).thenAnswer((_) async => {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'});

      await sut.recordLocallyDeletedFromDelta(['local-1', 'local-2'], 'owner-1');

      verify(
        () => mockLocalDeletionRepository.upsert('owner-1', {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'}),
      ).called(1);
    });

    test('skips app-initiated deletions and returns them for later cleanup', () async {
      when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => {'local-excluded'});
      when(
        () => mockLocalDeletionRepository.getBackedUp(
          any(),
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      ).thenAnswer((_) async => {'r-1': 'c-1'});

      final excluded = await sut.recordLocallyDeletedFromDelta(['local-excluded', 'local-1'], 'owner-1');

      expect(excluded, {'local-excluded'});
      verify(
        () => mockLocalDeletionRepository.getBackedUp('owner-1', ['local-1'], includeIosSharedAlbums: false),
      ).called(1);
    });

    test('does not resolve anything when every deletion is app-initiated', () async {
      when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => {'local-excluded'});

      final excluded = await sut.recordLocallyDeletedFromDelta(['local-excluded'], 'owner-1');

      expect(excluded, {'local-excluded'});
      verifyNever(
        () => mockLocalDeletionRepository.getBackedUp(
          any(),
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      );
      verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
    });

    test('queues nothing when the setting was turned off during the sync', () async {
      when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => {'local-excluded'});
      when(
        () => mockLocalDeletionRepository.getBackedUp(
          any(),
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      ).thenAnswer((_) async {
        await changeOnSettingsPage(SettingsKey.backupSyncLocalDeletions, enabled: false);
        return {'r-1': 'c-1'};
      });

      final excluded = await sut.recordLocallyDeletedFromDelta(['local-excluded', 'local-1'], 'owner-1');

      expect(excluded, {'local-excluded'});
      verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
    });

    test('leaves out iOS shared albums when their option was turned off during the sync', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
      stubBackedUp(1, total: 100, shared: 2);
      await changeOnSettingsPage(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, enabled: false);

      await sut.recordLocallyDeletedFromDelta(localIds(3), 'owner-1');

      verify(() => mockLocalDeletionRepository.upsert('owner-1', backedUp(1))).called(1);
    });

    test('does not add iOS shared albums when their option was turned on during the sync', () async {
      stubBackedUp(1, total: 100, shared: 2);
      // Too late for the shared albums that left the device to be excluded
      await changeOnSettingsPage(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, enabled: true);

      await sut.recordLocallyDeletedFromDelta(localIds(3), 'owner-1');

      verifyNever(() => mockLocalDeletionRepository.getBackedUp(any(), any(), includeIosSharedAlbums: true));
      verify(() => mockLocalDeletionRepository.upsert('owner-1', backedUp(1))).called(1);
    });

    group('mass vanish guard', () {
      test('skips queuing when almost every backed-up asset vanished at once', () async {
        when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => {'local-excluded'});
        stubBackedUp(91, total: 100);

        final excluded = await sut.recordLocallyDeletedFromDelta([...localIds(91), 'local-excluded'], 'owner-1');

        // The exclusions are still returned, as processDelta removes their rows anyway
        expect(excluded, {'local-excluded'});
        verify(() => mockLocalDeletionRepository.countBackedUp('owner-1')).called(1);
        verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
      });

      test('skips queuing when 46 of 50 backed-up assets vanished', () async {
        stubBackedUp(46, total: 50);

        await sut.recordLocallyDeletedFromDelta(localIds(46), 'owner-1');

        verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
      });

      test('queues the deletions when at most 90 percent of the backed-up assets vanished', () async {
        stubBackedUp(90, total: 100);

        // Deletions without a backed-up copy do not count
        await sut.recordLocallyDeletedFromDelta(localIds(120), 'owner-1');

        verify(() => mockLocalDeletionRepository.upsert('owner-1', backedUp(90))).called(1);
      });

      test('queues the deletions of a library under 50 backed-up assets that vanished as a whole', () async {
        stubBackedUp(49, total: 49);

        await sut.recordLocallyDeletedFromDelta(localIds(49), 'owner-1');

        verify(() => mockLocalDeletionRepository.upsert('owner-1', backedUp(49))).called(1);
      });

      test('does not count the backed-up assets when too few vanished to trip the guard', () async {
        stubBackedUp(45, total: 50);

        await sut.recordLocallyDeletedFromDelta(localIds(100), 'owner-1');

        verifyNever(() => mockLocalDeletionRepository.countBackedUp(any()));
        verify(() => mockLocalDeletionRepository.upsert('owner-1', backedUp(45))).called(1);
      });

      test('measures the library alone when iOS shared albums are included', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        // The shared album copies among the deletions do not count, only the library does
        stubBackedUp(91, total: 100, shared: 200);

        await sut.recordLocallyDeletedFromDelta(localIds(291), 'owner-1');

        verify(
          () => mockLocalDeletionRepository.getBackedUp('owner-1', localIds(291), includeIosSharedAlbums: false),
        ).called(1);
        verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
      });

      test('queues the removals from iOS shared albums along with a library below the guard', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubBackedUp(40, total: 100, shared: 60);

        await sut.recordLocallyDeletedFromDelta(localIds(100), 'owner-1');

        verify(() => mockLocalDeletionRepository.upsert('owner-1', backedUp(100))).called(1);
      });
    });
  });

  void stubDeltaSync(List<String> deletes, {List<LocalAlbum> albums = const []}) {
    when(
      () => mockNativeSyncApi.getMediaChanges(),
    ).thenAnswer((_) async => SyncDelta(hasChanges: true, updates: const [], deletes: deletes, assetAlbums: const {}));
    when(() => mockNativeSyncApi.getAlbums()).thenAnswer((_) async => const []);
    when(() => mockLocalAlbumRepository.updateAll(any())).thenAnswer((_) async {});
    when(
      () => mockLocalAlbumRepository.processDelta(
        updates: any(named: 'updates'),
        deletes: any(named: 'deletes'),
        assetAlbums: any(named: 'assetAlbums'),
      ),
    ).thenAnswer((_) async {});
    when(() => mockLocalAlbumRepository.getAll()).thenAnswer((_) async => albums);
    when(() => mockNativeSyncApi.getAssetIdsForAlbum(any())).thenAnswer((_) async => const []);
    when(() => mockLocalAlbumRepository.syncDeletes(any(), any())).thenAnswer((_) async {});
    when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async {});
  }

  group('LocalSyncService - iOS delta path', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    });

    test('does nothing when the feature is disabled', () async {
      stubDeltaSync(const ['local-1']);

      await sut.sync();

      verifyNever(() => mockLocalDeletionRepository.getExcluded(any()));
      verifyNever(
        () => mockLocalDeletionRepository.getBackedUp(
          any(),
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      );
    });

    test('does nothing when there is no authenticated user even if enabled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      await Store.delete(StoreKey.currentUser);
      stubDeltaSync(const ['local-1']);

      await sut.sync();

      verifyNever(
        () => mockLocalDeletionRepository.getBackedUp(
          any(),
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      );
    });

    test('does nothing when photo access is limited even if enabled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      when(() => mockDevicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.limited);
      stubDeltaSync(const ['local-1']);

      await sut.sync();

      verifyNever(
        () => mockLocalDeletionRepository.getBackedUp(
          any(),
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      );
    });

    test('skips the permission check when the delta has no deletions', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      stubDeltaSync(const []);

      await sut.sync();

      verifyNever(() => mockDevicePermissionService.galleryStatus());
      verifyNever(() => mockLocalDeletionRepository.getExcluded(any()));
    });

    test('records deletions before processDelta removes the rows', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);

      stubDeltaSync(const ['local-1']);
      when(
        () => mockLocalDeletionRepository.getBackedUp(
          any(),
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      ).thenAnswer((_) async => {'remote-1': 'checksum-1'});

      await sut.sync();

      verifyInOrder([
        () => mockLocalDeletionRepository.getBackedUp(UserStub.admin.id, ['local-1'], includeIosSharedAlbums: false),
        () => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'}),
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: any(named: 'deletes'),
          assetAlbums: any(named: 'assetAlbums'),
        ),
        () => mockLocalDeletionRepository.consumeExcluded(any()),
      ]);
    });

    test('includes iOS shared albums when the setting is on', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);

      stubDeltaSync(const ['local-1']);

      await sut.sync();

      verify(
        () => mockLocalDeletionRepository.getBackedUp(UserStub.admin.id, ['local-1'], includeIosSharedAlbums: true),
      ).called(1);
    });

    test('removes the rows but queues nothing when almost every backed-up asset vanished at once', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
      // E.g. signed out of iCloud: the library leaves the device along with the shared albums
      final deletes = [...localIds(100), 'shared-1', 'shared-2'];
      stubDeltaSync(deletes);
      // Stands in for the exclusion rows of the shared albums that left the device
      when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => {'shared-1', 'shared-2'});
      stubBackedUp(100, total: 100);

      await sut.sync();

      verify(
        () => mockLocalDeletionRepository.getBackedUp(UserStub.admin.id, localIds(100), includeIosSharedAlbums: false),
      ).called(1);
      verify(() => mockLocalDeletionRepository.countBackedUp(UserStub.admin.id)).called(1);
      verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
      verifyInOrder([
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: deletes,
          assetAlbums: any(named: 'assetAlbums'),
        ),
        () => mockLocalDeletionRepository.consumeExcluded({'shared-1', 'shared-2'}),
        () => mockNativeSyncApi.checkpointSync(),
      ]);
    });

    group('cloud albums', () {
      PlatformAsset platformAsset(String id) => PlatformAsset(
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

      final dbAlbum = LocalAlbum(
        id: 'shared-1',
        name: 'Shared',
        updatedAt: DateTime.utc(2026),
        assetCount: 2,
        isIosSharedAlbum: true,
      );

      setUpAll(() => registerFallbackValue(dbAlbum));

      void stubCloudAlbumSync({int deviceAssetCount = 1}) {
        // Another member removed a photo, the delta reports nothing
        stubDeltaSync(const [], albums: [dbAlbum]);
        when(() => mockNativeSyncApi.getAlbums()).thenAnswer(
          (_) async => [
            PlatformAlbum(
              id: 'shared-1',
              name: 'Shared',
              updatedAt: 1800000000,
              isCloud: true,
              assetCount: deviceAssetCount,
            ),
          ],
        );
        when(() => mockNativeSyncApi.getAssetsForAlbum('shared-1')).thenAnswer((_) async => [platformAsset('local-2')]);
        when(
          () => mockLocalAlbumRepository.getAssets('shared-1'),
        ).thenAnswer((_) async => [platformAsset('local-1').toLocalAsset(), platformAsset('local-2').toLocalAsset()]);
        when(() => mockLocalAlbumRepository.getAssetIds('shared-1')).thenAnswer((_) async => ['local-1', 'local-2']);
        when(() => mockLocalAlbumRepository.upsert(any(), toDelete: any(named: 'toDelete'))).thenAnswer((_) async {});
        when(
          () => mockLocalAlbumRepository.upsert(
            any(),
            toUpsert: any(named: 'toUpsert'),
            toDelete: any(named: 'toDelete'),
          ),
        ).thenAnswer((_) async {});
        when(() => mockLocalDeletionRepository.markExcluded(any())).thenAnswer((_) async {});
        // A shared album copy, which the library total leaves out
        when(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any())).thenAnswer(
          (_) async => (
            candidates: [(localId: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1', inIosSharedAlbum: true)],
            total: 0,
          ),
        );
      }

      test('snapshots around the cloud album sync when the setting is on', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubCloudAlbumSync();

        await sut.sync();

        verifyInOrder([
          () => mockLocalDeletionRepository.snapshotBackedUpAssets(UserStub.admin.id, includeIosSharedAlbums: true),
          () => mockLocalAlbumRepository.upsert(
            any(),
            toUpsert: any(named: 'toUpsert'),
            toDelete: ['local-1'],
          ),
          () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(1),
          () => mockNativeSyncApi.getExistingAssetIds(['local-1']),
          () => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'}),
          () => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions(1),
          () => mockNativeSyncApi.checkpointSync(),
        ]);
        verifyNever(() => mockLocalDeletionRepository.markExcluded(any()));
      });

      test('does not queue the removals when the option was turned off during the sync', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubCloudAlbumSync();
        when(() => mockNativeSyncApi.getExistingAssetIds(any())).thenAnswer((_) async {
          await changeOnSettingsPage(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, enabled: false);
          return <String>[];
        });

        await sut.sync();

        verifyNever(() => mockLocalDeletionRepository.upsert(any(), any(that: isNotEmpty)));
        verify(() => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions(1)).called(1);
      });

      test('excludes the assets of a shared album that empties as a whole', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubCloudAlbumSync(deviceAssetCount: 0);

        await sut.sync();

        verifyInOrder([
          () => mockLocalDeletionRepository.snapshotBackedUpAssets(UserStub.admin.id, includeIosSharedAlbums: true),
          () => mockLocalDeletionRepository.markExcluded(['local-1', 'local-2']),
          () => mockLocalAlbumRepository.upsert(any(), toDelete: ['local-1', 'local-2']),
          () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(1),
        ]);
      });

      test('skips the snapshot when the setting is off', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        stubCloudAlbumSync();

        await sut.sync();

        verify(
          () => mockLocalAlbumRepository.upsert(
            any(),
            toUpsert: any(named: 'toUpsert'),
            toDelete: ['local-1'],
          ),
        ).called(1);
        verifyNever(
          () => mockLocalDeletionRepository.snapshotBackedUpAssets(
            any(),
            includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
          ),
        );
        verifyNever(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()));
      });

      test('skips the snapshot when the feature is disabled', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubCloudAlbumSync();

        await sut.sync();

        verifyNever(
          () => mockLocalDeletionRepository.snapshotBackedUpAssets(
            any(),
            includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
          ),
        );
        verifyNever(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()));
      });

      test('diffs a changed shared album in full instead of only adding its newer assets', () async {
        stubCloudAlbumSync(deviceAssetCount: 3);
        when(() => mockNativeSyncApi.getAssetsCountSince(any(), any())).thenAnswer((_) async => 1);

        await sut.sync();

        verifyNever(() => mockNativeSyncApi.getAssetsCountSince(any(), any()));
        verify(
          () => mockLocalAlbumRepository.upsert(
            any(),
            toUpsert: any(named: 'toUpsert'),
            toDelete: ['local-1'],
          ),
        ).called(1);
      });

      test('excludes the assets of a shared album that vanished after it was counted', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubCloudAlbumSync();
        when(() => mockNativeSyncApi.getAssetsForAlbum('shared-1')).thenAnswer((_) async => []);

        await sut.sync();

        verifyInOrder([
          () => mockLocalDeletionRepository.markExcluded(['local-1', 'local-2']),
          () => mockLocalAlbumRepository.upsert(any(), toDelete: ['local-1', 'local-2']),
          () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(1),
        ]);
      });

      test('still detects and queues deletions when cancelled', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);

        final cancellation = Completer<void>()..complete();
        when(() => mockNativeSyncApi.cancelSync()).thenAnswer((_) async {});
        final cancelledSut = LocalSyncService(
          localAlbumRepository: mockLocalAlbumRepository,
          trashedLocalAssetRepository: mockTrashedLocalAssetRepository,
          assetMediaRepository: mockAssetMediaRepository,
          permissionRepository: mockPermissionRepository,
          devicePermissionService: mockDevicePermissionService,
          localDeletionRepository: mockLocalDeletionRepository,
          nativeSyncApi: mockNativeSyncApi,
          cancellation: cancellation,
        );
        stubCloudAlbumSync();

        await cancelledSut.sync();

        verify(() => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'})).called(1);
        verify(() => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions(1)).called(1);
        verifyNever(() => mockNativeSyncApi.getAssetsForAlbum(any()));
        verifyNever(() => mockNativeSyncApi.checkpointSync());
      });
    });

    group('shared album that left the device', () {
      final sharedAlbum = LocalAlbum(
        id: 'shared-1',
        name: 'Shared',
        updatedAt: DateTime.utc(2026),
        assetCount: 2,
        isIosSharedAlbum: true,
      );

      setUpAll(() => registerFallbackValue(sharedAlbum));

      void stubRemovedSharedAlbum({List<PlatformAlbum> deviceAlbums = const []}) {
        // The delta reports the assets of the album as deleted
        stubDeltaSync(const ['local-1', 'local-2'], albums: [sharedAlbum]);
        when(() => mockNativeSyncApi.getAlbums()).thenAnswer((_) async => deviceAlbums);
        when(() => mockLocalAlbumRepository.getAssetIds('shared-1')).thenAnswer((_) async => ['local-1', 'local-2']);
        when(() => mockLocalAlbumRepository.getAssets('shared-1')).thenAnswer((_) async => []);
        when(() => mockLocalAlbumRepository.upsert(any(), toDelete: any(named: 'toDelete'))).thenAnswer((_) async {});
        when(() => mockLocalDeletionRepository.markExcluded(any())).thenAnswer((_) async {});
      }

      test('excludes its assets before the deletions are recorded when the setting is on', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubRemovedSharedAlbum();
        // Stands in for the exclusion rows that markExcluded writes
        when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => {'local-1', 'local-2'});

        await sut.sync();

        verifyInOrder([
          () => mockLocalDeletionRepository.markExcluded(['local-1', 'local-2']),
          () => mockLocalDeletionRepository.getExcluded(['local-1', 'local-2']),
          () => mockLocalAlbumRepository.updateAll(any()),
          () => mockLocalAlbumRepository.processDelta(
            updates: any(named: 'updates'),
            deletes: ['local-1', 'local-2'],
            assetAlbums: any(named: 'assetAlbums'),
          ),
          () => mockLocalDeletionRepository.consumeExcluded({'local-1', 'local-2'}),
        ]);
      });

      test('excludes the assets of a shared album that the device lists empty', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubRemovedSharedAlbum(
          deviceAlbums: [
            PlatformAlbum(id: 'shared-1', name: 'Shared', updatedAt: 1800000000, isCloud: true, assetCount: 0),
          ],
        );

        await sut.sync();

        verifyInOrder([
          () => mockLocalDeletionRepository.markExcluded(['local-1', 'local-2']),
          () => mockLocalDeletionRepository.getExcluded(['local-1', 'local-2']),
          () => mockLocalAlbumRepository.updateAll(any()),
        ]);
      });

      test('still queues the removals from a shared album that is on the device', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        // Count and newest date unchanged, so the cloud album sync skips the album
        stubRemovedSharedAlbum(
          deviceAlbums: [
            PlatformAlbum(id: 'shared-1', name: 'Shared', updatedAt: 1767225600, isCloud: true, assetCount: 2),
          ],
        );

        await sut.sync();

        verify(
          () => mockLocalDeletionRepository.getBackedUp(UserStub.admin.id, [
            'local-1',
            'local-2',
          ], includeIosSharedAlbums: true),
        ).called(1);
        verifyNever(() => mockLocalDeletionRepository.markExcluded(any()));
      });

      test('does not exclude the assets of a regular album that the device lists empty', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        final regularAlbum = LocalAlbum(id: 'album-1', name: 'Camera', updatedAt: DateTime.utc(2026), assetCount: 2);
        stubDeltaSync(const ['local-1', 'local-2'], albums: [regularAlbum]);
        when(() => mockNativeSyncApi.getAlbums()).thenAnswer(
          (_) async => [
            PlatformAlbum(id: 'album-1', name: 'Camera', updatedAt: 1800000000, isCloud: false, assetCount: 0),
          ],
        );
        when(() => mockLocalAlbumRepository.getAssetIds('album-1')).thenAnswer((_) async => ['local-1', 'local-2']);
        when(() => mockLocalDeletionRepository.markExcluded(any())).thenAnswer((_) async {});

        await sut.sync();

        verifyNever(() => mockLocalDeletionRepository.markExcluded(any()));
        verify(
          () => mockLocalDeletionRepository.getBackedUp(UserStub.admin.id, [
            'local-1',
            'local-2',
          ], includeIosSharedAlbums: true),
        ).called(1);
      });

      test('does not exclude anything without full photo access, as no detection consumes it', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        when(() => mockDevicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.limited);
        stubRemovedSharedAlbum();

        await sut.sync();

        verifyNever(() => mockLocalDeletionRepository.markExcluded(any()));
        verifyNever(() => mockLocalDeletionRepository.getExcluded(any()));
      });

      test('filters its assets before updateAll can drop the album links when the setting is off', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        stubRemovedSharedAlbum();

        await sut.sync();

        verifyInOrder([
          () => mockLocalDeletionRepository.getBackedUp(UserStub.admin.id, [
            'local-1',
            'local-2',
          ], includeIosSharedAlbums: false),
          () => mockLocalAlbumRepository.updateAll(any()),
        ]);
        verifyNever(() => mockLocalDeletionRepository.markExcluded(any()));
        // Only the album sync after processDelta reads the stored albums
        verify(() => mockLocalAlbumRepository.getAll()).called(1);
      });
    });
  });

  group('LocalSyncService - Android delta path', () {
    final album = LocalAlbum(id: 'album-1', name: 'Camera', updatedAt: DateTime(2026));

    void stubCandidates() {
      when(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any())).thenAnswer(
        (_) async => (
          candidates: [(localId: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1', inIosSharedAlbum: false)],
          total: 1,
        ),
      );
    }

    test('snapshots before reconciliation, then detects and queues deletions', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      // The delta never reports deletions, the album reconciliation removes their rows
      stubDeltaSync(const [], albums: [album]);
      stubCandidates();

      await sut.sync();

      verifyInOrder([
        () => mockLocalDeletionRepository.snapshotBackedUpAssets(UserStub.admin.id, includeIosSharedAlbums: false),
        () => mockLocalAlbumRepository.updateAll(any()),
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: any(named: 'deletes'),
          assetAlbums: any(named: 'assetAlbums'),
        ),
        () => mockLocalAlbumRepository.syncDeletes('album-1', any()),
        () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(1),
        () => mockNativeSyncApi.getExistingAssetIds(['local-1']),
        () => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'}),
        () => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions(1),
        () => mockNativeSyncApi.checkpointSync(),
      ]);
    });

    test('does not queue the deletions when the setting was turned off during the sync', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      stubDeltaSync(const [], albums: [album]);
      stubCandidates();
      when(() => mockNativeSyncApi.getExistingAssetIds(any())).thenAnswer((_) async {
        await changeOnSettingsPage(SettingsKey.backupSyncLocalDeletions, enabled: false);
        return <String>[];
      });

      await sut.sync();

      verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
      verify(() => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions(1)).called(1);
    });

    test('re-verifies the reported deletes instead of queuing them directly', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      stubDeltaSync(const ['invalid-1']);

      await sut.sync();

      verify(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any())).called(1);
      verifyNever(() => mockLocalDeletionRepository.getExcluded(any()));
      verifyNever(
        () => mockLocalDeletionRepository.getBackedUp(
          any(),
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      );
    });

    test('skips snapshot and detection when the feature is disabled', () async {
      stubDeltaSync(const [], albums: [album]);

      await sut.sync();

      verifyNever(
        () => mockLocalDeletionRepository.snapshotBackedUpAssets(
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      );
      verifyNever(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()));
      verify(() => mockLocalAlbumRepository.syncDeletes('album-1', any())).called(1);
    });

    test('skips snapshot and detection when photo access is limited', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      when(() => mockDevicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.limited);
      stubDeltaSync(const [], albums: [album]);

      await sut.sync();

      verifyNever(
        () => mockLocalDeletionRepository.snapshotBackedUpAssets(
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      );
      verifyNever(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()));
    });

    test('still detects and queues deletions when cancelled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);

      final cancellation = Completer<void>()..complete();
      when(() => mockNativeSyncApi.cancelSync()).thenAnswer((_) async {});
      final cancelledSut = LocalSyncService(
        localAlbumRepository: mockLocalAlbumRepository,
        trashedLocalAssetRepository: mockTrashedLocalAssetRepository,
        assetMediaRepository: mockAssetMediaRepository,
        permissionRepository: mockPermissionRepository,
        devicePermissionService: mockDevicePermissionService,
        localDeletionRepository: mockLocalDeletionRepository,
        nativeSyncApi: mockNativeSyncApi,
        cancellation: cancellation,
      );
      stubDeltaSync(const [], albums: [album]);
      stubCandidates();

      await cancelledSut.sync();

      verify(() => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'})).called(1);
      verifyNever(() => mockLocalAlbumRepository.syncDeletes(any(), any()));
      verifyNever(() => mockNativeSyncApi.checkpointSync());
    });
  });

  group('LocalSyncService - full sync path', () {
    void stubFullSync() {
      when(() => mockNativeSyncApi.getAlbums()).thenAnswer((_) async => const []);
      when(
        () => mockLocalAlbumRepository.getAll(sortBy: const {SortLocalAlbumsBy.id}),
      ).thenAnswer((_) async => const []);
      when(() => mockNativeSyncApi.checkpointSync()).thenAnswer((_) async {});
    }

    test('snapshots before reconciliation, then detects and queues deletions', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);

      stubFullSync();
      when(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any())).thenAnswer(
        (_) async => (
          candidates: [(localId: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1', inIosSharedAlbum: false)],
          total: 1,
        ),
      );

      await sut.fullSync();

      verifyInOrder([
        () => mockLocalDeletionRepository.snapshotBackedUpAssets(UserStub.admin.id, includeIosSharedAlbums: false),
        () => mockNativeSyncApi.getAlbums(),
        () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(1),
        () => mockNativeSyncApi.getExistingAssetIds(['local-1']),
        () => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'}),
        () => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions(1),
        () => mockNativeSyncApi.checkpointSync(),
      ]);
    });

    test('includes iOS shared albums in the snapshot when the setting is on', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);

      stubFullSync();

      await sut.fullSync();

      verify(
        () => mockLocalDeletionRepository.snapshotBackedUpAssets(UserStub.admin.id, includeIosSharedAlbums: true),
      ).called(1);
    });

    group('shared album that left the device', () {
      final sharedAlbum = LocalAlbum(
        id: 'shared-1',
        name: 'Shared',
        updatedAt: DateTime.utc(2026),
        assetCount: 1,
        isIosSharedAlbum: true,
      );

      void stubRemovedSharedAlbum() {
        stubFullSync();
        when(
          () => mockLocalAlbumRepository.getAll(sortBy: const {SortLocalAlbumsBy.id}),
        ).thenAnswer((_) async => [sharedAlbum]);
        when(() => mockLocalAlbumRepository.getAssetIds('shared-1')).thenAnswer((_) async => ['local-1']);
        when(() => mockLocalAlbumRepository.deleteAlbum(any())).thenAnswer((_) async {});
        when(() => mockLocalDeletionRepository.markExcluded(any())).thenAnswer((_) async {});
      }

      test('excludes its assets before they are removed when the setting is on', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubRemovedSharedAlbum();

        await sut.fullSync();

        verifyInOrder([
          () => mockLocalDeletionRepository.snapshotBackedUpAssets(UserStub.admin.id, includeIosSharedAlbums: true),
          () => mockLocalDeletionRepository.markExcluded(['local-1']),
          () => mockLocalAlbumRepository.deleteAlbum('shared-1'),
          () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(1),
        ]);
      });

      test('does not exclude anything when the setting is off', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        stubRemovedSharedAlbum();

        await sut.fullSync();

        verify(() => mockLocalAlbumRepository.deleteAlbum('shared-1')).called(1);
        verifyNever(() => mockLocalDeletionRepository.markExcluded(any()));
      });

      test('does not exclude anything without full photo access, as no detection consumes it', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        when(() => mockDevicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.limited);
        stubRemovedSharedAlbum();

        await sut.fullSync();

        verify(() => mockLocalAlbumRepository.deleteAlbum('shared-1')).called(1);
        verifyNever(() => mockLocalDeletionRepository.markExcluded(any()));
      });
    });

    test('skips snapshot and detection when the feature is disabled', () async {
      stubFullSync();

      await sut.fullSync();

      verifyNever(
        () => mockLocalDeletionRepository.snapshotBackedUpAssets(
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      );
      verifyNever(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()));
    });

    test('skips snapshot and detection when photo access is limited', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      when(() => mockDevicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.limited);
      stubFullSync();

      await sut.fullSync();

      verifyNever(
        () => mockLocalDeletionRepository.snapshotBackedUpAssets(
          any(),
          includeIosSharedAlbums: any(named: 'includeIosSharedAlbums'),
        ),
      );
      verifyNever(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()));
    });

    test('still detects and queues deletions when cancelled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);

      final cancellation = Completer<void>()..complete();
      when(() => mockNativeSyncApi.cancelSync()).thenAnswer((_) async {});
      final cancelledSut = LocalSyncService(
        localAlbumRepository: mockLocalAlbumRepository,
        trashedLocalAssetRepository: mockTrashedLocalAssetRepository,
        assetMediaRepository: mockAssetMediaRepository,
        permissionRepository: mockPermissionRepository,
        devicePermissionService: mockDevicePermissionService,
        localDeletionRepository: mockLocalDeletionRepository,
        nativeSyncApi: mockNativeSyncApi,
        cancellation: cancellation,
      );

      stubFullSync();
      when(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any())).thenAnswer(
        (_) async => (
          candidates: [(localId: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1', inIosSharedAlbum: false)],
          total: 1,
        ),
      );

      await cancelledSut.fullSync();

      // The detected deletions are persisted for the next run.
      verify(
        () => mockLocalDeletionRepository.snapshotBackedUpAssets(UserStub.admin.id, includeIosSharedAlbums: false),
      ).called(1);
      verify(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any())).called(1);
      verify(() => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'})).called(1);
    });

    test('does not queue candidates the device still reports as present', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);

      stubFullSync();
      when(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any())).thenAnswer(
        (_) async => (
          candidates: [
            (localId: 'hidden-1', remoteId: 'remote-1', checksum: 'checksum-1', inIosSharedAlbum: false),
            (localId: 'gone-2', remoteId: 'remote-2', checksum: 'checksum-2', inIosSharedAlbum: false),
          ],
          total: 2,
        ),
      );
      // hidden-1 is still on the device (e.g. hidden on iOS); only gone-2 is really deleted.
      when(() => mockNativeSyncApi.getExistingAssetIds(any())).thenAnswer((_) async => ['hidden-1']);

      await sut.fullSync();

      verify(() => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-2': 'checksum-2'})).called(1);
      verify(() => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions(any())).called(1);
    });

    test('skips the deletion sync when almost every backed-up asset vanished at once', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);

      stubFullSync();
      final candidates = [
        for (int i = 0; i < 100; i++)
          (localId: 'local-$i', remoteId: 'remote-$i', checksum: 'checksum-$i', inIosSharedAlbum: false),
      ];
      when(
        () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()),
      ).thenAnswer((_) async => (candidates: candidates, total: 100));

      await sut.fullSync();

      // A near-total wipe is a device state change, not deletions. Nothing is
      // queued, but the snapshot is still cleared for the next run.
      verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
      verify(() => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions(any())).called(1);
    });

    group('with the copies in iOS shared albums', () {
      List<SnapshotCandidate> candidates({required int library, required int shared}) => [
        for (int i = 0; i < library + shared; i++)
          (localId: 'local-$i', remoteId: 'remote-$i', checksum: 'checksum-$i', inIosSharedAlbum: i >= library),
      ];

      setUp(() async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        stubFullSync();
      });

      test('skips the deletion sync when almost every backed-up library asset vanished at once', () async {
        // The total counts the library alone
        when(
          () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()),
        ).thenAnswer((_) async => (candidates: candidates(library: 91, shared: 200), total: 100));

        await sut.fullSync();

        verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
      });

      test('queues the removals from iOS shared albums along with a library below the guard', () async {
        when(
          () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(any()),
        ).thenAnswer((_) async => (candidates: candidates(library: 40, shared: 60), total: 100));

        await sut.fullSync();

        verify(() => mockLocalDeletionRepository.upsert(UserStub.admin.id, backedUp(100))).called(1);
      });
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
