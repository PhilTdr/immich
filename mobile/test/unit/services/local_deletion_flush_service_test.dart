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
  late Completer<void> cancellation;
  late Drift db;
  final ownerId = UserStub.admin.id;

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
    cancellation = Completer();
    sut = LocalDeletionFlushService(
      localDeletionRepository: mocks.localDeletion.repo,
      assetService: services.asset.service,
      devicePermissionService: devicePermissionService,
      serverInfoService: services.serverInfo,
      cancellation: cancellation,
    );

    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
    await Store.put(StoreKey.currentUser, UserStub.admin);
    when(() => devicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.granted);
    when(
      () => services.serverInfo.getServerFeatures(),
    ).thenAnswer((_) async => const ServerFeatures(trash: true, map: false, oauthEnabled: false, passwordLogin: true));
  });

  void stubServerRejects(Future<void> Function() send, String rejectedId) {
    when(send).thenAnswer((invocation) async {
      final ids = invocation.positionalArguments.first as List<String>;
      if (ids.contains(rejectedId)) {
        throw ApiException(400, 'Not found or no asset.delete access');
      }
    });
  }

  group('flush', () {
    test('does nothing when the feature is disabled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);

      await sut.flush();

      verifyNever(mocks.localDeletion.getToRestore);
      verifyNever(mocks.localDeletion.prune);
      verifyNever(mocks.localDeletion.getToTrash);
    });

    test('does nothing when there is no authenticated user', () async {
      await Store.delete(StoreKey.currentUser);

      await sut.flush();

      verifyNever(mocks.localDeletion.getToTrash);
    });

    test('does nothing when photo access is limited', () async {
      when(() => devicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.limited);

      await sut.flush();

      verifyNever(mocks.localDeletion.getToTrash);
    });

    test('trashes the settled deletions and marks them flushed', () async {
      when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1', 'remote-2']);
      final start = DateTime.now();

      await sut.flush();

      final settledBefore =
          verify(
                () => mocks.localDeletion.repo.getToTrash(ownerId, settledBefore: captureAny(named: 'settledBefore')),
              ).captured.single
              as DateTime;
      expect(settledBefore.isBefore(start.subtract(kLocalDeletionSettleDuration)), isFalse);
      expect(settledBefore.isAfter(DateTime.now().subtract(kLocalDeletionSettleDuration)), isFalse);
      verifyInOrder([
        () => mocks.localDeletion.repo.prune(ownerId),
        () => services.asset.service.trash(['remote-1', 'remote-2']),
        () => mocks.localDeletion.repo.markTrashed(['remote-1', 'remote-2']),
      ]);
      verifyNever(mocks.localDeletion.deleteByRemoteIds);
    });

    test('restores and prunes but trashes nothing while deletions await confirmation', () async {
      when(mocks.localDeletion.hasAwaitingConfirmation).thenAnswer((_) async => true);
      when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1']);
      when(mocks.localDeletion.getToRestore).thenAnswer((_) async => ['remote-restored']);

      await sut.flush();

      verifyInOrder([
        () => services.asset.service.restoreTrash(['remote-restored']),
        () => mocks.localDeletion.repo.prune(ownerId),
      ]);
      verifyNever(services.asset.trash);
    });

    for (final (name, features) in [
      (
        'the server has trash disabled',
        const ServerFeatures(trash: false, map: false, oauthEnabled: false, passwordLogin: true),
      ),
      ('the server features cannot be fetched', null),
    ]) {
      test('keeps the queue when $name', () async {
        when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1']);
        when(() => services.serverInfo.getServerFeatures()).thenAnswer((_) async => features);

        await sut.flush();

        verifyNever(services.asset.trash);
        verifyNever(mocks.localDeletion.deleteByRemoteIds);
      });
    }

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
        when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1']);
        when(services.asset.trash).thenThrow(error);

        await sut.flush();

        verifyNever(mocks.localDeletion.deleteByRemoteIds);
        verifyNever(mocks.localDeletion.markTrashed);
      });
    }

    test('drops the deletions that the server rejects and flushes the rest', () async {
      when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-dead', 'remote-2']);
      stubServerRejects(services.asset.trash, 'remote-dead');

      await sut.flush();

      verify(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-dead'])).called(1);
      verify(() => mocks.localDeletion.repo.markTrashed(['remote-2'])).called(1);
    });

    group('in chunks', () {
      setUp(() {
        when(mocks.localDeletion.getToTrash).thenAnswer((_) async => [for (int i = 0; i < 1001; i++) 'remote-$i']);
      });

      void afterFirstChunk(FutureOr<void> Function() action) {
        when(services.asset.trash).thenAnswer((_) async => action());
      }

      test('flushes a large queue', () async {
        await sut.flush();

        final chunks = verify(() => services.asset.service.trash(captureAny())).captured;
        expect(chunks.map((chunk) => (chunk as List<String>).length), [1000, 1]);
      });

      test('stops when the deletion sync is turned off', () async {
        afterFirstChunk(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false));

        await sut.flush();

        verify(services.asset.trash).called(1);
      });

      test('stops when the iOS shared albums option is turned off', () async {
        const key = SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums;
        await SettingsRepository.instance.write(key, true);
        // Changed in the database only, like from the settings page in another isolate
        afterFirstChunk(() => (db.delete(db.settingsEntity)..where((row) => row.key.equals(key.name))).go());

        await sut.flush();

        verify(services.asset.trash).called(1);
      });

      test('stops when a sync holds deletions for confirmation', () async {
        afterFirstChunk(() => when(mocks.localDeletion.hasAwaitingConfirmation).thenAnswer((_) async => true));

        await sut.flush();

        verify(services.asset.trash).called(1);
      });

      test('stops when cancelled', () async {
        afterFirstChunk(cancellation.complete);

        await sut.flush();

        verify(services.asset.trash).called(1);
      });
    });
  });

  group('restore', () {
    test('restores the server copy of flushed deletions whose file is back on the device', () async {
      when(mocks.localDeletion.getToRestore).thenAnswer((_) async => ['remote-1', 'remote-2']);

      await sut.flush();

      verifyInOrder([
        () => services.asset.service.restoreTrash(['remote-1', 'remote-2']),
        () => mocks.localDeletion.repo.deleteByRemoteIds(['remote-1', 'remote-2']),
        () => mocks.localDeletion.repo.prune(ownerId),
      ]);
    });

    test('keeps the rows that the server rejects and restores the rest', () async {
      when(mocks.localDeletion.getToRestore).thenAnswer((_) async => ['remote-dead', 'remote-2']);
      stubServerRejects(services.asset.restoreTrash, 'remote-dead');

      await sut.flush();

      // Kept until the sync drops the rejected remote asset
      verifyNever(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-dead']));
      verify(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-2'])).called(1);
    });

    test('keeps the rows and still flushes pending deletions when the restore fails', () async {
      when(mocks.localDeletion.getToRestore).thenAnswer((_) async => ['remote-1']);
      when(services.asset.restoreTrash).thenThrow(Exception('network'));
      when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-2']);

      await sut.flush();

      verifyNever(mocks.localDeletion.deleteByRemoteIds);
      verify(() => services.asset.service.trash(['remote-2'])).called(1);
    });
  });
}
