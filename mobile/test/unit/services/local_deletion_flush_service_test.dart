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
    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums, true);
    await Store.put(StoreKey.currentUser, UserStub.admin);
    when(() => devicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.granted);
    when(
      () => services.serverInfo.getServerFeatures(),
    ).thenAnswer((_) async => const ServerFeatures(trash: true, map: false, oauthEnabled: false, passwordLogin: true));
  });

  group('flush', () {
    for (final (name, arrange) in <(String, FutureOr<void> Function())>[
      ('the option is off', () => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false)),
      (
        'photo access is limited',
        () =>
            when(() => devicePermissionService.galleryStatus()).thenAnswer((_) async => DevicePermissionStatus.limited),
      ),
      ('the run is cancelled', () => cancellation.complete()),
    ]) {
      test('does nothing when $name', () async {
        when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1']);
        when(mocks.localDeletion.getToRestore).thenAnswer((_) async => ['remote-2']);
        await arrange();

        await sut.flush();

        verifyNever(services.asset.trash);
        verifyNever(services.asset.restoreTrash);
      });
    }

    for (final key in [SettingsKey.backupSyncLocalDeletions, SettingsKey.backupSyncLocalDeletionsInIosSharedAlbums]) {
      test('trashes nothing when ${key.name} was turned off in another isolate', () async {
        await (db.delete(db.settingsEntity)..where((row) => row.key.equals(key.name))).go();
        when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1']);

        await sut.flush();

        verifyNever(services.asset.trash);
      });
    }

    test('trashes the settled deletions and keeps them for a restore', () async {
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
    });

    test('trashes nothing while deletions await confirmation', () async {
      when(mocks.localDeletion.hasAwaitingConfirmation).thenAnswer((_) async => true);
      when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1']);

      await sut.flush();

      verifyNever(services.asset.trash);
    });

    for (final (name, features) in [
      (
        'the server has the trash disabled',
        const ServerFeatures(trash: false, map: false, oauthEnabled: false, passwordLogin: true),
      ),
      ('the server features cannot be fetched', null),
    ]) {
      test('trashes nothing when $name', () async {
        when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1']);
        when(() => services.serverInfo.getServerFeatures()).thenAnswer((_) async => features);

        await sut.flush();

        verifyNever(services.asset.trash);
        verifyNever(mocks.localDeletion.deleteByRemoteIds);
      });
    }

    for (final (name, error) in [
      (
        'the server cannot be reached',
        ApiException.withInner(400, 'offline', const SocketException('offline'), StackTrace.empty),
      ),
      ('the server answers with an error', ApiException(500, 'Internal Server Error')),
    ]) {
      test('keeps the deletions queued when $name', () async {
        when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1']);
        when(services.asset.trash).thenThrow(error);

        await sut.flush();

        verifyNever(mocks.localDeletion.deleteByRemoteIds);
        verifyNever(mocks.localDeletion.markTrashed);
      });
    }

    test('drops the deletions that the server rejects and trashes the rest', () async {
      when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-1', 'remote-2', 'remote-gone']);
      when(services.asset.trash).thenAnswer((invocation) async {
        if ((invocation.positionalArguments.first as List<String>).contains('remote-gone')) {
          throw ApiException(400, 'Not found or no asset.delete access');
        }
      });

      await sut.flush();

      verify(() => mocks.localDeletion.repo.markTrashed(['remote-1', 'remote-2'])).called(1);
      verify(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-gone'])).called(1);
    });

    test('restores the server copy of sent deletions whose file is back on the device', () async {
      when(mocks.localDeletion.getToRestore).thenAnswer((_) async => ['remote-1', 'remote-2']);

      await sut.flush();

      verify(() => services.asset.service.restoreTrash(['remote-1', 'remote-2'])).called(1);
      verify(() => mocks.localDeletion.repo.deleteByRemoteIds(['remote-1', 'remote-2'])).called(1);
    });

    test('still trashes the pending deletions when the restore fails', () async {
      when(mocks.localDeletion.getToRestore).thenAnswer((_) async => ['remote-1']);
      when(services.asset.restoreTrash).thenThrow(Exception('network'));
      when(mocks.localDeletion.getToTrash).thenAnswer((_) async => ['remote-2']);

      await sut.flush();

      verifyNever(mocks.localDeletion.deleteByRemoteIds);
      verify(() => services.asset.service.trash(['remote-2'])).called(1);
    });
  });
}
