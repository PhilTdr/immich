import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/utils/option.dart';

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

  group('getTrashedBackupsForLocalIds', () {
    test('returns (localId, remoteId) for a candidate whose own remote is trashed', () async {
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

      expect(await sut.getTrashedBackupsForLocalIds(userId, ['local-1']), [(localId: 'local-1', remoteId: 'remote-1')]);
    });

    test('ignores candidates whose remote is not trashed', () async {
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: userId, checksum: 'checksum-1'); // deletedAt null
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

      expect(await sut.getTrashedBackupsForLocalIds(userId, ['local-1']), isEmpty);
    });

    test('ignores a trashed remote owned by another account (partner sharing a checksum)', () async {
      final otherUser = (await ctx.newUser()).id;
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: otherUser, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');

      expect(await sut.getTrashedBackupsForLocalIds(userId, ['local-1']), isEmpty);
    });

    test('only considers the given candidate ids', () async {
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(id: 'local-1', checksum: 'checksum-1');
      await ctx.newLocalAsset(id: 'local-2', checksum: 'checksum-1');

      expect(await sut.getTrashedBackupsForLocalIds(userId, ['local-1']), [(localId: 'local-1', remoteId: 'remote-1')]);
    });

    test('ignores an unhashed candidate (null checksum cannot match)', () async {
      await ctx.newRemoteAsset(id: 'remote-1', ownerId: userId, checksum: 'checksum-1', deletedAt: DateTime(2024));
      await ctx.newLocalAsset(id: 'local-1', checksumOption: const Option.none());

      expect(await sut.getTrashedBackupsForLocalIds(userId, ['local-1']), isEmpty);
    });
  });
}
