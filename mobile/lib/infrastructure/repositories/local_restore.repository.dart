import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/infrastructure/entities/local_restore.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

/// Durable, per-account watch list of local assets that (re)appeared on this
/// device (see [LocalRestoreEntity]). Each row waits for its asset to be hashed;
/// the restore sweep then checks whether the asset's own remote twin is trashed
/// on the server and, if so, restores it. Rows are removed once resolved.
class DriftLocalRestoreRepository extends DriftDatabaseRepository {
  final Drift _db;

  const DriftLocalRestoreRepository(this._db) : super(_db);

  /// Adds [assetIds] (local asset ids) as restore candidates owned by [ownerId].
  /// Idempotent: re-adding an existing asset id just refreshes its owner.
  Future<void> enqueue(String ownerId, Iterable<String> assetIds) async {
    final ids = assetIds.toSet();
    if (ids.isEmpty) {
      return;
    }

    await _db.batch((batch) {
      for (final id in ids) {
        final companion = LocalRestoreEntityCompanion.insert(assetId: id, ownerId: ownerId);
        batch.insert(_db.localRestoreEntity, companion, onConflict: DoUpdate((_) => companion));
      }
    });
  }

  /// Local asset ids currently watched for restore, owned by [ownerId].
  Future<List<String>> getPending(String ownerId) {
    final query = _db.localRestoreEntity.select()..where((row) => row.ownerId.equals(ownerId));
    return query.map((row) => row.assetId).get();
  }

  Future<void> deleteByAssetIds(Iterable<String> assetIds) async {
    final ids = assetIds.toSet();
    if (ids.isEmpty) {
      return;
    }

    for (final slice in ids.slices(kDriftMaxChunk)) {
      await (_db.delete(_db.localRestoreEntity)..where((row) => row.assetId.isIn(slice))).go();
    }
  }

  /// Removes watch rows belonging to any account other than [ownerId]. Called at
  /// the start of an owner-scoped sync so a previous account's candidates cannot
  /// linger on the device or act on the current session.
  Future<void> deleteForeignRows(String ownerId) {
    return (_db.delete(_db.localRestoreEntity)..where((row) => row.ownerId.equals(ownerId).not())).go();
  }

  /// Clears all watch rows (hard wipe).
  Future<void> deleteAll() => _db.delete(_db.localRestoreEntity).go();
}
