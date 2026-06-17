import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late RemoteAssetRepository sut;
  late String userId;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = RemoteAssetRepository(ctx.db);
    userId = (await ctx.newUser()).id;
  });

  tearDown(() async {
    await ctx.dispose();
  });

  group('getLocallyPresentTrashedRemoteIds', () {
    test('returns the account\'s own trashed assets that are still present locally', () async {
      // Device-authoritative: a present local copy means the asset should not be
      // in the trash. This holds regardless of where it was trashed — including
      // assets the user trashed on the web while keeping the local copy. That is
      // intentional and is the behavior this query encodes.
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(checksum: 'checksum-1');

      expect(await sut.getLocallyPresentTrashedRemoteIds(userId), ['remote-1']);
    });

    test('ignores trashed remotes that have no local twin', () async {
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));

      expect(await sut.getLocallyPresentTrashedRemoteIds(userId), isEmpty);
    });

    test('ignores remotes that are not trashed', () async {
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: userId, checksum: 'checksum-1'); // deletedAt null
      await ctx.newLocalAsset(checksum: 'checksum-1');

      expect(await sut.getLocallyPresentTrashedRemoteIds(userId), isEmpty);
    });

    test('ignores trashed remotes owned by another account (partner sharing a checksum)', () async {
      final otherUser = (await ctx.newUser()).id;
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: otherUser, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(checksum: 'checksum-1');

      expect(await sut.getLocallyPresentTrashedRemoteIds(userId), isEmpty);
    });

    test('collapses duplicate-checksum local assets to a single remote id', () async {
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(checksum: 'checksum-1');
      await ctx.newLocalAsset(checksum: 'checksum-1');

      expect(await sut.getLocallyPresentTrashedRemoteIds(userId), ['remote-1']);
    });
  });
}
