import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late LocalDeletionRepository sut;
  late String userId;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = LocalDeletionRepository(ctx.db);
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

  group('getBackedUp', () {
    test('returns the remote id and checksum of the users own non-trashed backup', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

      expect(await sut.getBackedUp(userId, ['local-1']), {remote.id: 'checksum-1'});
    });

    test('ignores a partner-owned remote that merely shares the checksum', () async {
      final partner = await ctx.newUser();
      await ctx.newRemoteAsset(ownerId: partner.id, checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

      expect(await sut.getBackedUp(userId, ['local-1']), isEmpty);
    });

    test('ignores an already-trashed remote', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

      expect(await sut.getBackedUp(userId, ['local-1']), isEmpty);
    });

    test('ignores an external-library remote that shares the checksum', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', libraryId: 'library-1');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

      expect(await sut.getBackedUp(userId, ['local-1']), isEmpty);
    });

    test('resolves only the uploaded remote when an external-library copy also matches', () async {
      final uploaded = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', libraryId: 'library-1');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

      expect(await sut.getBackedUp(userId, ['local-1']), {uploaded.id: 'checksum-1'});
    });

    test('ignores local assets that are not backed up', () async {
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

      expect(await sut.getBackedUp(userId, ['local-1']), isEmpty);
    });
  });

  group('getPending', () {
    test('returns the remote ids queued for the account', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'});

      expect(await sut.getPending(userId), unorderedEquals(['remote-1', 'remote-2']));
    });

    test('excludes rows owned by another account', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      await sut.upsert('other-user', {'remote-2': 'checksum-2'});

      expect(await sut.getPending(userId), ['remote-1']);
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

  group('pruneRestored', () {
    test('drops intents whose content is still on the device', () async {
      await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.upsert(userId, {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'});

      await sut.pruneRestored(userId);

      expect(await queuedRemoteIds(), {'remote-2'});
    });

    test('keeps intents of other accounts', () async {
      await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.upsert('other-user', {'remote-1': 'checksum-1'});

      await sut.pruneRestored(userId);

      expect(await queuedRemoteIds(), {'remote-1'});
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
    test('queues assets that disappeared between snapshot and detection', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');

      await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      await sut.queueDeletionsFromSnapshot(userId);

      expect(await queuedChecksums(), {remote.id: 'checksum-1'});
    });

    test('does not queue assets that survived the reconciliation', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newLocalAsset(checksum: 'checksum-1');

      await sut.snapshotBackedUpAssets(userId);
      await sut.queueDeletionsFromSnapshot(userId);

      expect(await queuedRemoteIds(), isEmpty);
    });

    test('skips excluded assets and consumes the exclusion once the row is gone', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.markExcluded([local.id]);

      await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      await sut.queueDeletionsFromSnapshot(userId);

      expect(await queuedRemoteIds(), isEmpty);
      expect(await excludedLocalIds(), isEmpty);
    });

    test('keeps exclusions of assets that still exist', () async {
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.markExcluded([local.id]);

      await sut.snapshotBackedUpAssets(userId);
      await sut.queueDeletionsFromSnapshot(userId);

      expect(await excludedLocalIds(), {local.id});
    });

    test('ignores trashed, partner-owned, and external-library remotes', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-trashed', deletedAt: DateTime(2024));
      final partner = await ctx.newUser();
      await ctx.newRemoteAsset(ownerId: partner.id, checksum: 'checksum-partner');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-library', libraryId: 'library-1');
      final locals = [
        await ctx.newLocalAsset(checksum: 'checksum-trashed'),
        await ctx.newLocalAsset(checksum: 'checksum-partner'),
        await ctx.newLocalAsset(checksum: 'checksum-library'),
      ];

      await sut.snapshotBackedUpAssets(userId);
      for (final local in locals) {
        await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      }
      await sut.queueDeletionsFromSnapshot(userId);

      expect(await queuedRemoteIds(), isEmpty);
    });

    test('detection without a prior snapshot queues nothing', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');

      await sut.queueDeletionsFromSnapshot(userId);

      expect(await queuedRemoteIds(), isEmpty);
    });
  });

  group('deleteAll', () {
    test('removes every queue row and exclusion', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      await sut.upsert('other-user', {'remote-2': 'checksum-2'});
      await sut.markExcluded(['local-1']);

      await sut.deleteAll();

      expect(await queuedRemoteIds(), isEmpty);
      expect(await excludedLocalIds(), isEmpty);
    });
  });
}
