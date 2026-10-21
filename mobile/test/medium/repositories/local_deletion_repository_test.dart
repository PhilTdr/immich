import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/table/local/deletion.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/utils/option.dart';

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

  Future<void> backdate(String remoteId, DateTime createdAt) {
    return (ctx.db.update(
      ctx.db.localDeletionEntity,
    )..where((row) => row.remoteId.equals(remoteId))).write(LocalDeletionEntityCompanion(createdAt: .new(createdAt)));
  }

  group('upsert', () {
    test('inserts and updates queue rows keyed by remote id', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      expect(await queuedRemoteIds(), {'remote-1'});

      await sut.upsert(userId, {'remote-1': 'checksum-1-updated', 'remote-2': 'checksum-2'});
      expect(await queuedChecksums(), {'remote-1': 'checksum-1-updated', 'remote-2': 'checksum-2'});
    });

    test('keeps the original createdAt when an intent is queued again', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      await backdate('remote-1', DateTime.utc(2024));

      await sut.upsert(userId, {'remote-1': 'checksum-1'});

      final row = await ctx.db.select(ctx.db.localDeletionEntity).getSingle();
      expect(row.createdAt.isAtSameMomentAs(DateTime.utc(2024)), isTrue);
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

    test('ignores hidden and locked remotes', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', visibility: AssetVisibility.hidden);
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2', visibility: AssetVisibility.locked);
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-2', checksum: 'checksum-2');

      expect(await sut.getBackedUp(userId, ['local-1', 'local-2']), isEmpty);
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

      expect(
        await sut.getPending(userId, settledBefore: DateTime.now().add(const Duration(minutes: 1))),
        unorderedEquals(['remote-1', 'remote-2']),
      );
    });

    test('excludes rows owned by another account', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      await sut.upsert('other-user', {'remote-2': 'checksum-2'});

      expect(await sut.getPending(userId, settledBefore: DateTime.now().add(const Duration(minutes: 1))), ['remote-1']);
    });

    test('returns only intents queued before the settle window', () async {
      await sut.upsert(userId, {'remote-settled': 'checksum-1', 'remote-fresh': 'checksum-2'});
      await backdate(
        'remote-settled',
        DateTime.now().subtract(kLocalDeletionSettleDuration + const Duration(minutes: 1)),
      );

      final settledBefore = DateTime.now().subtract(kLocalDeletionSettleDuration);
      expect(await sut.getPending(userId, settledBefore: settledBefore), ['remote-settled']);
    });
  });

  group('watchPending', () {
    test('emits the intents of the account oldest first, with their remote asset', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await sut.upsert(userId, {remote.id: 'checksum-1', 'remote-unknown': 'checksum-2'});
      await sut.upsert('other-user', {'remote-other': 'checksum-3'});
      await backdate('remote-unknown', DateTime.utc(2024));

      final pending = await sut.watchPending(userId).first;

      expect(pending.map((p) => p.remoteId), ['remote-unknown', remote.id]);
      expect(pending.first.name, isNull);
      expect(pending.last.name, remote.name);
      expect(pending.last.thumbHash, remote.thumbHash);
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
    test('returns candidates for assets that disappeared between snapshot and detection', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');

      final snapshotId = await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      final result = await sut.getSnapshotDeletionCandidates(snapshotId);

      expect(result.total, 1);
      expect(result.candidates, [(localId: local.id, remoteId: remote.id, checksum: 'checksum-1')]);
    });

    test('returns candidates for assets the Android album reconciliation removed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final albums = LocalAlbumRepository(ctx.db);
      await ctx.newLocalAlbum(id: 'camera');
      await ctx.newLocalAlbum(id: 'vanished');
      for (final (id, albumId) in [('kept', 'camera'), ('deleted', 'camera'), ('in-vanished', 'vanished')]) {
        await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-$id');
        await ctx.newLocalAsset(id: id, checksum: 'checksum-$id');
        await ctx.newLocalAlbumAsset(albumId: albumId, assetId: id);
      }

      final snapshotId = await sut.snapshotBackedUpAssets(userId);
      await albums.updateAll([LocalAlbum(id: 'camera', name: 'Camera', updatedAt: DateTime(2026))]);
      await albums.syncDeletes('camera', ['kept']);
      final result = await sut.getSnapshotDeletionCandidates(snapshotId);

      expect(result.total, 3);
      expect(result.candidates.map((c) => c.localId), unorderedEquals(['deleted', 'in-vanished']));
    });

    test('omits assets that survived the reconciliation', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newLocalAsset(checksum: 'checksum-1');

      final snapshotId = await sut.snapshotBackedUpAssets(userId);
      final result = await sut.getSnapshotDeletionCandidates(snapshotId);

      expect(result.candidates, isEmpty);
      expect(result.total, 1);
    });

    test('omits excluded assets and consumes the exclusion once the row is gone', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.markExcluded([local.id]);

      final snapshotId = await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      final result = await sut.getSnapshotDeletionCandidates(snapshotId);
      await sut.clearSnapshotAndConsumeExclusions(snapshotId);

      expect(result.candidates, isEmpty);
      expect(await excludedLocalIds(), isEmpty);
    });

    test('keeps exclusions of assets that still exist', () async {
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.markExcluded([local.id]);

      final snapshotId = await sut.snapshotBackedUpAssets(userId);
      await sut.clearSnapshotAndConsumeExclusions(snapshotId);

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

      final snapshotId = await sut.snapshotBackedUpAssets(userId);
      for (final local in locals) {
        await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      }
      final result = await sut.getSnapshotDeletionCandidates(snapshotId);

      expect(result.candidates, isEmpty);
    });

    test('detection without a prior snapshot returns nothing', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');

      final result = await sut.getSnapshotDeletionCandidates(1);

      expect(result.candidates, isEmpty);
      expect(result.total, 0);
    });

    test('keeps the snapshots of concurrent syncs apart', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2');
      await ctx.newLocalAsset(checksum: 'checksum-2');

      final first = await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      final second = await sut.snapshotBackedUpAssets(userId);
      await sut.clearSnapshotAndConsumeExclusions(second);
      final result = await sut.getSnapshotDeletionCandidates(first);

      expect(result.total, 2);
      expect(result.candidates, [(localId: local.id, remoteId: remote.id, checksum: 'checksum-1')]);
    });

    test('keeps exclusions that another snapshot still needs', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.markExcluded([local.id]);

      final first = await sut.snapshotBackedUpAssets(userId);
      final second = await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      await sut.clearSnapshotAndConsumeExclusions(first);

      expect(await excludedLocalIds(), {local.id});
      expect((await sut.getSnapshotDeletionCandidates(second)).candidates, isEmpty);

      await sut.clearSnapshotAndConsumeExclusions(second);

      expect(await excludedLocalIds(), isEmpty);
    });

    test('consumeExcluded keeps exclusions that a snapshot still needs', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final local = await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.markExcluded([local.id, 'local-other']);

      final snapshotId = await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals(local.id)).delete();
      await sut.consumeExcluded([local.id, 'local-other']);

      expect(await excludedLocalIds(), {local.id});
      expect((await sut.getSnapshotDeletionCandidates(snapshotId)).candidates, isEmpty);
    });

    test('drops the snapshots of syncs that never reached their detection', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.snapshotBackedUpAssets(userId);
      await ctx.db.customStatement('UPDATE local_deletion_snapshot SET snapshot_id = 1');

      await sut.snapshotBackedUpAssets(userId);

      expect((await sut.getSnapshotDeletionCandidates(1)).total, 0);
    });
  });

  group('getMoveCandidates', () {
    test('returns the unhashed files with the name and type of the deleted remote asset', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await sut.upsert(userId, {remote.id: 'checksum-1'});
      final copy = await ctx.newLocalAsset(name: remote.name, checksumOption: const Option.none());
      await ctx.newLocalAsset(name: remote.name.replaceFirst('.jpg', ' (1).jpg'), checksumOption: const Option.none());
      await ctx.newLocalAsset(name: remote.name);
      await ctx.newLocalAsset(name: 'other.jpg', checksumOption: const Option.none());
      await ctx.newLocalAsset(name: remote.name, type: AssetType.video, checksumOption: const Option.none());

      final result = await sut.getMoveCandidates([remote.id]);

      expect(result.keys, [remote.id]);
      expect(result[remote.id]!.checksum, 'checksum-1');
      expect(result[remote.id]!.localIds, [copy.id]);
    });

    test('returns nothing for deletions without a same-named file', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await sut.upsert(userId, {remote.id: 'checksum-1'});
      await ctx.newLocalAsset(name: 'other.jpg', checksumOption: const Option.none());

      expect(await sut.getMoveCandidates([remote.id]), isEmpty);
    });
  });

  group('clearQueue', () {
    test('removes every queue row but keeps the exclusions', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      await sut.upsert('other-user', {'remote-2': 'checksum-2'});
      await sut.markExcluded(['local-1']);

      await sut.clearQueue();

      expect(await queuedRemoteIds(), isEmpty);
      expect(await excludedLocalIds(), {'local-1'});
    });
  });
}
