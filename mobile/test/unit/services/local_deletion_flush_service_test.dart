import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_deletion_flush.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' show ApiException;

import '../../fixtures/user.stub.dart';
import '../../service.mocks.dart';
import '../mocks.dart';

void main() {
  late LocalDeletionFlushService sut;
  late RepositoryMocks mocks;
  late ServiceMocks services;
  late MockDevicePermissionService devicePermissionService;
  late Drift db;

  setUpAll(() async {
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await SettingsRepository.ensureInitialized(db);
  });

  tearDownAll(() async {
    await Store.clear();
    await db.close();
  });

  setUp(() async {
    mocks = .new();
    services = .new();
    devicePermissionService = MockDevicePermissionService();
    sut = LocalDeletionFlushService(
      localDeletionRepository: mocks.localDeletion.repo,
      assetService: services.asset.service,
      devicePermissionService: devicePermissionService,
      serverInfoService: services.serverInfo,
      nativeSyncApi: mocks.nativeApi.api,
    );

    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalMovesOutOfBackupAsDeletion, false);
    await Store.put(StoreKey.currentUser, UserStub.admin);
    when(() => mocks.nativeApi.api.cancelHashing()).thenAnswer((_) async {});
    when(() => mocks.localDeletion.repo.getMoveCandidates(any())).thenAnswer((_) async => {});
    when(() => devicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.granted);
    when(() => mocks.localDeletion.repo.pruneAlreadyTrashed()).thenAnswer((_) async {});
    when(() => mocks.localDeletion.repo.pruneRestored(any())).thenAnswer((_) async {});
    when(() => mocks.localDeletion.repo.pruneFlushed()).thenAnswer((_) async {});
    when(() => mocks.localDeletion.repo.getRestored(any())).thenAnswer((_) async => []);
    when(() => mocks.localDeletion.repo.markTrashed(any())).thenAnswer((_) async {});
    when(
      () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
    ).thenAnswer((_) async => []);
    when(() => mocks.localDeletion.repo.deleteByRemoteIds(any())).thenAnswer((_) async {});
    when(() => mocks.localDeletion.repo.hasAwaitingConfirmation(any())).thenAnswer((_) async => false);
    when(
      () => services.serverInfo.getServerFeatures(),
    ).thenAnswer((_) async => const ServerFeatures(trash: true, map: false, oauthEnabled: false, passwordLogin: true));
  });

  group('LocalDeletionFlushService', () {
    group('flushPendingDeletions', () {
      group('while deletions await confirmation', () {
        setUp(() {
          when(() => mocks.localDeletion.repo.hasAwaitingConfirmation(any())).thenAnswer((_) async => true);
          when(
            () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
          ).thenAnswer((_) async => ['remote-1']);
        });

        test('moves nothing to the server trash', () async {
          await sut.flushPendingDeletions('owner-1');

          verify(() => mocks.localDeletion.repo.hasAwaitingConfirmation('owner-1')).called(1);
          verifyNever(() => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')));
          verifyNever(() => services.asset.service.trash(any()));
        });

        test('still prunes the queue and restores returned assets, so they leave the confirmation', () async {
          when(() => mocks.localDeletion.repo.getRestored(any())).thenAnswer((_) async => ['remote-restored']);
          when(() => services.asset.service.restoreTrash(any())).thenAnswer((_) async {});

          await sut.flushPendingDeletions('owner-1');

          verifyInOrder([
            () => mocks.localDeletion.repo.pruneFlushed(),
            () => services.asset.service.restoreTrash(['remote-restored']),
            () => mocks.localDeletion.repo.pruneAlreadyTrashed(),
            () => mocks.localDeletion.repo.pruneRestored('owner-1'),
            () => mocks.localDeletion.repo.hasAwaitingConfirmation('owner-1'),
          ]);
        });
      });

      test('stops before the next chunk when a sync holds deletions for confirmation meanwhile', () async {
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => [for (int i = 0; i < 1500; i++) 'remote-$i']);
        var held = false;
        when(() => mocks.localDeletion.repo.hasAwaitingConfirmation(any())).thenAnswer((_) async => held);
        when(() => services.asset.service.trash(any())).thenAnswer((_) async {
          held = true;
        });

        await sut.flushPendingDeletions('owner-1');

        verify(() => services.asset.service.trash(any())).called(1);
        verify(() => mocks.localDeletion.repo.markTrashed(any(that: hasLength(1000)))).called(1);
      });

      test('stops sending one at a time when a sync holds deletions for confirmation meanwhile', () async {
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => ['remote-dead', 'remote-2', 'remote-3']);
        var held = false;
        when(() => mocks.localDeletion.repo.hasAwaitingConfirmation(any())).thenAnswer((_) async => held);
        when(() => services.asset.service.trash(any())).thenAnswer((invocation) async {
          final ids = invocation.positionalArguments.first as List<String>;
          if (ids.length > 1 || ids.single == 'remote-dead') {
            throw ApiException(400, 'Not found or no asset.delete access');
          }
          held = true;
        });

        await sut.flushPendingDeletions('owner-1');

        verify(() => services.asset.service.trash(['remote-2'])).called(1);
        verifyNever(() => services.asset.service.trash(['remote-3']));
      });

      test('moves pending deletions to the server trash and keeps their queue rows as flushed', () async {
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => ['remote-1', 'remote-2']);

        await sut.flushPendingDeletions('owner-1');

        verifyInOrder([
          () => mocks.localDeletion.repo.pruneFlushed(),
          () => mocks.localDeletion.repo.getRestored('owner-1'),
          () => mocks.localDeletion.repo.pruneAlreadyTrashed(),
          () => mocks.localDeletion.repo.pruneRestored('owner-1'),
          () => mocks.localDeletion.repo.getPending('owner-1', settledBefore: any(named: 'settledBefore')),
          () => services.asset.service.trash(['remote-1', 'remote-2']),
          () => mocks.localDeletion.repo.markTrashed(['remote-1', 'remote-2']),
        ]);
        verifyNever(() => mocks.localDeletion.repo.deleteByRemoteIds(any()));
      });

      for (final (name, error) in [
        ('the server call fails', Exception('network')),
        (
          'the client reports a transport failure as code 400',
          ApiException.withInner(400, 'offline', const SocketException('offline'), StackTrace.empty),
        ),
        ('a 400 does not carry the server rejection body', ApiException(400, '<html>Bad Request</html>')),
        ('the server answers with an error', ApiException(500, 'Internal Server Error')),
      ]) {
        test('keeps the queue when $name', () async {
          when(
            () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
          ).thenAnswer((_) async => ['remote-1']);
          when(() => services.asset.service.trash(any())).thenThrow(error);

          await sut.flushPendingDeletions('owner-1');

          verifyNever(() => mocks.localDeletion.repo.deleteByRemoteIds(any()));

          verifyNever(() => mocks.localDeletion.repo.markTrashed(any()));
        });
      }

      test('drops intents the server rejects permanently and keeps flushing the rest', () async {
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => ['remote-dead', 'remote-2']);
        when(() => services.asset.service.trash(any())).thenAnswer((invocation) async {
          final ids = invocation.positionalArguments.first as List<String>;
          if (ids.length > 1 || ids.single == 'remote-dead') {
            throw ApiException(400, 'Not found or no asset.delete access');
          }
        });

        await sut.flushPendingDeletions('owner-1');

        verify(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-dead'])).called(1);
        verify(() => services.asset.service.trash(['remote-2'])).called(1);
        verify(() => mocks.localDeletion.repo.markTrashed(['remote-2'])).called(1);
      });

      test('stops the individual flush when cancelled', () async {
        final cancellation = Completer<void>();
        sut = LocalDeletionFlushService(
          localDeletionRepository: mocks.localDeletion.repo,
          assetService: services.asset.service,
          devicePermissionService: devicePermissionService,
          serverInfoService: services.serverInfo,
          nativeSyncApi: mocks.nativeApi.api,
          cancellation: cancellation,
        );
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => ['remote-1', 'remote-2']);
        when(() => services.asset.service.trash(any())).thenAnswer((invocation) async {
          final ids = invocation.positionalArguments.first as List<String>;
          if (ids.length > 1) {
            // The rejected batch falls back to the per-id flush.
            throw ApiException(400, 'Not found or no asset.delete access');
          }
          cancellation.complete();
        });

        await sut.flushPendingDeletions('owner-1');

        verify(() => services.asset.service.trash(['remote-1'])).called(1);
        verifyNever(() => services.asset.service.trash(['remote-2']));
        await pumpEventQueue();
        verify(() => mocks.nativeApi.api.cancelHashing()).called(1);
      });

      for (final (name, features) in [
        (
          'the server has trash disabled',
          const ServerFeatures(trash: false, map: false, oauthEnabled: false, passwordLogin: true),
        ),
        ('the server features cannot be fetched', null),
      ]) {
        test('skips the flush and keeps the queue when $name', () async {
          when(
            () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
          ).thenAnswer((_) async => ['remote-1']);
          when(() => services.serverInfo.getServerFeatures()).thenAnswer((_) async => features);

          await sut.flushPendingDeletions('owner-1');

          verifyNever(services.asset.trash);
          verifyNever(() => mocks.localDeletion.repo.deleteByRemoteIds(any()));
          verifyNever(() => mocks.localDeletion.repo.markTrashed(any()));
        });
      }

      test('only flushes intents older than the settle duration', () async {
        final before = DateTime.now().subtract(kLocalDeletionSettleDuration);

        await sut.flushPendingDeletions('owner-1');

        final settledBefore =
            verify(
                  () =>
                      mocks.localDeletion.repo.getPending('owner-1', settledBefore: captureAny(named: 'settledBefore')),
                ).captured.single
                as DateTime;
        expect(settledBefore.isBefore(before), isFalse);
        expect(settledBefore.isAfter(DateTime.now().subtract(kLocalDeletionSettleDuration)), isFalse);
      });

      test('flushes large queues in chunks', () async {
        final pending = [for (int i = 0; i < 1001; i++) 'remote-$i'];
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => pending);

        await sut.flushPendingDeletions('owner-1');

        final calls = verify(() => services.asset.service.trash(captureAny())).captured;
        expect(calls.length, 2);
        expect((calls[0] as List<String>).length, 1000);
        expect((calls[1] as List<String>).length, 1);
      });

      test('stops between chunks when the deletion sync is turned off', () async {
        final pending = [for (int i = 0; i < 1001; i++) 'remote-$i'];
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => pending);
        when(() => services.asset.service.trash(any())).thenAnswer((_) async {
          await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);
        });

        await sut.flushPendingDeletions('owner-1');

        verify(() => services.asset.service.trash(any())).called(1);
      });

      test('stops between chunks when the iOS shared album option is turned off', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
        final pending = [for (int i = 0; i < 1001; i++) 'remote-$i'];
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => pending);
        when(() => services.asset.service.trash(any())).thenAnswer((_) async {
          // On the settings page in the main isolate, which the cached settings of the flush do not see
          await (db.delete(
            db.settingsEntity,
          )..where((row) => row.key.equals(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums.name))).go();
        });

        await sut.flushPendingDeletions('owner-1');

        verify(() => services.asset.service.trash(any())).called(1);
      });
    });

    group('moves out of backup', () {
      setUp(() {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => ['remote-1', 'remote-2']);
        when(() => mocks.localDeletion.repo.getMoveCandidates(any())).thenAnswer(
          (_) async => {
            'remote-1': (checksum: 'checksum-1', localIds: ['copy-1']),
          },
        );
      });

      void stubHash(HashResult result) {
        when(mocks.nativeApi.hashAssets).thenAnswer((_) async => [result]);
      }

      test('drops a deletion whose same-named file has the same content', () async {
        stubHash(HashResult(assetId: 'copy-1', hash: 'checksum-1'));

        await sut.flushPendingDeletions('owner-1');

        verify(() => mocks.localDeletion.repo.deleteByRemoteIds({'remote-1'})).called(1);
        verify(() => services.asset.service.trash(['remote-2'])).called(1);
        verifyNever(() => services.asset.service.trash(['remote-1', 'remote-2']));
      });

      test('flushes a deletion whose same-named file has other content', () async {
        stubHash(HashResult(assetId: 'copy-1', hash: 'other'));

        await sut.flushPendingDeletions('owner-1');

        verify(() => services.asset.service.trash(['remote-1', 'remote-2'])).called(1);
      });

      test('keeps a deletion queued while its same-named file cannot be hashed', () async {
        stubHash(HashResult(assetId: 'copy-1', error: 'unreadable'));

        await sut.flushPendingDeletions('owner-1');

        verify(() => services.asset.service.trash(['remote-2'])).called(1);
        verify(() => mocks.localDeletion.repo.markTrashed(['remote-2'])).called(1);
        verifyNever(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-1']));
      });

      test('keeps a deletion queued when hashing fails', () async {
        when(mocks.nativeApi.hashAssets).thenThrow(PlatformException(code: 'HASH_CANCELLED'));

        await sut.flushPendingDeletions('owner-1');

        verify(() => services.asset.service.trash(['remote-2'])).called(1);
        verifyNever(() => services.asset.service.trash(['remote-1', 'remote-2']));
        verifyNever(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-1']));
      });

      test('does not look for moves when they count as deletions', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalMovesOutOfBackupAsDeletion, true);

        await sut.flushPendingDeletions('owner-1');

        verifyNever(() => mocks.localDeletion.repo.getMoveCandidates(any()));
        verify(() => services.asset.service.trash(['remote-1', 'remote-2'])).called(1);
      });

      test('does not look for moves on iOS', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

        await sut.flushPendingDeletions('owner-1');

        verifyNever(() => mocks.localDeletion.repo.getMoveCandidates(any()));
        verifyNever(mocks.nativeApi.hashAssets);
      });

      group('by file size', () {
        setUp(() {
          when(() => mocks.localDeletion.repo.getMoveCandidates(any())).thenAnswer((_) async => {});
          when(
            () => mocks.localDeletion.repo.getPendingFileSizes(any()),
          ).thenAnswer((_) async => {'remote-1': (checksum: 'checksum-1', type: 1, fileSize: 1234)});
          when(
            () => mocks.nativeApi.api.getAssetIdsBySize(any()),
          ).thenAnswer((_) async => {'renamed-1': 1234, 'hashed-1': 1234, 'video-1': 1234});
          when(
            () => mocks.localDeletion.repo.getUnhashedByIds(any()),
          ).thenAnswer((_) async => {'renamed-1': 1, 'video-1': 2});
        });

        test('hashes only the unhashed files with the size and type of the deleted file', () async {
          stubHash(HashResult(assetId: 'renamed-1', hash: 'other'));

          await sut.flushPendingDeletions('owner-1');

          verify(() => mocks.nativeApi.api.getAssetIdsBySize([1234])).called(1);
          verify(
            () => mocks.nativeApi.api.hashAssets(['renamed-1'], allowNetworkAccess: any(named: 'allowNetworkAccess')),
          ).called(1);
          verify(() => services.asset.service.trash(['remote-1', 'remote-2'])).called(1);
        });

        test('drops a deletion whose same-sized file has the same content', () async {
          stubHash(HashResult(assetId: 'renamed-1', hash: 'checksum-1'));

          await sut.flushPendingDeletions('owner-1');

          verify(() => mocks.localDeletion.repo.deleteByRemoteIds({'remote-1'})).called(1);
          verify(() => services.asset.service.trash(['remote-2'])).called(1);
          verifyNever(() => services.asset.service.trash(['remote-1', 'remote-2']));
        });

        test('hashes a file that matches by name and by size only once', () async {
          when(() => mocks.localDeletion.repo.getMoveCandidates(any())).thenAnswer(
            (_) async => {
              'remote-1': (checksum: 'checksum-1', localIds: ['renamed-1']),
            },
          );
          stubHash(HashResult(assetId: 'renamed-1', hash: 'checksum-1'));

          await sut.flushPendingDeletions('owner-1');

          verify(
            () => mocks.nativeApi.api.hashAssets(['renamed-1'], allowNetworkAccess: any(named: 'allowNetworkAccess')),
          ).called(1);
          verify(() => mocks.localDeletion.repo.deleteByRemoteIds({'remote-1'})).called(1);
        });

        test('does not look up sizes when no pending deletion has a file size', () async {
          when(() => mocks.localDeletion.repo.getPendingFileSizes(any())).thenAnswer((_) async => {});

          await sut.flushPendingDeletions('owner-1');

          verifyNever(() => mocks.nativeApi.api.getAssetIdsBySize(any()));
          verify(() => services.asset.service.trash(['remote-1', 'remote-2'])).called(1);
        });

        test('keeps the sized deletions queued when the size lookup fails', () async {
          when(() => mocks.nativeApi.api.getAssetIdsBySize(any())).thenThrow(PlatformException(code: 'error'));

          await sut.flushPendingDeletions('owner-1');

          verify(() => services.asset.service.trash(['remote-2'])).called(1);
          verifyNever(() => services.asset.service.trash(['remote-1', 'remote-2']));
          verifyNever(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-1']));
          verifyNever(mocks.nativeApi.hashAssets);
        });
      });
    });

    group('restoring returned files', () {
      test('restores the server copy of flushed deletions whose file is back on the device', () async {
        when(() => mocks.localDeletion.repo.getRestored(any())).thenAnswer((_) async => ['remote-1', 'remote-2']);

        await sut.flushPendingDeletions('owner-1');

        verifyInOrder([
          () => mocks.localDeletion.repo.pruneFlushed(),
          () => mocks.localDeletion.repo.getRestored('owner-1'),
          () => services.asset.service.restoreTrash(['remote-1', 'remote-2']),
          () => mocks.localDeletion.repo.deleteByRemoteIds(['remote-1', 'remote-2']),
        ]);
      });

      test('keeps the rows the server rejects and restores the rest', () async {
        when(() => mocks.localDeletion.repo.getRestored(any())).thenAnswer((_) async => ['remote-dead', 'remote-2']);
        when(() => services.asset.service.restoreTrash(any())).thenAnswer((invocation) async {
          final ids = invocation.positionalArguments.first as List<String>;
          if (ids.length > 1 || ids.single == 'remote-dead') {
            throw ApiException(400, 'Not found or no asset.delete access');
          }
        });

        await sut.flushPendingDeletions('owner-1');

        // The sync drops the remote asset of a rejected id, until then its row keeps the file out of the device trash
        verifyNever(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-dead']));
        verify(() => services.asset.service.restoreTrash(['remote-2'])).called(1);
        verify(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-2'])).called(1);
      });

      test('keeps the rows and still flushes pending deletions when the restore fails', () async {
        when(() => mocks.localDeletion.repo.getRestored(any())).thenAnswer((_) async => ['remote-1']);
        when(() => services.asset.service.restoreTrash(any())).thenThrow(Exception('network'));
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => ['remote-2']);

        await sut.flushPendingDeletions('owner-1');

        verifyNever(() => mocks.localDeletion.repo.deleteByRemoteIds(any()));
        verify(() => services.asset.service.trash(['remote-2'])).called(1);
      });

      test('does not call the server when no file came back', () async {
        await sut.flushPendingDeletions('owner-1');

        verifyNever(services.asset.restoreTrash);
      });
    });

    group('flush', () {
      test('does nothing when the feature is disabled', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);

        await sut.flush();

        verifyNever(() => mocks.localDeletion.repo.getRestored(any()));
        verifyNever(() => mocks.localDeletion.repo.pruneAlreadyTrashed());
        verifyNever(() => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')));
      });

      test('does nothing when there is no authenticated user', () async {
        await Store.delete(StoreKey.currentUser);

        await sut.flush();

        verifyNever(() => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')));
      });

      test('does nothing when photo access is limited', () async {
        when(() => devicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.limited);

        await sut.flush();

        verifyNever(() => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')));
      });

      test('flushes the pending deletions of the current user', () async {
        when(
          () => mocks.localDeletion.repo.getPending(UserStub.admin.id, settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => ['remote-1']);

        await sut.flush();

        verify(() => services.asset.service.trash(['remote-1'])).called(1);
      });
    });
  });
}
