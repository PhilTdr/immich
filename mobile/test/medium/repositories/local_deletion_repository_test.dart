import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late DriftLocalDeletionRepository sut;
  late String userId;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = DriftLocalDeletionRepository(ctx.db);
    userId = (await ctx.newUser()).id;
  });

  tearDown(() async {
    await ctx.dispose();
  });

  Future<Set<String>> queuedRemoteIds() async {
    final rows = await ctx.db.select(ctx.db.localDeletionEntity).get();
    return rows.map((r) => r.remoteId).toSet();
  }

  Future<Map<String, String>> queuedChecksums() async {
    final rows = await ctx.db.select(ctx.db.localDeletionEntity).get();
    return {for (final r in rows) r.remoteId: r.checksum};
  }

  Future<Set<String>> excludedLocalIds() async {
    final rows = await ctx.db.select(ctx.db.localDeletionExclusionEntity).get();
    return rows.map((r) => r.localId).toSet();
  }

  group('upsert', () {
    test('inserts and updates queue rows keyed by remote id', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      expect(await queuedRemoteIds(), {'remote-1'});

      await sut.upsert(userId, {'remote-1': 'checksum-1-updated', 'remote-2': 'checksum-2'});
      expect(await queuedChecksums(), {'remote-1': 'checksum-1-updated', 'remote-2': 'checksum-2'});
    });
  });

  group('getPending', () {
    test('returns the current accounts queued rows', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'});

      final pending = await sut.getPending(userId);
      expect(pending.map((e) => e.remoteId).toSet(), {'remote-1', 'remote-2'});
      expect(pending.map((e) => e.checksum).toSet(), {'checksum-1', 'checksum-2'});
    });

    test('excludes rows owned by another account', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      await sut.upsert('other-user', {'remote-2': 'checksum-2'});

      final pending = await sut.getPending(userId);
      expect(pending.map((e) => e.remoteId).toSet(), {'remote-1'});
    });
  });

  group('deleteByRemoteIds', () {
    test('removes the given queue rows', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'});

      await sut.deleteByRemoteIds(['remote-1']);

      expect(await queuedRemoteIds(), {'remote-2'});
    });
  });

  group('pruneAlreadyTrashed', () {
    test('drops intents whose remote asset is already trashed', () async {
      final trashed = await ctx.newRemoteAsset(ownerId: userId, deletedAt: DateTime(2024));
      final alive = await ctx.newRemoteAsset(ownerId: userId);
      await sut.upsert(userId, {trashed.id: 'checksum-1', alive.id: 'checksum-2', 'remote-unknown': 'checksum-3'});

      await sut.pruneAlreadyTrashed();

      // Intents for unknown remotes are kept. The flush resolves them per id.
      expect(await queuedRemoteIds(), {alive.id, 'remote-unknown'});
    });
  });

  group('exclusions', () {
    test('markExcluded / getExcluded / unmarkExcluded round-trip', () async {
      await sut.markExcluded(['local-1', 'local-2']);

      expect(await sut.getExcluded(['local-1', 'local-2', 'local-3']), {'local-1', 'local-2'});

      await sut.unmarkExcluded(['local-1']);
      expect(await excludedLocalIds(), {'local-2'});
    });

    test('markExcluded is idempotent', () async {
      await sut.markExcluded(['local-1']);
      await sut.markExcluded(['local-1']);

      expect(await excludedLocalIds(), {'local-1'});
    });
  });

  group('snapshot deletion detection', () {
    test('returns candidates for assets that disappeared between snapshot and detection', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');

      await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      final result = await sut.getSnapshotDeletionCandidates();

      expect(result.total, 1);
      expect(result.candidates, [(localId: local.id, remoteId: remote.id, checksum: 'checksum-1')]);
    });

    test('omits assets that survived the reconciliation', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newLocalAsset(checksum: 'checksum-1');

      await sut.snapshotBackedUpAssets(userId);
      final result = await sut.getSnapshotDeletionCandidates();

      expect(result.candidates, isEmpty);
      expect(result.total, 1);
    });

    test('omits excluded assets and consumes the exclusion once the row is gone', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.markExcluded([local.id]);

      await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      final result = await sut.getSnapshotDeletionCandidates();
      await sut.clearSnapshotAndConsumeExclusions();

      expect(result.candidates, isEmpty);
      expect(await excludedLocalIds(), isEmpty);
    });

    test('keeps exclusions of assets that still exist', () async {
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.markExcluded([local.id]);

      await sut.snapshotBackedUpAssets(userId);
      await sut.clearSnapshotAndConsumeExclusions();

      expect(await excludedLocalIds(), {local.id});
    });

    test('ignores trashed, partner-owned, external-library, hidden, and locked remotes', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-trashed', deletedAt: DateTime(2024));
      final partner = await ctx.newUser();
      await ctx.newRemoteAsset(ownerId: partner.id, checksum: 'checksum-partner');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-library', libraryId: 'library-1');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-hidden', visibility: AssetVisibility.hidden);
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-locked', visibility: AssetVisibility.locked);
      final locals = [
        await ctx.newLocalAsset(checksum: 'checksum-trashed'),
        await ctx.newLocalAsset(checksum: 'checksum-partner'),
        await ctx.newLocalAsset(checksum: 'checksum-library'),
        await ctx.newLocalAsset(checksum: 'checksum-hidden'),
        await ctx.newLocalAsset(checksum: 'checksum-locked'),
      ];

      await sut.snapshotBackedUpAssets(userId);
      for (final local in locals) {
        await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      }
      final result = await sut.getSnapshotDeletionCandidates();

      expect(result.candidates, isEmpty);
    });

    test('detection without a prior snapshot returns nothing', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');

      final result = await sut.getSnapshotDeletionCandidates();

      expect(result.candidates, isEmpty);
      expect(result.total, 0);
    });
  });

  group('clearQueue', () {
    test('removes every queue row but keeps the exclusions', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      await sut.upsert('other-user', {'remote-2': 'checksum-2'});
      await sut.markExcluded(['local-1']);

      await sut.clearQueue();

      expect(await queuedRemoteIds(), isEmpty);
      expect(await excludedLocalIds(), ['local-1']);
    });
  });
}
