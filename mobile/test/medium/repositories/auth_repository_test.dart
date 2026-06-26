import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/repositories/auth.repository.dart';

import '../../infrastructure/repository.mock.dart';
import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late AuthRepository sut;

  setUp(() {
    ctx = MediumRepositoryContext();
    // clearLocalData() does not touch settings, so a bare mock is sufficient.
    sut = AuthRepository(ctx.db, MockSettingsRepository());
  });

  tearDown(() async {
    await ctx.dispose();
  });

  group('clearLocalData', () {
    test('keeps the local→server deletion queue so pending deletions survive a reset', () async {
      // The queue is a durable, per-account retry queue: a logout / token-expiry
      // reset must not strand the current user's not-yet-synced deletions. Foreign
      // accounts are handled by owner-scoping, not by wiping here.
      final deletions = DriftLocalDeletionRepository(ctx.db);
      await deletions.upsert('user-1', {'remote-1': 'checksum-1', 'remote-2': 'checksum-2'});

      await sut.clearLocalData();

      final rows = await ctx.db.select(ctx.db.localDeletionEntity).get();
      expect(rows.map((r) => r.remoteId).toSet(), {'remote-1', 'remote-2'});
    });
  });
}
