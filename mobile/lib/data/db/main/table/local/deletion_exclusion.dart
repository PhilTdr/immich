import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/util/defaults_mixin.dart';

// Assets the app deleted itself, their server copy stays
class LocalDeletionExclusionEntity extends Table with DriftDefaultsMixin {
  const LocalDeletionExclusionEntity();

  TextColumn get localId => text()();

  @override
  Set<Column> get primaryKey => {localId};
}
