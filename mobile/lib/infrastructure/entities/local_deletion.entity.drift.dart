// dart format width=80
// ignore_for_file: type=lint
import 'package:drift/drift.dart' as i0;
import 'package:immich_mobile/infrastructure/entities/local_deletion.entity.drift.dart'
    as i1;
import 'package:immich_mobile/infrastructure/entities/local_deletion.entity.dart'
    as i2;

typedef $$LocalDeletionEntityTableCreateCompanionBuilder =
    i1.LocalDeletionEntityCompanion Function({
      required String remoteId,
      required String checksum,
      required String ownerId,
    });
typedef $$LocalDeletionEntityTableUpdateCompanionBuilder =
    i1.LocalDeletionEntityCompanion Function({
      i0.Value<String> remoteId,
      i0.Value<String> checksum,
      i0.Value<String> ownerId,
    });

class $$LocalDeletionEntityTableFilterComposer
    extends i0.Composer<i0.GeneratedDatabase, i1.$LocalDeletionEntityTable> {
  $$LocalDeletionEntityTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<String> get checksum => $composableBuilder(
    column: $table.checksum,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => i0.ColumnFilters(column),
  );
}

class $$LocalDeletionEntityTableOrderingComposer
    extends i0.Composer<i0.GeneratedDatabase, i1.$LocalDeletionEntityTable> {
  $$LocalDeletionEntityTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<String> get checksum => $composableBuilder(
    column: $table.checksum,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => i0.ColumnOrderings(column),
  );
}

class $$LocalDeletionEntityTableAnnotationComposer
    extends i0.Composer<i0.GeneratedDatabase, i1.$LocalDeletionEntityTable> {
  $$LocalDeletionEntityTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  i0.GeneratedColumn<String> get checksum =>
      $composableBuilder(column: $table.checksum, builder: (column) => column);

  i0.GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);
}

class $$LocalDeletionEntityTableTableManager
    extends
        i0.RootTableManager<
          i0.GeneratedDatabase,
          i1.$LocalDeletionEntityTable,
          i1.LocalDeletionEntityData,
          i1.$$LocalDeletionEntityTableFilterComposer,
          i1.$$LocalDeletionEntityTableOrderingComposer,
          i1.$$LocalDeletionEntityTableAnnotationComposer,
          $$LocalDeletionEntityTableCreateCompanionBuilder,
          $$LocalDeletionEntityTableUpdateCompanionBuilder,
          (
            i1.LocalDeletionEntityData,
            i0.BaseReferences<
              i0.GeneratedDatabase,
              i1.$LocalDeletionEntityTable,
              i1.LocalDeletionEntityData
            >,
          ),
          i1.LocalDeletionEntityData,
          i0.PrefetchHooks Function()
        > {
  $$LocalDeletionEntityTableTableManager(
    i0.GeneratedDatabase db,
    i1.$LocalDeletionEntityTable table,
  ) : super(
        i0.TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => i1
              .$$LocalDeletionEntityTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              i1.$$LocalDeletionEntityTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              i1.$$LocalDeletionEntityTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                i0.Value<String> remoteId = const i0.Value.absent(),
                i0.Value<String> checksum = const i0.Value.absent(),
                i0.Value<String> ownerId = const i0.Value.absent(),
              }) => i1.LocalDeletionEntityCompanion(
                remoteId: remoteId,
                checksum: checksum,
                ownerId: ownerId,
              ),
          createCompanionCallback:
              ({
                required String remoteId,
                required String checksum,
                required String ownerId,
              }) => i1.LocalDeletionEntityCompanion.insert(
                remoteId: remoteId,
                checksum: checksum,
                ownerId: ownerId,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), i0.BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalDeletionEntityTableProcessedTableManager =
    i0.ProcessedTableManager<
      i0.GeneratedDatabase,
      i1.$LocalDeletionEntityTable,
      i1.LocalDeletionEntityData,
      i1.$$LocalDeletionEntityTableFilterComposer,
      i1.$$LocalDeletionEntityTableOrderingComposer,
      i1.$$LocalDeletionEntityTableAnnotationComposer,
      $$LocalDeletionEntityTableCreateCompanionBuilder,
      $$LocalDeletionEntityTableUpdateCompanionBuilder,
      (
        i1.LocalDeletionEntityData,
        i0.BaseReferences<
          i0.GeneratedDatabase,
          i1.$LocalDeletionEntityTable,
          i1.LocalDeletionEntityData
        >,
      ),
      i1.LocalDeletionEntityData,
      i0.PrefetchHooks Function()
    >;
