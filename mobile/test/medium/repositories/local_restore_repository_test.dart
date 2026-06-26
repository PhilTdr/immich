import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/local_restore.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late DriftLocalRestoreRepository sut;
  late String userId;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = DriftLocalRestoreRepository(ctx.db);
    userId = (await ctx.newUser()).id;
  });

  tearDown(() async {
    await ctx.dispose();
  });

  Future<Set<String>> watchedAssetIds() async {
    final rows = await ctx.db.select(ctx.db.localRestoreEntity).get();
    return rows.map((r) => r.assetId).toSet();
  }

  group('enqueue', () {
    test('inserts watch rows keyed by asset id and is idempotent', () async {
      await sut.enqueue(userId, ['local-1']);
      expect(await watchedAssetIds(), {'local-1'});

      await sut.enqueue(userId, ['local-1', 'local-2']);
      expect(await watchedAssetIds(), {'local-1', 'local-2'});
    });

    test('does nothing for an empty set', () async {
      await sut.enqueue(userId, const []);
      expect(await watchedAssetIds(), isEmpty);
    });
  });

  group('getPending', () {
    test("returns the current account's watched asset ids", () async {
      await sut.enqueue(userId, ['local-1', 'local-2']);

      expect((await sut.getPending(userId)).toSet(), {'local-1', 'local-2'});
    });

    test('excludes rows owned by another account', () async {
      await sut.enqueue(userId, ['local-1']);
      await sut.enqueue('other-user', ['local-2']);

      expect(await sut.getPending(userId), ['local-1']);
    });
  });

  group('deleteByAssetIds', () {
    test('removes the given watch rows', () async {
      await sut.enqueue(userId, ['local-1', 'local-2']);

      await sut.deleteByAssetIds(['local-1']);

      expect(await watchedAssetIds(), {'local-2'});
    });
  });

  group('deleteForeignRows', () {
    test('removes only rows owned by other accounts', () async {
      await sut.enqueue(userId, ['local-1']);
      await sut.enqueue('other-user', ['local-2', 'local-3']);

      await sut.deleteForeignRows(userId);

      expect(await watchedAssetIds(), {'local-1'});
    });
  });

  group('deleteAll', () {
    test('removes every watch row', () async {
      await sut.enqueue(userId, ['local-1', 'local-2']);

      await sut.deleteAll();

      expect(await watchedAssetIds(), isEmpty);
    });
  });
}
