import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:mocktail/mocktail.dart';

import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';

void main() {
  late CleanupService sut;

  late MockDriftLocalAssetRepository localAssetRepository;
  late MockAssetMediaRepository assetMediaRepository;
  late MockLocalDeletionRepository localDeletionRepository;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(<String>[]);
    registerFallbackValue(const Iterable<String>.empty());

    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await SettingsRepository.ensureInitialized(db);
  });

  tearDownAll(() async {
    await db.close();
  });

  setUp(() async {
    localAssetRepository = MockDriftLocalAssetRepository();
    assetMediaRepository = MockAssetMediaRepository();
    localDeletionRepository = MockLocalDeletionRepository();
    sut = CleanupService(localAssetRepository, assetMediaRepository, localDeletionRepository);

    await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, false);
    when(() => localDeletionRepository.markExcluded(any())).thenAnswer((_) async {});
    when(() => localDeletionRepository.unmarkExcluded(any())).thenAnswer((_) async {});
  });

  group('CleanupService.deleteLocalAssets', () {
    test('returns 0 and does nothing for empty input', () async {
      final result = await sut.deleteLocalAssets([]);

      expect(result, 0);
      verifyNever(() => assetMediaRepository.deleteAll(any()));
      verifyNever(() => localAssetRepository.delete(any()));
    });

    test('deletes in a single batch when under limit', () async {
      final ids = List.generate(999, (i) => 'asset-$i');

      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((invocation) async {
        return (invocation.positionalArguments.first as List<String>).toList();
      });
      when(() => localAssetRepository.delete(any())).thenAnswer((_) async {});

      final result = await sut.deleteLocalAssets(ids);

      expect(result, ids.length);
      verify(() => assetMediaRepository.deleteAll(ids)).called(1);
      verify(() => localAssetRepository.delete(ids)).called(1);
    });

    test('deletes in platform-specific batches when over limit', () async {
      final batchSize = CurrentPlatform.isAndroid ? 2000 : 10000;
      final ids = List.generate(batchSize * 2 + 501, (i) => 'asset-$i');
      final capturedBatches = <List<String>>[];

      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((invocation) async {
        final batch = (invocation.positionalArguments.first as List<String>).toList();
        capturedBatches.add(batch);
        return batch;
      });
      when(() => localAssetRepository.delete(any())).thenAnswer((_) async {});

      final result = await sut.deleteLocalAssets(ids);

      expect(result, ids.length);
      expect(capturedBatches.length, 3);
      expect(capturedBatches[0].length, batchSize);
      expect(capturedBatches[1].length, batchSize);
      expect(capturedBatches[2].length, 501);
      expect(capturedBatches[0].first, 'asset-0');
      expect(capturedBatches[0].last, 'asset-${batchSize - 1}');
      expect(capturedBatches[1].first, 'asset-$batchSize');
      expect(capturedBatches[1].last, 'asset-${batchSize * 2 - 1}');
      expect(capturedBatches[2].first, 'asset-${batchSize * 2}');
      expect(capturedBatches[2].last, 'asset-${batchSize * 2 + 500}');
      verify(() => localAssetRepository.delete(any())).called(3);
    });

    test('does not touch the deletion-sync exclusions when the feature is disabled', () async {
      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((invocation) async {
        return (invocation.positionalArguments.first as List<String>).toList();
      });
      when(() => localAssetRepository.delete(any())).thenAnswer((_) async {});

      await sut.deleteLocalAssets(['asset-1']);

      verifyNever(() => localDeletionRepository.markExcluded(any()));
      verifyNever(() => localDeletionRepository.unmarkExcluded(any()));
    });

    test('marks the batch as excluded before deleting when the deletion sync is enabled', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);

      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((invocation) async {
        return (invocation.positionalArguments.first as List<String>).toList();
      });
      when(() => localAssetRepository.delete(any())).thenAnswer((_) async {});

      await sut.deleteLocalAssets(['asset-1', 'asset-2']);

      verifyInOrder([
        () => localDeletionRepository.markExcluded(['asset-1', 'asset-2']),
        () => assetMediaRepository.deleteAll(['asset-1', 'asset-2']),
        () => localAssetRepository.delete(['asset-1', 'asset-2']),
      ]);
      verifyNever(() => localDeletionRepository.unmarkExcluded(any()));
    });

    test('unmarks assets whose native deletion failed', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);

      when(() => assetMediaRepository.deleteAll(any())).thenAnswer((_) async => ['asset-1']);
      when(() => localAssetRepository.delete(any())).thenAnswer((_) async {});

      await sut.deleteLocalAssets(['asset-1', 'asset-2']);

      final unmarked =
          verify(() => localDeletionRepository.unmarkExcluded(captureAny())).captured.single as Iterable<String>;
      expect(unmarked, ['asset-2']);
    });

    test('unmarks the whole batch when the native deletion throws', () async {
      await SettingsRepository.instance.write(SettingsKey.backupSyncLocalDeletions, true);

      when(() => assetMediaRepository.deleteAll(any())).thenThrow(Exception('plugin error'));

      await expectLater(sut.deleteLocalAssets(['asset-1', 'asset-2']), throwsException);

      final unmarked =
          verify(() => localDeletionRepository.unmarkExcluded(captureAny())).captured.single as Iterable<String>;
      expect(unmarked, ['asset-1', 'asset-2']);
      verifyNever(() => localAssetRepository.delete(any()));
    });
  });
}