i0.Index get idxLocalDeletionChecksum => i0.Index(
  'idx_local_deletion_checksum',
  'CREATE INDEX IF NOT EXISTS idx_local_deletion_checksum ON local_deletion_entity (checksum)',
);

class $LocalDeletionEntityTable extends i2.LocalDeletionEntity
    with i0.TableInfo<$LocalDeletionEntityTable, i1.LocalDeletionEntityData> {
  @override
  final i0.GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalDeletionEntityTable(this.attachedDatabase, [this._alias]);
  static const i0.VerificationMeta _remoteIdMeta = const i0.VerificationMeta(
    'remoteId',
  );
  @override
  late final i0.GeneratedColumn<String> remoteId = i0.GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    false,
    type: i0.DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const i0.VerificationMeta _checksumMeta = const i0.VerificationMeta(
    'checksum',
  );
  @override
  late final i0.GeneratedColumn<String> checksum = i0.GeneratedColumn<String>(
    'checksum',
    aliasedName,
    false,
    type: i0.DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const i0.VerificationMeta _ownerIdMeta = const i0.VerificationMeta(
    'ownerId',
  );
  @override
  late final i0.GeneratedColumn<String> ownerId = i0.GeneratedColumn<String>(
    'owner_id',
    aliasedName,
    false,
    type: i0.DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<i0.GeneratedColumn> get $columns => [remoteId, checksum, ownerId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_deletion_entity';
  @override
  i0.VerificationContext validateIntegrity(
    i0.Insertable<i1.LocalDeletionEntityData> instance, {
    bool isInserting = false,
  }) {
    final context = i0.VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    } else if (isInserting) {
      context.missing(_remoteIdMeta);
    }
    if (data.containsKey('checksum')) {
      context.handle(
        _checksumMeta,
        checksum.isAcceptableOrUnknown(data['checksum']!, _checksumMeta),
      );
    } else if (isInserting) {
      context.missing(_checksumMeta);
    }
    if (data.containsKey('owner_id')) {
      context.handle(
        _ownerIdMeta,
        ownerId.isAcceptableOrUnknown(data['owner_id']!, _ownerIdMeta),
      );
    } else if (isInserting) {
      context.missing(_ownerIdMeta);
    }
    return context;
  }

  @override
  Set<i0.GeneratedColumn> get $primaryKey => {remoteId};
  @override
  i1.LocalDeletionEntityData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return i1.LocalDeletionEntityData(
      remoteId: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      )!,
      checksum: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}checksum'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      )!,
    );
  }

  @override
  $LocalDeletionEntityTable createAlias(String alias) {
    return $LocalDeletionEntityTable(attachedDatabase, alias);
  }

  @override
  bool get withoutRowId => true;
  @override
  bool get isStrict => true;
}

