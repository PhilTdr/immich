import 'dart:async';
import 'dart:io';

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
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' show ApiException;

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
  late MockServerInfoService mockServerInfoService;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    registerFallbackValue(<LocalAsset>[]);
    registerFallbackValue(<String>[]);
    registerFallbackValue(const Iterable<String>.empty());
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
    mockServerInfoService = MockServerInfoService();

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
      serverInfoService: mockServerInfoService,
    );

    when(() => mockServerInfoService.getServerFeatures()).thenAnswer(
      (_) async => const ServerFeatures(trash: true, map: false, oauthEnabled: false, passwordLogin: true),
    );

    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);
    await Store.put(StoreKey.currentUser, UserStub.admin);
    when(() => mockLocalDeletionRepository.upsert(any(), any())).thenAnswer((_) async {});
    when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer((_) async => []);
    when(() => mockLocalDeletionRepository.deleteByRemoteIds(any())).thenAnswer((_) async {});
    when(() => mockLocalDeletionRepository.pruneAlreadyTrashed()).thenAnswer((_) async {});
    when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => <String>{});
    when(() => mockLocalDeletionRepository.unmarkExcluded(any())).thenAnswer((_) async {});
    when(() => mockLocalDeletionRepository.snapshotBackedUpAssets(any())).thenAnswer((_) async {});
    when(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates()).thenAnswer(
      (_) async => (candidates: <({String localId, String remoteId, String checksum})>[], total: 0),
    );
    when(() => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions()).thenAnswer((_) async {});
    when(() => mockNativeSyncApi.getExistingAssetIds(any())).thenAnswer((_) async => <String>[]);
    when(() => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId'))).thenAnswer((_) async => []);
    when(() => mockLocalAssetRepository.getExistingChecksums(any())).thenAnswer((_) async => <String>{});
    when(() => mockLocalAssetRepository.getUnhashedCount()).thenAnswer((_) async => 0);

    await Store.put(StoreKey.manageLocalMediaAndroid, false);
    when(() => mockPermissionRepository.hasManageMediaPermission()).thenAnswer((_) async => false);
    when(() => mockPermissionRepository.hasFullMediaPermission()).thenAnswer((_) async => true);
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

  group('LocalSyncService - record locally deleted assets', () {
    test('queues backed-up deleted assets as pending deletions (no server call yet)', () async {
      final resolved = [
        LocalAssetStub.image1.copyWith(id: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1'),
        LocalAssetStub.image1.copyWith(id: 'local-2', remoteId: 'remote-2', checksum: 'checksum-2'),
      ];
      when(
        () => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')),
      ).thenAnswer((_) async => resolved);

      await sut.recordLocallyDeletedFromDelta(['local-1', 'local-2'], 'owner-1');

      verify(
        () => mockLocalDeletionRepository.upsert('owner-1', {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'}),
      ).called(1);
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
    });

    test('ignores deleted assets without a remote counterpart', () async {
      when(
        () => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')),
      ).thenAnswer((_) async => [LocalAssetStub.image1.copyWith(id: 'local-1')]);

      await sut.recordLocallyDeletedFromDelta(['local-1'], 'owner-1');

      verify(() => mockLocalDeletionRepository.upsert('owner-1', {})).called(1);
    });

    test('skips app-initiated deletions and returns them for later cleanup', () async {
      when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => {'local-excluded'});
      when(
        () => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')),
      ).thenAnswer((_) async => [LocalAssetStub.image1.copyWith(id: 'local-1', remoteId: 'r-1', checksum: 'c-1')]);

      final excluded = await sut.recordLocallyDeletedFromDelta(['local-excluded', 'local-1'], 'owner-1');

      expect(excluded, {'local-excluded'});
      verify(() => mockLocalAssetRepository.getByIds(['local-1'], ownerId: 'owner-1')).called(1);
    });

    test('does not resolve anything when every deletion is app-initiated', () async {
      when(() => mockLocalDeletionRepository.getExcluded(any())).thenAnswer((_) async => {'local-excluded'});

      final excluded = await sut.recordLocallyDeletedFromDelta(['local-excluded'], 'owner-1');

      expect(excluded, {'local-excluded'});
      verifyNever(() => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')));
      verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
    });
  });

  group('LocalSyncService - flush pending deletions', () {
    test('moves pending deletions to the server trash and clears their queue rows', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [(remoteId: 'remote-1', checksum: 'checksum-1'), (remoteId: 'remote-2', checksum: 'checksum-2')],
      );
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((_) async {});
      when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});

      await sut.flushPendingDeletions('owner-1');

      verifyInOrder([
        () => mockLocalDeletionRepository.pruneAlreadyTrashed(),
        () => mockAssetApiRepository.delete(['remote-1', 'remote-2'], false),
        () => mockRemoteAssetRepository.trash(['remote-1', 'remote-2']),
        () => mockLocalDeletionRepository.deleteByRemoteIds(['remote-1', 'remote-2']),
      ]);
    });

    test('cancels pending deletions whose content is still present locally', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [(remoteId: 'remote-1', checksum: 'checksum-1'), (remoteId: 'remote-2', checksum: 'checksum-2')],
      );
      // checksum-1 still exists locally -> cancel remote-1.
      when(() => mockLocalAssetRepository.getExistingChecksums(any())).thenAnswer((_) async => {'checksum-1'});
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((_) async {});
      when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});

      await sut.flushPendingDeletions('owner-1');

      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-1'])).called(1);
      verify(() => mockAssetApiRepository.delete(['remote-2'], false)).called(1);
      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-2'])).called(1);
    });

    test('leaves deletions queued when the server call fails', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1')]);
      when(() => mockAssetApiRepository.delete(any(), any())).thenThrow(Exception('network'));

      await sut.flushPendingDeletions('owner-1');

      // The queue row must survive a failed flush so it is retried on the next sync.
      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
    });

    test('keeps the queue when the client reports a transport failure as code 400', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1')]);
      when(
        () => mockAssetApiRepository.delete(any(), any()),
      ).thenThrow(ApiException.withInner(400, 'offline', const SocketException('offline'), StackTrace.empty));

      await sut.flushPendingDeletions('owner-1');

      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
    });

    test('drops intents the server rejects permanently and keeps flushing the rest', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [
          (remoteId: 'remote-dead', checksum: 'checksum-1'),
          (remoteId: 'remote-2', checksum: 'checksum-2'),
        ],
      );
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((invocation) async {
        final ids = invocation.positionalArguments.first as List<String>;
        if (ids.length > 1 || ids.single == 'remote-dead') {
          throw ApiException(400, 'Not found or no asset.delete access');
        }
      });
      when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});

      await sut.flushPendingDeletions('owner-1');

      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-dead'])).called(1);
      verify(() => mockRemoteAssetRepository.trash(['remote-2'])).called(1);
      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-2'])).called(1);
      verifyNever(() => mockRemoteAssetRepository.trash(['remote-dead']));
    });

    test('skips the flush and keeps the queue when the server has trash disabled', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1')]);
      when(() => mockServerInfoService.getServerFeatures()).thenAnswer(
        (_) async => const ServerFeatures(trash: false, map: false, oauthEnabled: false, passwordLogin: true),
      );

      await sut.flushPendingDeletions('owner-1');

      // A move-to-trash would be a permanent delete, so nothing is sent and the
      // queue survives for a retry once trash is enabled again.
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
    });

    test('skips the flush and keeps the queue when server features cannot be fetched', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1')]);
      when(() => mockServerInfoService.getServerFeatures()).thenAnswer((_) async => null);

      await sut.flushPendingDeletions('owner-1');

      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
    });

    test('flushes large queues in chunks', () async {
      final pending = [for (int i = 0; i < 1001; i++) (remoteId: 'remote-$i', checksum: 'checksum-$i')];
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer((_) async => pending);
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((_) async {});
      when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});

      await sut.flushPendingDeletions('owner-1');

      final calls = verify(() => mockAssetApiRepository.delete(captureAny(), false)).captured;
      expect(calls.length, 2);
      expect((calls[0] as List<String>).length, 1000);
      expect((calls[1] as List<String>).length, 1);
    });
  });

  group('LocalSyncService - delta path', () {
    void stubDeltaSync(List<String> deletes) {
      when(() => mockNativeSyncApi.getMediaChanges()).thenAnswer(
        (_) async => SyncDelta(hasChanges: true, updates: const [], deletes: deletes, assetAlbums: const {}),
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
    }

    test('does nothing when the feature is disabled', () async {
      stubDeltaSync(const ['local-1']);

      await sut.sync();

      verifyNever(() => mockLocalDeletionRepository.getExcluded(any()));
      verifyNever(() => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')));
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockLocalDeletionRepository.getPending(any()));
    });

    test('does nothing when there is no authenticated user even if enabled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));
      await Store.delete(StoreKey.currentUser);
      stubDeltaSync(const ['local-1']);

      await sut.sync();

      verifyNever(() => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')));
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
    });

    test('does nothing when photo access is limited even if enabled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));
      when(() => mockPermissionRepository.hasFullMediaPermission()).thenAnswer((_) async => false);
      stubDeltaSync(const ['local-1']);

      await sut.sync();

      verifyNever(() => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')));
      verifyNever(() => mockLocalDeletionRepository.getPending(any()));
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
    });

    test('defers the flush when the delta introduced new unhashed assets', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));

      stubDeltaSync(const ['local-1']);
      final deleted = LocalAssetStub.image1.copyWith(id: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1');
      when(
        () => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')),
      ).thenAnswer((_) async => [deleted]);
      // A moved file surfaces as delete + insert: The new row is unhashed.
      var unhashedCalls = 0;
      when(() => mockLocalAssetRepository.getUnhashedCount()).thenAnswer((_) async => unhashedCalls++ == 0 ? 0 : 1);

      await sut.sync();

      // The intent is recorded but not flushed until the hash service caught up.
      verify(() => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'})).called(1);
      verifyNever(() => mockLocalDeletionRepository.getPending(any()));
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
    });

    test('records deletions before processDelta removes the rows, then flushes', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));

      stubDeltaSync(const ['local-1']);
      final deleted = LocalAssetStub.image1.copyWith(id: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1');
      when(
        () => mockLocalAssetRepository.getByIds(any(), ownerId: any(named: 'ownerId')),
      ).thenAnswer((_) async => [deleted]);
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1')]);
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((_) async {});
      when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});

      await sut.sync();

      verifyInOrder([
        () => mockLocalAssetRepository.getByIds(['local-1'], ownerId: UserStub.admin.id),
        () => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'}),
        () => mockLocalAlbumRepository.processDelta(
          updates: any(named: 'updates'),
          deletes: any(named: 'deletes'),
          assetAlbums: any(named: 'assetAlbums'),
        ),
        () => mockLocalDeletionRepository.unmarkExcluded(any()),
        () => mockLocalDeletionRepository.getPending(UserStub.admin.id),
        () => mockAssetApiRepository.delete(['remote-1'], false),
        () => mockRemoteAssetRepository.trash(['remote-1']),
        () => mockLocalDeletionRepository.deleteByRemoteIds(['remote-1']),
      ]);
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

    test('snapshots before reconciliation, then queues and flushes deletions', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));

      stubFullSync();
      when(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates()).thenAnswer(
        (_) async => (candidates: [(localId: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1')], total: 1),
      );
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1')]);
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((_) async {});
      when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});

      await sut.fullSync();

      verifyInOrder([
        () => mockLocalDeletionRepository.snapshotBackedUpAssets(UserStub.admin.id),
        () => mockNativeSyncApi.getAlbums(),
        () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(),
        () => mockNativeSyncApi.getExistingAssetIds(['local-1']),
        () => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'}),
        () => mockLocalDeletionRepository.getPending(UserStub.admin.id),
        () => mockAssetApiRepository.delete(['remote-1'], false),
        () => mockNativeSyncApi.checkpointSync(),
      ]);
    });

    test('skips snapshot and detection when the feature is disabled', () async {
      stubFullSync();

      await sut.fullSync();

      verifyNever(() => mockLocalDeletionRepository.snapshotBackedUpAssets(any()));
      verifyNever(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates());
      verifyNever(() => mockLocalDeletionRepository.getPending(any()));
    });

    test('skips snapshot and detection when photo access is limited', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));
      when(() => mockPermissionRepository.hasFullMediaPermission()).thenAnswer((_) async => false);
      stubFullSync();

      await sut.fullSync();

      verifyNever(() => mockLocalDeletionRepository.snapshotBackedUpAssets(any()));
      verifyNever(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates());
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
    });

    test('still queues detected deletions when cancelled, but does not flush', () async {
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
        serverInfoService: mockServerInfoService,
        cancellation: cancellation,
      );

      stubFullSync();
      when(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates()).thenAnswer(
        (_) async => (candidates: [(localId: 'local-1', remoteId: 'remote-1', checksum: 'checksum-1')], total: 1),
      );

      await cancelledSut.fullSync();

      // The detected deletions are persisted for the next run. Only the server flush is skipped.
      verify(() => mockLocalDeletionRepository.snapshotBackedUpAssets(UserStub.admin.id)).called(1);
      verify(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates()).called(1);
      verify(() => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-1': 'checksum-1'})).called(1);
      verifyNever(() => mockLocalDeletionRepository.getPending(any()));
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
    });

    test('does not queue candidates the device still reports as present', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));

      stubFullSync();
      when(() => mockLocalDeletionRepository.getSnapshotDeletionCandidates()).thenAnswer(
        (_) async => (
          candidates: [
            (localId: 'hidden-1', remoteId: 'remote-1', checksum: 'checksum-1'),
            (localId: 'gone-2', remoteId: 'remote-2', checksum: 'checksum-2'),
          ],
          total: 2,
        ),
      );
      // hidden-1 is still on the device (e.g. hidden on iOS); only gone-2 is really deleted.
      when(() => mockNativeSyncApi.getExistingAssetIds(any())).thenAnswer((_) async => ['hidden-1']);

      await sut.fullSync();

      verify(() => mockLocalDeletionRepository.upsert(UserStub.admin.id, {'remote-2': 'checksum-2'})).called(1);
      verify(() => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions()).called(1);
    });

    test('skips the deletion sync when almost every backed-up asset vanished at once', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));

      stubFullSync();
      final candidates = [
        for (int i = 0; i < 100; i++) (localId: 'local-$i', remoteId: 'remote-$i', checksum: 'checksum-$i'),
      ];
      when(
        () => mockLocalDeletionRepository.getSnapshotDeletionCandidates(),
      ).thenAnswer((_) async => (candidates: candidates, total: 100));

      await sut.fullSync();

      // A near-total wipe is a device state change, not deletions. Nothing is
      // queued, but the snapshot is still cleared for the next run.
      verifyNever(() => mockLocalDeletionRepository.upsert(any(), any()));
      verify(() => mockLocalDeletionRepository.clearSnapshotAndConsumeExclusions()).called(1);
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
