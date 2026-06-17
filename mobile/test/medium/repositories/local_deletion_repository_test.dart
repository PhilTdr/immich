import 'package:flutter_test/flutter_test.dart';
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

  group('upsert', () {
    test('inserts and updates queue rows keyed by remote id', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      expect(await queuedRemoteIds(), {'remote-1'});

      await sut.upsert(userId, {'remote-1': 'checksum-1-updated', 'remote-2': 'checksum-2'});
      expect(await queuedRemoteIds(), {'remote-1', 'remote-2'});
    });
  });

  group('getPending', () {
    test("returns the current account's queued rows", () async {
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

  group('deleteForeignRows', () {
    test('removes only rows owned by other accounts', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1'});
      await sut.upsert('other-user', {'remote-2': 'checksum-2', 'remote-3': 'checksum-3'});

      await sut.deleteForeignRows(userId);

      expect(await queuedRemoteIds(), {'remote-1'});
    });
  });

  group('deleteAll', () {
    test('removes every queue row', () async {
      await sut.upsert(userId, {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'});

      await sut.deleteAll();

      expect(await queuedRemoteIds(), isEmpty);
    });
  });
}