class LocalDeletionEntityData extends i0.DataClass
    implements i0.Insertable<i1.LocalDeletionEntityData> {
  /// Remote asset id that is pending to be trashed on the server.
  final String remoteId;

  /// Checksum of the deleted local asset. Used to cancel the pending deletion if
  /// the same content is still present locally (a duplicate row, or an undo
  /// before the deletion was flushed).
  final String checksum;

  /// Owner (user id) of the remote asset. Scopes the queue per account so a
  /// logout / token-expiry reset neither strands the current user's pending
  /// deletions nor leaks them into the next account.
  ///
  /// Intentionally NOT a foreign key to `user_entity`: that row is wiped by the
  /// sync reset on logout, and an `ON DELETE CASCADE` would delete pending rows
  /// and defeat the durability this column exists to provide.
  final String ownerId;
  const LocalDeletionEntityData({
    required this.remoteId,
    required this.checksum,
    required this.ownerId,
  });
  @override
  Map<String, i0.Expression> toColumns(bool nullToAbsent) {
    final map = <String, i0.Expression>{};
    map['remote_id'] = i0.Variable<String>(remoteId);
    map['checksum'] = i0.Variable<String>(checksum);
    map['owner_id'] = i0.Variable<String>(ownerId);
    return map;
  }

  factory LocalDeletionEntityData.fromJson(
    Map<String, dynamic> json, {
    i0.ValueSerializer? serializer,
  }) {
    serializer ??= i0.driftRuntimeOptions.defaultSerializer;
    return LocalDeletionEntityData(
      remoteId: serializer.fromJson<String>(json['remoteId']),
      checksum: serializer.fromJson<String>(json['checksum']),
      ownerId: serializer.fromJson<String>(json['ownerId']),
    );
  }
  @override
  Map<String, dynamic> toJson({i0.ValueSerializer? serializer}) {
    serializer ??= i0.driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'remoteId': serializer.toJson<String>(remoteId),
      'checksum': serializer.toJson<String>(checksum),
      'ownerId': serializer.toJson<String>(ownerId),
    };
  }

  i1.LocalDeletionEntityData copyWith({
    String? remoteId,
    String? checksum,
    String? ownerId,
  }) => i1.LocalDeletionEntityData(
    remoteId: remoteId ?? this.remoteId,
    checksum: checksum ?? this.checksum,
    ownerId: ownerId ?? this.ownerId,
  );
  LocalDeletionEntityData copyWithCompanion(
    i1.LocalDeletionEntityCompanion data,
  ) {
    return LocalDeletionEntityData(
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      checksum: data.checksum.present ? data.checksum.value : this.checksum,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionEntityData(')
          ..write('remoteId: $remoteId, ')
          ..write('checksum: $checksum, ')
          ..write('ownerId: $ownerId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(remoteId, checksum, ownerId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is i1.LocalDeletionEntityData &&
          other.remoteId == this.remoteId &&
          other.checksum == this.checksum &&
          other.ownerId == this.ownerId);
}

class LocalDeletionEntityCompanion
    extends i0.UpdateCompanion<i1.LocalDeletionEntityData> {
  final i0.Value<String> remoteId;
  final i0.Value<String> checksum;
  final i0.Value<String> ownerId;
  const LocalDeletionEntityCompanion({
    this.remoteId = const i0.Value.absent(),
    this.checksum = const i0.Value.absent(),
    this.ownerId = const i0.Value.absent(),
  });
  LocalDeletionEntityCompanion.insert({
    required String remoteId,
    required String checksum,
    required String ownerId,
  }) : remoteId = i0.Value(remoteId),
       checksum = i0.Value(checksum),
       ownerId = i0.Value(ownerId);
  static i0.Insertable<i1.LocalDeletionEntityData> custom({
    i0.Expression<String>? remoteId,
    i0.Expression<String>? checksum,
    i0.Expression<String>? ownerId,
  }) {
    return i0.RawValuesInsertable({
      if (remoteId != null) 'remote_id': remoteId,
      if (checksum != null) 'checksum': checksum,
      if (ownerId != null) 'owner_id': ownerId,
    });
  }

  i1.LocalDeletionEntityCompanion copyWith({
    i0.Value<String>? remoteId,
    i0.Value<String>? checksum,
    i0.Value<String>? ownerId,
  }) {
    return i1.LocalDeletionEntityCompanion(
      remoteId: remoteId ?? this.remoteId,
      checksum: checksum ?? this.checksum,
      ownerId: ownerId ?? this.ownerId,
    );
  }

  @override
  Map<String, i0.Expression> toColumns(bool nullToAbsent) {
    final map = <String, i0.Expression>{};
    if (remoteId.present) {
      map['remote_id'] = i0.Variable<String>(remoteId.value);
    }
    if (checksum.present) {
      map['checksum'] = i0.Variable<String>(checksum.value);
    }
    if (ownerId.present) {
      map['owner_id'] = i0.Variable<String>(ownerId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionEntityCompanion(')
          ..write('remoteId: $remoteId, ')
          ..write('checksum: $checksum, ')
          ..write('ownerId: $ownerId')
          ..write(')'))
        .toString();
  }
}
