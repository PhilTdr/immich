import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
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
    );

    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
    await Store.put(StoreKey.currentUser, UserStub.admin);
    when(() => devicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.granted);
    when(() => mocks.localDeletion.repo.pruneAlreadyTrashed()).thenAnswer((_) async {});
    when(() => mocks.localDeletion.repo.pruneRestored(any())).thenAnswer((_) async {});
    when(
      () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
    ).thenAnswer((_) async => []);
    when(() => mocks.localDeletion.repo.deleteByRemoteIds(any())).thenAnswer((_) async {});
    when(
      () => services.serverInfo.getServerFeatures(),
    ).thenAnswer((_) async => const ServerFeatures(trash: true, map: false, oauthEnabled: false, passwordLogin: true));
  });

  group('LocalDeletionFlushService', () {
    group('flushPendingDeletions', () {
      test('moves pending deletions to the server trash and clears their queue rows', () async {
        when(
          () => mocks.localDeletion.repo.getPending(any(), settledBefore: any(named: 'settledBefore')),
        ).thenAnswer((_) async => ['remote-1', 'remote-2']);

        await sut.flushPendingDeletions('owner-1');

        verifyInOrder([
          () => mocks.localDeletion.repo.pruneAlreadyTrashed(),
          () => mocks.localDeletion.repo.pruneRestored('owner-1'),
          () => mocks.localDeletion.repo.getPending('owner-1', settledBefore: any(named: 'settledBefore')),
          () => services.asset.service.trash(['remote-1', 'remote-2']),
          () => mocks.localDeletion.repo.deleteByRemoteIds(['remote-1', 'remote-2']),
        ]);
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
        verify(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-2'])).called(1);
      });

      test('stops the individual flush when cancelled', () async {
        final cancellation = Completer<void>();
        sut = LocalDeletionFlushService(
          localDeletionRepository: mocks.localDeletion.repo,
          assetService: services.asset.service,
          devicePermissionService: devicePermissionService,
          serverInfoService: services.serverInfo,
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
    });

    group('flush', () {
      test('does nothing when the feature is disabled', () async {
        await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);

        await sut.flush();

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
