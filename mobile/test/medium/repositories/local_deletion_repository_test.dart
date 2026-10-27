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

    test('ignores assets of iOS shared albums', () async {
      final album = await ctx.newLocalAlbum(isIosSharedAlbum: true);
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: 'local-1');

      expect(await sut.getBackedUp(userId, ['local-1']), isEmpty);
    });

    test('includes assets of iOS shared albums when asked', () async {
      final album = await ctx.newLocalAlbum(isIosSharedAlbum: true);
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: 'local-1');

      expect(await sut.getBackedUp(userId, ['local-1'], includeIosSharedAlbums: true), {remote.id: 'checksum-1'});
    });
  });

  group('countBackedUp', () {
    test('counts the backed-up copies of all local assets as getBackedUp resolves them', () async {
      final partner = await ctx.newUser();
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2');
      await ctx.newRemoteAsset(ownerId: partner.id, checksum: 'checksum-3');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-4', deletedAt: DateTime(2024));
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-5', libraryId: 'library-1');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-6', visibility: AssetVisibility.hidden);
      for (int i = 1; i <= 7; i++) {
        await ctx.newLocalAsset(id: 'local-$i', checksum: 'checksum-$i');
      }

      expect(await sut.countBackedUp(userId), 2);
    });

    test('counts a backed-up copy once when several local assets share it', () async {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-2', checksum: 'checksum-1');

      expect(await sut.countBackedUp(userId), 1);
    });

    test('leaves out assets of iOS shared albums', () async {
      final shared = await ctx.newLocalAlbum(isIosSharedAlbum: true);
      final regular = await ctx.newLocalAlbum();
      for (int i = 1; i <= 3; i++) {
        await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-$i');
        await ctx.newLocalAsset(id: 'local-$i', checksum: 'checksum-$i');
      }
      await ctx.newLocalAlbumAsset(albumId: shared.id, assetId: 'local-1');
      await ctx.newLocalAlbumAsset(albumId: regular.id, assetId: 'local-2');
      await ctx.newLocalAlbumAsset(albumId: regular.id, assetId: 'local-3');

      expect(await sut.countBackedUp(userId), 2);
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

  group('flushed deletions', () {
    test('markTrashed keeps the row but takes it out of the pending queue', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'});

      await sut.markTrashed(['remote-1']);

      expect(await queuedRemoteIds(), {'remote-1', 'remote-2'});
      expect(await sut.getPending(userId, settledBefore: DateTime.now().add(const Duration(minutes: 1))), ['remote-2']);
      expect((await sut.watchPending(userId).first).map((p) => p.remoteId), ['remote-2']);
    });

    test('the prunes of pending intents keep flushed deletions', () async {
      final trashed = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.upsert(userId, {trashed.id: 'checksum-1'});
      await sut.markTrashed([trashed.id]);

      await sut.pruneAlreadyTrashed();
      await sut.pruneRestored(userId);

      expect(await queuedRemoteIds(), {trashed.id});
    });

    test('upsert queues a flushed deletion anew', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      await backdate('remote-1', DateTime.utc(2024));
      await sut.markTrashed(['remote-1']);

      await sut.upsert(userId, {'remote-1': 'checksum-1'});

      final settledBefore = DateTime.now().subtract(kLocalDeletionSettleDuration);
      expect(await sut.getPending(userId, settledBefore: settledBefore), isEmpty);
      expect(await sut.getPending(userId, settledBefore: DateTime.now().add(const Duration(minutes: 1))), ['remote-1']);
    });

    test('getRestored returns the flushed deletions whose content is back while the server copy is trashed', () async {
      final restored = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      final notBack = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2', deletedAt: DateTime(2024));
      final active = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-3');
      final pending = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-4', deletedAt: DateTime(2024));
      final otherUserId = (await ctx.newUser()).id;
      final other = await ctx.newRemoteAsset(ownerId: otherUserId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      for (final checksum in ['checksum-1', 'checksum-3', 'checksum-4']) {
        await ctx.newLocalAsset(checksum: checksum);
      }
      await sut.upsert(userId, {
        restored.id: 'checksum-1',
        notBack.id: 'checksum-2',
        active.id: 'checksum-3',
        pending.id: 'checksum-4',
      });
      await sut.upsert(otherUserId, {other.id: 'checksum-1'});
      await sut.markTrashed([restored.id, notBack.id, active.id, other.id]);

      expect(await sut.getRestored(userId), [restored.id]);
    });

    test('pruneFlushed drops the flushed deletions whose server copy left the trash', () async {
      final trashed = await ctx.newRemoteAsset(ownerId: userId, deletedAt: DateTime(2024));
      final restoredOnServer = await ctx.newRemoteAsset(ownerId: userId);
      await sut.upsert(userId, {
        trashed.id: 'checksum-1',
        restoredOnServer.id: 'checksum-2',
        'remote-purged': 'checksum-3',
        'remote-pending': 'checksum-4',
      });
      await sut.markTrashed([trashed.id, restoredOnServer.id, 'remote-purged']);

      await sut.pruneFlushed();

      expect(await queuedRemoteIds(), {trashed.id, 'remote-pending'});
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

    test('ignores assets of iOS shared albums', () async {
      final shared = await ctx.newLocalAlbum(isIosSharedAlbum: true);
      final regular = await ctx.newLocalAlbum();
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-shared');
      final regularRemote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-regular');
      await ctx.newLocalAsset(id: 'local-shared', checksum: 'checksum-shared');
      await ctx.newLocalAsset(id: 'local-regular', checksum: 'checksum-regular');
      await ctx.newLocalAlbumAsset(albumId: shared.id, assetId: 'local-shared');
      await ctx.newLocalAlbumAsset(albumId: regular.id, assetId: 'local-regular');

      final snapshotId = await sut.snapshotBackedUpAssets(userId);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.isIn(['local-shared', 'local-regular'])).delete();
      final result = await sut.getSnapshotDeletionCandidates(snapshotId);

      expect(result.total, 1);
      expect(result.candidates.map((c) => c.remoteId), [regularRemote.id]);
    });

    test('includes assets of iOS shared albums when asked', () async {
      final album = await ctx.newLocalAlbum(isIosSharedAlbum: true);
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');
      await ctx.newLocalAlbumAsset(albumId: album.id, assetId: 'local-1');

      final snapshotId = await sut.snapshotBackedUpAssets(userId, includeIosSharedAlbums: true);
      await ctx.db.managers.localAssetEntity.filter((r) => r.id.equals('local-1')).delete();
      final result = await sut.getSnapshotDeletionCandidates(snapshotId);

      expect(result.candidates.map((c) => c.remoteId), [remote.id]);
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

  group('getPendingFileSizes', () {
    test('returns the checksum, type and file size of the remote asset of each pending deletion', () async {
      final image = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final video = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2', type: AssetType.video);
      final unknownSize = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-3');
      final noExif = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-4');
      await ctx.newRemoteExif(assetId: image.id, fileSize: 1234);
      await ctx.newRemoteExif(assetId: video.id, fileSize: 5678);
      await ctx.newRemoteExif(assetId: unknownSize.id);
      await sut.upsert(userId, {
        image.id: 'checksum-1',
        video.id: 'checksum-2',
        unknownSize.id: 'checksum-3',
        noExif.id: 'checksum-4',
      });

      final result = await sut.getPendingFileSizes([image.id, video.id, unknownSize.id, noExif.id]);

      expect(result, {
        image.id: (checksum: 'checksum-1', type: AssetType.image.index, fileSize: 1234),
        video.id: (checksum: 'checksum-2', type: AssetType.video.index, fileSize: 5678),
      });
    });

    test('returns only the requested deletions', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final other = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2');
      await ctx.newRemoteExif(assetId: remote.id, fileSize: 1234);
      await ctx.newRemoteExif(assetId: other.id, fileSize: 1234);
      await sut.upsert(userId, {remote.id: 'checksum-1', other.id: 'checksum-2'});

      expect((await sut.getPendingFileSizes([remote.id])).keys, [remote.id]);
    });
  });

  group('getUnhashedByIds', () {
    test('returns the type of the given assets that have no checksum', () async {
      final image = await ctx.newLocalAsset(checksumOption: const Option.none());
      final video = await ctx.newLocalAsset(type: AssetType.video, checksumOption: const Option.none());
      final hashed = await ctx.newLocalAsset();
      await ctx.newLocalAsset(checksumOption: const Option.none());

      expect(await sut.getUnhashedByIds([image.id, video.id, hashed.id, 'unknown']), {
        image.id: AssetType.image.index,
        video.id: AssetType.video.index,
      });
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

  group('clearPending', () {
    test('removes the pending deletions but keeps the flushed ones', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'});
      await sut.markTrashed(['remote-2']);

      await sut.clearPending();

      expect(await queuedRemoteIds(), {'remote-2'});
    });
  });
}
