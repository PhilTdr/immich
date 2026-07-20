import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_deletion_flush.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' show ApiException;

import '../../domain/service.mock.dart';
import '../../fixtures/user.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../repository.mocks.dart';

void main() {
  final settled = DateTime.now().subtract(const Duration(minutes: 16));
  late LocalDeletionFlushService sut;
  late MockLocalDeletionRepository mockLocalDeletionRepository;
  late MockLocalAssetRepository mockLocalAssetRepository;
  late MockAssetApiRepository mockAssetApiRepository;
  late MockRemoteAssetRepository mockRemoteAssetRepository;
  late MockPermissionRepository mockPermissionRepository;
  late MockServerInfoService mockServerInfoService;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    registerFallbackValue(<String>[]);
    registerFallbackValue(const Iterable<String>.empty());

    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
    await SettingsRepository.ensureInitialized(db);
  });

  tearDownAll(() async {
    await Store.clear();
    await db.close();
  });

  setUp(() async {
    mockLocalDeletionRepository = MockLocalDeletionRepository();
    mockLocalAssetRepository = MockLocalAssetRepository();
    mockAssetApiRepository = MockAssetApiRepository();
    mockRemoteAssetRepository = MockRemoteAssetRepository();
    mockPermissionRepository = MockPermissionRepository();
    mockServerInfoService = MockServerInfoService();

    sut = LocalDeletionFlushService(
      localDeletionRepository: mockLocalDeletionRepository,
      localAssetRepository: mockLocalAssetRepository,
      assetApiRepository: mockAssetApiRepository,
      remoteAssetRepository: mockRemoteAssetRepository,
      permissionRepository: mockPermissionRepository,
      serverInfoService: mockServerInfoService,
    );

    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);
    await Store.put(StoreKey.currentUser, UserStub.admin);
    when(() => mockPermissionRepository.hasFullMediaPermission()).thenAnswer((_) async => true);
    when(() => mockLocalDeletionRepository.pruneAlreadyTrashed()).thenAnswer((_) async {});
    when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer((_) async => []);
    when(() => mockLocalDeletionRepository.deleteByRemoteIds(any())).thenAnswer((_) async {});
    when(() => mockLocalAssetRepository.getExistingChecksums(any())).thenAnswer((_) async => <String>{});
    when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((_) async {});
    when(() => mockRemoteAssetRepository.trash(any())).thenAnswer((_) async {});
    when(() => mockServerInfoService.getServerFeatures()).thenAnswer(
      (_) async => const ServerFeatures(trash: true, map: false, oauthEnabled: false, passwordLogin: true),
    );
  });

  group('LocalDeletionFlushService - flushPendingDeletions', () {
    test('moves pending deletions to the server trash and clears their queue rows', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [
          (remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled),
          (remoteId: 'remote-2', checksum: 'checksum-2', createdAt: settled),
        ],
      );

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
        (_) async => [
          (remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled),
          (remoteId: 'remote-2', checksum: 'checksum-2', createdAt: settled),
        ],
      );
      // checksum-1 still exists locally -> cancel remote-1.
      when(() => mockLocalAssetRepository.getExistingChecksums(any())).thenAnswer((_) async => {'checksum-1'});

      await sut.flushPendingDeletions('owner-1');

      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-1'])).called(1);
      verify(() => mockAssetApiRepository.delete(['remote-2'], false)).called(1);
      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-2'])).called(1);
    });

    test('leaves deletions queued when the server call fails', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled)]);
      when(() => mockAssetApiRepository.delete(any(), any())).thenThrow(Exception('network'));

      await sut.flushPendingDeletions('owner-1');

      // The queue row must survive a failed flush so it is retried on the next sync.
      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
    });

    test('keeps the queue when the client reports a transport failure as code 400', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled)]);
      when(
        () => mockAssetApiRepository.delete(any(), any()),
      ).thenThrow(ApiException.withInner(400, 'offline', const SocketException('offline'), StackTrace.empty));

      await sut.flushPendingDeletions('owner-1');

      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
    });

    test('keeps the queue when a 400 does not carry the server rejection body', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled)]);
      // e.g. a reverse proxy or WAF answering with its own 400 page.
      when(
        () => mockAssetApiRepository.delete(any(), any()),
      ).thenThrow(ApiException(400, '<html>Bad Request</html>'));

      await sut.flushPendingDeletions('owner-1');

      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
    });

    test('keeps the queue on server errors', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled)]);
      when(() => mockAssetApiRepository.delete(any(), any())).thenThrow(ApiException(500, 'Internal Server Error'));

      await sut.flushPendingDeletions('owner-1');

      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
    });

    test('stops the individual flush when cancelled', () async {
      final cancellation = Completer<void>();
      final cancellableSut = LocalDeletionFlushService(
        localDeletionRepository: mockLocalDeletionRepository,
        localAssetRepository: mockLocalAssetRepository,
        assetApiRepository: mockAssetApiRepository,
        remoteAssetRepository: mockRemoteAssetRepository,
        permissionRepository: mockPermissionRepository,
        serverInfoService: mockServerInfoService,
        cancellation: cancellation,
      );
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [
          (remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled),
          (remoteId: 'remote-2', checksum: 'checksum-2', createdAt: settled),
        ],
      );
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((invocation) async {
        final ids = invocation.positionalArguments.first as List<String>;
        if (ids.length > 1) {
          // The rejected batch falls back to the per-id flush.
          throw ApiException(400, 'Not found or no asset.delete access');
        }
        cancellation.complete();
      });

      await cancellableSut.flushPendingDeletions('owner-1');

      verify(() => mockAssetApiRepository.delete(['remote-1'], false)).called(1);
      verifyNever(() => mockAssetApiRepository.delete(['remote-2'], false));
    });

    test('drops intents the server rejects permanently and keeps flushing the rest', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [
          (remoteId: 'remote-dead', checksum: 'checksum-1', createdAt: settled),
          (remoteId: 'remote-2', checksum: 'checksum-2', createdAt: settled),
        ],
      );
      when(() => mockAssetApiRepository.delete(any(), any())).thenAnswer((invocation) async {
        final ids = invocation.positionalArguments.first as List<String>;
        if (ids.length > 1 || ids.single == 'remote-dead') {
          throw ApiException(400, 'Not found or no asset.delete access');
        }
      });

      await sut.flushPendingDeletions('owner-1');

      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-dead'])).called(1);
      verify(() => mockRemoteAssetRepository.trash(['remote-2'])).called(1);
      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-2'])).called(1);
      verifyNever(() => mockRemoteAssetRepository.trash(['remote-dead']));
    });

    test('skips the flush and keeps the queue when the server has trash disabled', () async {
      when(
        () => mockLocalDeletionRepository.getPending(any()),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled)]);
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
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled)]);
      when(() => mockServerInfoService.getServerFeatures()).thenAnswer((_) async => null);

      await sut.flushPendingDeletions('owner-1');

      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
    });

    test('keeps intents queued until they settle', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [(remoteId: 'remote-fresh', checksum: 'checksum-1', createdAt: DateTime.now())],
      );

      await sut.flushPendingDeletions('owner-1');

      // A fresh intent may still be in a move/rename settle window. nothing is
      // sent and the row survives for a later flush.
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
      verifyNever(() => mockRemoteAssetRepository.trash(any()));
      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(any()));
    });

    test('flushes only the settled intents and keeps the fresh ones queued', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [
          (remoteId: 'remote-settled', checksum: 'checksum-1', createdAt: settled),
          (remoteId: 'remote-fresh', checksum: 'checksum-2', createdAt: DateTime.now()),
        ],
      );

      await sut.flushPendingDeletions('owner-1');

      verify(() => mockAssetApiRepository.delete(['remote-settled'], false)).called(1);
      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-settled'])).called(1);
      verifyNever(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-fresh']));
    });

    test('cancels a fresh intent whose content is still present locally', () async {
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer(
        (_) async => [(remoteId: 'remote-fresh', checksum: 'checksum-1', createdAt: DateTime.now())],
      );
      when(() => mockLocalAssetRepository.getExistingChecksums(any())).thenAnswer((_) async => {'checksum-1'});

      await sut.flushPendingDeletions('owner-1');

      // Moot intents leave the queue without waiting for the settle valve.
      verify(() => mockLocalDeletionRepository.deleteByRemoteIds(['remote-fresh'])).called(1);
      verifyNever(() => mockAssetApiRepository.delete(any(), any()));
    });

    test('flushes large queues in chunks', () async {
      final pending = [
        for (int i = 0; i < 1001; i++) (remoteId: 'remote-$i', checksum: 'checksum-$i', createdAt: settled),
      ];
      when(() => mockLocalDeletionRepository.getPending(any())).thenAnswer((_) async => pending);

      await sut.flushPendingDeletions('owner-1');

      final calls = verify(() => mockAssetApiRepository.delete(captureAny(), false)).captured;
      expect(calls.length, 2);
      expect((calls[0] as List<String>).length, 1000);
      expect((calls[1] as List<String>).length, 1);
    });
  });

  group('LocalDeletionFlushService - flush gating', () {
    test('does nothing when the feature is disabled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);
      addTearDown(() => SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true));

      await sut.flush();

      verifyNever(() => mockLocalDeletionRepository.pruneAlreadyTrashed());
      verifyNever(() => mockLocalDeletionRepository.getPending(any()));
    });

    test('does nothing when there is no authenticated user', () async {
      await Store.delete(StoreKey.currentUser);
      addTearDown(() => Store.put(StoreKey.currentUser, UserStub.admin));

      await sut.flush();

      verifyNever(() => mockLocalDeletionRepository.getPending(any()));
    });

    test('does nothing when photo access is limited', () async {
      when(() => mockPermissionRepository.hasFullMediaPermission()).thenAnswer((_) async => false);

      await sut.flush();

      verifyNever(() => mockLocalDeletionRepository.getPending(any()));
    });

    test('flushes the current user pending deletions when enabled and full access', () async {
      when(
        () => mockLocalDeletionRepository.getPending(UserStub.admin.id),
      ).thenAnswer((_) async => [(remoteId: 'remote-1', checksum: 'checksum-1', createdAt: settled)]);

      await sut.flush();

      verify(() => mockLocalDeletionRepository.getPending(UserStub.admin.id)).called(1);
      verify(() => mockAssetApiRepository.delete(['remote-1'], false)).called(1);
    });
  });
}
