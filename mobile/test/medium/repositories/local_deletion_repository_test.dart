import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/data/db/main/table/local/deletion.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
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

  Map<String, DeletedAsset> deleted(Map<String, String> checksums) => {
    for (final MapEntry(key: remoteId, value: checksum) in checksums.entries)
      remoteId: (checksum: checksum, albumId: null, albumName: null),
  };

  Future<Set<String>> queuedRemoteIds() async {
    final rows = await ctx.db.select(ctx.db.localDeletionEntity).get();
    return rows.map((r) => r.remoteId).toSet();
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

  Future<Set<String>> awaitingRemoteIds() async {
    final rows = await (ctx.db.select(
      ctx.db.localDeletionEntity,
    )..where((row) => row.awaitingConfirmation.equals(true))).get();
    return rows.map((r) => r.remoteId).toSet();
  }

  // Recents holds every asset, Selfies and Trip two each
  Future<void> seedIosLibrary() async {
    await ctx.newLocalAlbum(id: 'recents', name: 'Recents');
    await ctx.newLocalAlbum(id: 'selfies', name: 'Selfies');
    await ctx.newLocalAlbum(id: 'trip', name: 'Trip');
    for (int i = 1; i <= 3; i++) {
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-$i');
      await ctx.newLocalAsset(id: 'local-$i', checksum: 'checksum-$i');
      await ctx.newLocalAlbumAsset(albumId: 'recents', assetId: 'local-$i');
    }
    await ctx.newLocalAlbumAsset(albumId: 'selfies', assetId: 'local-1');
    await ctx.newLocalAlbumAsset(albumId: 'trip', assetId: 'local-1');
    await ctx.newLocalAlbumAsset(albumId: 'trip', assetId: 'local-2');
    await ctx.newLocalAlbumAsset(albumId: 'selfies', assetId: 'local-3');
  }

  group('upsert', () {
    test('keeps the original createdAt when a deletion is queued again', () async {
      await sut.upsert(userId, deleted({'remote-1': 'checksum-1'}));
      await backdate('remote-1', DateTime.utc(2024));

      await sut.upsert(userId, deleted({'remote-1': 'checksum-1'}));

      final row = await ctx.db.select(ctx.db.localDeletionEntity).getSingle();
      expect(row.createdAt.isAtSameMomentAs(DateTime.utc(2024)), isTrue);
    });
  });

  group('getBackedUp', () {
    test('ignores trashed, partner-owned, external-library, hidden, locked and not backed-up assets', () async {
      final partner = await ctx.newUser();
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-trashed', deletedAt: DateTime(2024));
      await ctx.newRemoteAsset(ownerId: partner.id, checksum: 'checksum-partner');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-library', libraryId: 'library-1');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-hidden', visibility: AssetVisibility.hidden);
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-locked', visibility: AssetVisibility.locked);
      final ids = ['trashed', 'partner', 'library', 'hidden', 'locked', 'not-backed-up'];
      for (final id in ids) {
        await ctx.newLocalAsset(id: id, checksum: 'checksum-$id');
      }

      expect(await sut.getBackedUp(userId, ids), isEmpty);
    });

    test('skips excluded assets', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-2', checksum: 'checksum-2');
      await sut.markExcluded(['local-2']);

      expect((await sut.getBackedUp(userId, ['local-1', 'local-2'])).map((asset) => asset.remoteId), [remote.id]);
    });

    test('includes and flags the assets of iOS shared albums only when asked', () async {
      final shared = await ctx.newLocalAlbum(isIosSharedAlbum: true);
      final regular = await ctx.newLocalAlbum();
      for (final (id, albumId) in [('local-shared', shared.id), ('local-regular', regular.id)]) {
        await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-$id');
        await ctx.newLocalAsset(id: id, checksum: 'checksum-$id');
        await ctx.newLocalAlbumAsset(albumId: albumId, assetId: id);
      }

      Future<Map<String, bool>> inIosSharedAlbum({required bool includeIosSharedAlbums}) async => {
        for (final asset in await sut.getBackedUp(userId, [
          'local-shared',
          'local-regular',
        ], includeIosSharedAlbums: includeIosSharedAlbums))
          asset.localId: asset.inIosSharedAlbum,
      };
      expect(await inIosSharedAlbum(includeIosSharedAlbums: false), {'local-regular': false});
      expect(await inIosSharedAlbum(includeIosSharedAlbums: true), {'local-shared': true, 'local-regular': false});
    });

    group('album', () {
      Future<Map<String, String?>> albumNameByChecksum({List<String> smartAlbumIds = const []}) async {
        final backedUp = await sut.getBackedUp(userId, ['local-1', 'local-2', 'local-3'], smartAlbumIds: smartAlbumIds);
        return {for (final asset in backedUp) asset.checksum: asset.albumName};
      }

      test('lists each asset under the smallest album it is in', () async {
        await seedIosLibrary();

        expect(await albumNameByChecksum(), {'checksum-1': 'Selfies', 'checksum-2': 'Trip', 'checksum-3': 'Selfies'});
        expect((await sut.getBackedUp(userId, ['local-2'])).single.albumId, 'trip');
      });

      test('prefers albums over smart albums, and the largest smart album over the others', () async {
        await seedIosLibrary();

        expect(await albumNameByChecksum(smartAlbumIds: ['recents', 'selfies']), {
          'checksum-1': 'Trip',
          'checksum-2': 'Trip',
          'checksum-3': 'Recents',
        });
      });

      test('leaves the album out for assets in no album', () async {
        final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
        final local = await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

        expect(await sut.getBackedUp(userId, ['local-1']), [
          (
            localId: 'local-1',
            remoteId: remote.id,
            checksum: 'checksum-1',
            name: local.name,
            inIosSharedAlbum: false,
            albumId: null,
            albumName: null,
          ),
        ]);
      });
    });
  });

  group('awaiting confirmation', () {
    Future<void> queueHeldAndScheduled() async {
      await sut.upsert(
        userId,
        deleted({'remote-held-1': 'checksum-1', 'remote-held-2': 'checksum-2'}),
        awaitingConfirmation: true,
      );
      await sut.upsert(userId, deleted({'remote-scheduled': 'checksum-3'}));
    }

    test('hasAwaitingConfirmation only sees held deletions of the account', () async {
      expect(await sut.hasAwaitingConfirmation(userId), isFalse);

      await sut.upsert('other-user', deleted({'remote-other': 'checksum-1'}), awaitingConfirmation: true);
      await sut.upsert(userId, deleted({'remote-1': 'checksum-2'}));
      expect(await sut.hasAwaitingConfirmation(userId), isFalse);

      await sut.upsert(userId, deleted({'remote-2': 'checksum-3'}), awaitingConfirmation: true);
      expect(await sut.hasAwaitingConfirmation(userId), isTrue);
    });

    test('holdForConfirmation holds the pending deletions but not the flushed ones', () async {
      await sut.upsert(userId, deleted({'remote-1': 'checksum-1', 'remote-2': 'checksum-2', 'remote-3': 'checksum-3'}));
      await sut.markTrashed(['remote-2']);

      await sut.holdForConfirmation(['remote-1', 'remote-2']);

      expect(await awaitingRemoteIds(), {'remote-1'});
    });

    test('confirm releases the deletions to the queue', () async {
      await queueHeldAndScheduled();

      await sut.confirm(['remote-held-1']);

      expect(await awaitingRemoteIds(), {'remote-held-2'});
      expect(
        await sut.getToTrash(userId, settledBefore: DateTime.now().add(const Duration(minutes: 1))),
        unorderedEquals(['remote-held-1', 'remote-scheduled']),
      );
    });

    test('discard drops only the deletions that await confirmation', () async {
      await queueHeldAndScheduled();

      await sut.discard(['remote-held-1', 'remote-scheduled']);

      expect(await queuedRemoteIds(), {'remote-held-2', 'remote-scheduled'});
    });
  });

  group('getToTrash', () {
    test('returns the deletions of the account that were queued before the settle window', () async {
      await sut.upsert(userId, deleted({'remote-settled': 'checksum-1', 'remote-fresh': 'checksum-2'}));
      await sut.upsert('other-user', deleted({'remote-other': 'checksum-3'}));
      final settledBefore = DateTime.now().subtract(kLocalDeletionSettleDuration);
      for (final remoteId in ['remote-settled', 'remote-other']) {
        await backdate(remoteId, settledBefore.subtract(const Duration(minutes: 1)));
      }

      expect(await sut.getToTrash(userId, settledBefore: settledBefore), ['remote-settled']);
    });
  });

  group('watchPending', () {
    test('emits the deletions of the account oldest first, with their album and remote asset', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await sut.upsert(userId, {
        remote.id: (checksum: 'checksum-1', albumId: 'album-1', albumName: 'Camera'),
      }, awaitingConfirmation: true);
      await sut.upsert(userId, deleted({'remote-unknown': 'checksum-2'}));
      await sut.upsert('other-user', deleted({'remote-other': 'checksum-3'}));
      await backdate('remote-unknown', DateTime.utc(2024));

      final pending = await sut.watchPending(userId).first;

      expect(pending.map((p) => p.remoteId), ['remote-unknown', remote.id]);
      expect(pending.first.name, isNull);
      expect(pending.first.awaitingConfirmation, isFalse);
      expect(pending.last.name, remote.name);
      expect(pending.last.thumbHash, remote.thumbHash);
      expect((pending.last.albumId, pending.last.albumName), ('album-1', 'Camera'));
      expect(pending.last.awaitingConfirmation, isTrue);
    });
  });

  group('prune', () {
    test('drops deletions whose remote asset is already trashed', () async {
      final trashed = await ctx.newRemoteAsset(ownerId: userId, deletedAt: DateTime(2024));
      final alive = await ctx.newRemoteAsset(ownerId: userId);
      await sut.upsert(
        userId,
        deleted({trashed.id: 'checksum-1', alive.id: 'checksum-2', 'remote-unknown': 'checksum-3'}),
      );

      await sut.prune(userId);

      // Unknown remotes are left to the flush
      expect(await queuedRemoteIds(), {alive.id, 'remote-unknown'});
    });

    test('drops deletions whose content is still on the device', () async {
      await ctx.newLocalAsset(checksum: 'checksum-1');
      await ctx.newLocalAsset(checksum: 'checksum-3');
      await sut.upsert(userId, deleted({'remote-1': 'checksum-1', 'remote-2': 'checksum-2'}));
      await sut.upsert(userId, deleted({'remote-held': 'checksum-3'}), awaitingConfirmation: true);

      await sut.prune(userId);

      expect(await queuedRemoteIds(), {'remote-2'});
    });

    test('keeps deletions of other accounts', () async {
      await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.upsert('other-user', deleted({'remote-1': 'checksum-1', 'remote-purged': 'checksum-2'}));
      await sut.markTrashed(['remote-purged']);

      await sut.prune(userId);

      expect(await queuedRemoteIds(), {'remote-1', 'remote-purged'});
    });

    test('keeps flushed deletions whose server copy is still trashed', () async {
      final trashed = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(checksum: 'checksum-1');
      await sut.upsert(userId, deleted({trashed.id: 'checksum-1'}));
      await sut.markTrashed([trashed.id]);

      await sut.prune(userId);

      expect(await queuedRemoteIds(), {trashed.id});
    });

    test('drops flushed deletions whose server copy left the trash', () async {
      final trashed = await ctx.newRemoteAsset(ownerId: userId, deletedAt: DateTime(2024));
      final restoredOnServer = await ctx.newRemoteAsset(ownerId: userId);
      await sut.upsert(
        userId,
        deleted({
          trashed.id: 'checksum-1',
          restoredOnServer.id: 'checksum-2',
          'remote-purged': 'checksum-3',
          'remote-pending': 'checksum-4',
        }),
      );
      await sut.markTrashed([trashed.id, restoredOnServer.id, 'remote-purged']);

      await sut.prune(userId);

      expect(await queuedRemoteIds(), {trashed.id, 'remote-pending'});
    });
  });

  group('flushed deletions', () {
    test('markTrashed keeps the row but takes it out of the pending queue', () async {
      await sut.upsert(userId, deleted({'remote-1': 'checksum-1', 'remote-2': 'checksum-2'}));

      await sut.markTrashed(['remote-1']);

      expect(await queuedRemoteIds(), {'remote-1', 'remote-2'});
      expect(await sut.getToTrash(userId, settledBefore: DateTime.now().add(const Duration(minutes: 1))), ['remote-2']);
      expect((await sut.watchPending(userId).first).map((p) => p.remoteId), ['remote-2']);
    });

    test('upsert queues a flushed deletion anew', () async {
      await sut.upsert(userId, deleted({'remote-1': 'checksum-1'}));
      await backdate('remote-1', DateTime.utc(2024));
      await sut.markTrashed(['remote-1']);

      await sut.upsert(userId, deleted({'remote-1': 'checksum-1'}));

      final settledBefore = DateTime.now().subtract(kLocalDeletionSettleDuration);
      expect(await sut.getToTrash(userId, settledBefore: settledBefore), isEmpty);
      expect(await sut.getToTrash(userId, settledBefore: DateTime.now().add(const Duration(minutes: 1))), ['remote-1']);
    });

    test('getToRestore returns flushed deletions whose file is back', () async {
      final restored = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      final notBack = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2', deletedAt: DateTime(2024));
      final active = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-3');
      final pending = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-4', deletedAt: DateTime(2024));
      final otherUserId = (await ctx.newUser()).id;
      final other = await ctx.newRemoteAsset(ownerId: otherUserId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      for (final checksum in ['checksum-1', 'checksum-3', 'checksum-4']) {
        await ctx.newLocalAsset(checksum: checksum);
      }
      await sut.upsert(
        userId,
        deleted({
          restored.id: 'checksum-1',
          notBack.id: 'checksum-2',
          active.id: 'checksum-3',
          pending.id: 'checksum-4',
        }),
      );
      await sut.upsert(otherUserId, deleted({other.id: 'checksum-1'}));
      await sut.markTrashed([restored.id, notBack.id, active.id, other.id]);

      expect(await sut.getToRestore(userId), [restored.id]);
    });
  });

  group('exclusions', () {
    test('consumeExcluded drops the exclusions of assets that are gone', () async {
      final local = await ctx.newLocalAsset();
      await sut.markExcluded([local.id, 'local-gone']);

      await sut.consumeExcluded();

      expect(await excludedLocalIds(), {local.id});
    });
  });

  group('getAssetsToHash', () {
    test('returns the unhashed files with the name and type of a deleted file', () async {
      final remote = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      await sut.upsert(userId, deleted({remote.id: 'checksum-1'}));
      final copy = await ctx.newLocalAsset(name: remote.name, checksumOption: const Option.none());
      await ctx.newLocalAsset(name: remote.name.replaceFirst('.jpg', ' (1).jpg'), checksumOption: const Option.none());
      await ctx.newLocalAsset(name: remote.name);
      await ctx.newLocalAsset(name: 'other.jpg', checksumOption: const Option.none());
      await ctx.newLocalAsset(name: remote.name, type: AssetType.video, checksumOption: const Option.none());

      expect((await sut.getAssetsToHash()).map((asset) => asset.id), [copy.id]);
    });

    test('includes held and flushed deletions', () async {
      final held = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-1');
      final flushed = await ctx.newRemoteAsset(ownerId: userId, checksum: 'checksum-2');
      await sut.upsert(userId, deleted({held.id: 'checksum-1'}), awaitingConfirmation: true);
      await sut.upsert(userId, deleted({flushed.id: 'checksum-2'}));
      await sut.markTrashed([flushed.id]);
      final heldCopy = await ctx.newLocalAsset(name: held.name, checksumOption: const Option.none());
      final flushedCopy = await ctx.newLocalAsset(name: flushed.name, checksumOption: const Option.none());

      expect((await sut.getAssetsToHash()).map((asset) => asset.id), unorderedEquals([heldCopy.id, flushedCopy.id]));
    });
  });

  group('clearPending', () {
    test('removes the pending deletions but keeps the flushed ones', () async {
      await sut.upsert(userId, deleted({'remote-1': 'checksum-1', 'remote-2': 'checksum-2'}));
      await sut.markTrashed(['remote-2']);

      await sut.clearPending();

      expect(await queuedRemoteIds(), {'remote-2'});
    });
  });
}
