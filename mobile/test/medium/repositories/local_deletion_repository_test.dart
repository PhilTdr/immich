import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/dao/local_deletion.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

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
    return rows.map((row) => row.remoteId).toSet();
  }

  Future<void> newLocalAssetInAlbum(String albumId, {required String checksum}) async {
    final asset = await ctx.newLocalAsset(checksum: checksum);
    await ctx.newLocalAlbumAsset(albumId: albumId, assetId: asset.id);
  }

  group('getBackedUp', () {
    test('returns only the own, visible and backed-up assets of the backup albums', () async {
      final partner = await ctx.newUser();
      await ctx.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
      await ctx.newLocalAlbum(id: 'downloads');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-backed-up');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-outside-backup');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-trashed', deletedAt: DateTime(2024));
      await ctx.newRemoteAsset(ownerId: partner.id, checksum: 'checksum-partner');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-library', libraryId: 'library-1');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-hidden', visibility: AssetVisibility.hidden);
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-locked', visibility: AssetVisibility.locked);
      final ids = ['backed-up', 'outside-backup', 'trashed', 'partner', 'library', 'hidden', 'locked', 'not-backed-up'];
      for (final id in ids) {
        await ctx.newLocalAsset(id: id, checksum: 'checksum-$id');
        await ctx.newLocalAlbumAsset(albumId: id == 'outside-backup' ? 'downloads' : 'camera', assetId: id);
      }

      final backedUp = await sut.getBackedUp(userId, ids);

      expect(backedUp.map((asset) => asset.localId), ['backed-up']);
    });

    test('lists an asset under its smallest album, or under its largest smart album if it is in no other', () async {
      final albums = {
        'recents': ['a1', 'a2', 'a3', 'a4'],
        'selfies': ['a1', 'a3'],
        'trip': ['a1', 'a2', 'a4'],
        'day': ['a4'],
      };
      for (final id in albums['recents']!) {
        await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-$id');
        await ctx.newLocalAsset(id: id, checksum: 'checksum-$id');
      }
      for (final MapEntry(key: albumId, value: assetIds) in albums.entries) {
        await ctx.newLocalAlbum(id: albumId, backupSelection: BackupSelection.selected);
        for (final assetId in assetIds) {
          await ctx.newLocalAlbumAsset(albumId: albumId, assetId: assetId);
        }
      }

      final backedUp = await sut.getBackedUp(userId, albums['recents']!, smartAlbumIds: ['recents', 'selfies']);

      expect(
        {for (final asset in backedUp) asset.localId: asset.albumId},
        {'a1': 'trip', 'a2': 'trip', 'a3': 'recents', 'a4': 'day'},
      );
    });
  });

  group('upsert', () {
    test('queues a deletion anew that was sent already', () async {
      await ctx.newLocalDeletion(
        remoteId: 'remote-1',
        ownerId: userId,
        createdAt: DateTime.utc(2024),
        trashedAt: DateTime.utc(2024),
      );

      await sut.upsert(userId, [
        (
          localId: 'local-1',
          remoteId: 'remote-1',
          checksum: 'checksum-1',
          name: 'a.jpg',
          inIosSharedAlbum: false,
          albumId: null,
          albumName: null,
        ),
      ]);

      expect(await sut.getToTrash(userId, settledBefore: DateTime.now().subtract(const Duration(minutes: 1))), isEmpty);
      expect(await sut.getToTrash(userId, settledBefore: DateTime.now().add(const Duration(minutes: 1))), ['remote-1']);
    });
  });

  group('getToTrash', () {
    test('returns the settled deletions of the account that are neither held nor sent', () async {
      final settledBefore = DateTime.now().subtract(const Duration(minutes: 15));
      final settled = settledBefore.subtract(const Duration(minutes: 1));
      await ctx.newLocalDeletion(remoteId: 'settled', ownerId: userId, createdAt: settled);
      await ctx.newLocalDeletion(remoteId: 'fresh', ownerId: userId);
      await ctx.newLocalDeletion(remoteId: 'held', ownerId: userId, createdAt: settled, awaitingConfirmation: true);
      await ctx.newLocalDeletion(remoteId: 'sent', ownerId: userId, createdAt: settled, trashedAt: DateTime.now());
      await ctx.newLocalDeletion(remoteId: 'other', ownerId: 'other-user', createdAt: settled);

      expect(await sut.getToTrash(userId, settledBefore: settledBefore), ['settled']);
    });
  });

  group('confirm', () {
    test('releases held deletions', () async {
      final settled = DateTime.utc(2024);
      await ctx.newLocalDeletion(remoteId: 'held-1', ownerId: userId, createdAt: settled, awaitingConfirmation: true);
      await ctx.newLocalDeletion(remoteId: 'held-2', ownerId: userId, createdAt: settled, awaitingConfirmation: true);

      await sut.confirm(['held-1']);

      expect(await sut.getToTrash(userId, settledBefore: DateTime.now()), ['held-1']);
    });
  });

  group('markTrashed', () {
    test('takes a deletion out of the pending queue but keeps its row', () async {
      await ctx.newLocalDeletion(remoteId: 'remote-1', ownerId: userId, createdAt: DateTime.utc(2024));
      await ctx.newLocalDeletion(remoteId: 'remote-2', ownerId: userId, createdAt: DateTime.utc(2024));

      await sut.markTrashed(['remote-1']);

      expect(await queuedRemoteIds(), {'remote-1', 'remote-2'});
      expect(await sut.getToTrash(userId, settledBefore: DateTime.now()), ['remote-2']);
    });
  });

  group('prune', () {
    test('drops pending deletions whose server copy is already trashed or whose file is in a backup album', () async {
      final trashed = await ctx.newRemoteAsset(ownerId: userId, deletedAt: DateTime(2024));
      final alive = await ctx.newRemoteAsset(ownerId: userId);
      await ctx.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
      await ctx.newLocalAlbum(id: 'downloads');
      await newLocalAssetInAlbum('camera', checksum: 'checksum-in-backup');
      await newLocalAssetInAlbum('camera', checksum: 'checksum-held');
      await newLocalAssetInAlbum('downloads', checksum: 'checksum-moved-out');
      await ctx.newLocalDeletion(remoteId: trashed.id, ownerId: userId);
      await ctx.newLocalDeletion(remoteId: alive.id, ownerId: userId);
      await ctx.newLocalDeletion(remoteId: 'remote-unknown', ownerId: userId);
      await ctx.newLocalDeletion(remoteId: 'remote-in-backup', ownerId: userId, checksum: 'checksum-in-backup');
      await ctx.newLocalDeletion(remoteId: 'remote-moved-out', ownerId: userId, checksum: 'checksum-moved-out');
      await ctx.newLocalDeletion(
        remoteId: 'remote-held',
        ownerId: userId,
        checksum: 'checksum-held',
        awaitingConfirmation: true,
      );

      await sut.prune(userId);

      expect(await queuedRemoteIds(), {alive.id, 'remote-unknown', 'remote-moved-out'});
    });

    test('drops sent deletions whose server copy left the trash', () async {
      final trashedAt = DateTime.now();
      final trashed = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      final restoredOnServer = await ctx.newRemoteAsset(ownerId: userId);
      await ctx.newLocalAsset(checksum: 'checksum-1');
      await ctx.newLocalDeletion(remoteId: trashed.id, ownerId: userId, checksum: 'checksum-1', trashedAt: trashedAt);
      await ctx.newLocalDeletion(remoteId: restoredOnServer.id, ownerId: userId, trashedAt: trashedAt);
      await ctx.newLocalDeletion(remoteId: 'remote-purged', ownerId: userId, trashedAt: trashedAt);
      await ctx.newLocalDeletion(remoteId: 'remote-pending', ownerId: userId);

      await sut.prune(userId);

      expect(await queuedRemoteIds(), {trashed.id, 'remote-pending'});
    });
  });

  group('getToRestore', () {
    test('returns the sent deletions whose file is back in a backup album', () async {
      final trashedAt = DateTime.now();
      final restored = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      final notBack = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2', deletedAt: DateTime(2024));
      final active = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-3');
      final pending = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-4', deletedAt: DateTime(2024));
      final movedOut = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-5', deletedAt: DateTime(2024));
      await ctx.newLocalAlbum(id: 'camera', backupSelection: BackupSelection.selected);
      await ctx.newLocalAlbum(id: 'downloads');
      for (final checksum in ['checksum-1', 'checksum-3', 'checksum-4']) {
        await newLocalAssetInAlbum('camera', checksum: checksum);
      }
      await newLocalAssetInAlbum('downloads', checksum: 'checksum-5');
      await ctx.newLocalDeletion(remoteId: restored.id, ownerId: userId, checksum: 'checksum-1', trashedAt: trashedAt);
      await ctx.newLocalDeletion(remoteId: notBack.id, ownerId: userId, checksum: 'checksum-2', trashedAt: trashedAt);
      await ctx.newLocalDeletion(remoteId: active.id, ownerId: userId, checksum: 'checksum-3', trashedAt: trashedAt);
      await ctx.newLocalDeletion(remoteId: pending.id, ownerId: userId, checksum: 'checksum-4');
      await ctx.newLocalDeletion(remoteId: movedOut.id, ownerId: userId, checksum: 'checksum-5', trashedAt: trashedAt);

      expect(await sut.getToRestore(userId), [restored.id]);
    });
  });
}
