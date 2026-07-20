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
      required DateTime createdAt,
    });
typedef $$LocalDeletionEntityTableUpdateCompanionBuilder =
    i1.LocalDeletionEntityCompanion Function({
      i0.Value<String> remoteId,
      i0.Value<String> checksum,
      i0.Value<String> ownerId,
      i0.Value<DateTime> createdAt,
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

  i0.ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
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

  i0.ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
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

  i0.GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
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
                i0.Value<DateTime> createdAt = const i0.Value.absent(),
              }) => i1.LocalDeletionEntityCompanion(
                remoteId: remoteId,
                checksum: checksum,
                ownerId: ownerId,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                required String remoteId,
                required String checksum,
                required String ownerId,
                required DateTime createdAt,
              }) => i1.LocalDeletionEntityCompanion.insert(
                remoteId: remoteId,
                checksum: checksum,
                ownerId: ownerId,
                createdAt: createdAt,
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
typedef $$LocalDeletionExclusionEntityTableCreateCompanionBuilder =
    i1.LocalDeletionExclusionEntityCompanion Function({
      required String localId,
    });
typedef $$LocalDeletionExclusionEntityTableUpdateCompanionBuilder =
    i1.LocalDeletionExclusionEntityCompanion Function({
      i0.Value<String> localId,
    });

class $$LocalDeletionExclusionEntityTableFilterComposer
    extends
        i0.Composer<
          i0.GeneratedDatabase,
          i1.$LocalDeletionExclusionEntityTable
        > {
  $$LocalDeletionExclusionEntityTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.ColumnFilters<String> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => i0.ColumnFilters(column),
  );
}

class $$LocalDeletionExclusionEntityTableOrderingComposer
    extends
        i0.Composer<
          i0.GeneratedDatabase,
          i1.$LocalDeletionExclusionEntityTable
        > {
  $$LocalDeletionExclusionEntityTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.ColumnOrderings<String> get localId => $composableBuilder(
    column: $table.localId,
    builder: (column) => i0.ColumnOrderings(column),
  );
}

class $$LocalDeletionExclusionEntityTableAnnotationComposer
    extends
        i0.Composer<
          i0.GeneratedDatabase,
          i1.$LocalDeletionExclusionEntityTable
        > {
  $$LocalDeletionExclusionEntityTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.GeneratedColumn<String> get localId =>
      $composableBuilder(column: $table.localId, builder: (column) => column);
}

class $$LocalDeletionExclusionEntityTableTableManager
    extends
        i0.RootTableManager<
          i0.GeneratedDatabase,
          i1.$LocalDeletionExclusionEntityTable,
          i1.LocalDeletionExclusionEntityData,
          i1.$$LocalDeletionExclusionEntityTableFilterComposer,
          i1.$$LocalDeletionExclusionEntityTableOrderingComposer,
          i1.$$LocalDeletionExclusionEntityTableAnnotationComposer,
          $$LocalDeletionExclusionEntityTableCreateCompanionBuilder,
          $$LocalDeletionExclusionEntityTableUpdateCompanionBuilder,
          (
            i1.LocalDeletionExclusionEntityData,
            i0.BaseReferences<
              i0.GeneratedDatabase,
              i1.$LocalDeletionExclusionEntityTable,
              i1.LocalDeletionExclusionEntityData
            >,
          ),
          i1.LocalDeletionExclusionEntityData,
          i0.PrefetchHooks Function()
        > {
  $$LocalDeletionExclusionEntityTableTableManager(
    i0.GeneratedDatabase db,
    i1.$LocalDeletionExclusionEntityTable table,
  ) : super(
        i0.TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              i1.$$LocalDeletionExclusionEntityTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              i1.$$LocalDeletionExclusionEntityTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              i1.$$LocalDeletionExclusionEntityTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({i0.Value<String> localId = const i0.Value.absent()}) =>
                  i1.LocalDeletionExclusionEntityCompanion(localId: localId),
          createCompanionCallback: ({required String localId}) =>
              i1.LocalDeletionExclusionEntityCompanion.insert(localId: localId),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), i0.BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalDeletionExclusionEntityTableProcessedTableManager =
    i0.ProcessedTableManager<
      i0.GeneratedDatabase,
      i1.$LocalDeletionExclusionEntityTable,
      i1.LocalDeletionExclusionEntityData,
      i1.$$LocalDeletionExclusionEntityTableFilterComposer,
      i1.$$LocalDeletionExclusionEntityTableOrderingComposer,
      i1.$$LocalDeletionExclusionEntityTableAnnotationComposer,
      $$LocalDeletionExclusionEntityTableCreateCompanionBuilder,
      $$LocalDeletionExclusionEntityTableUpdateCompanionBuilder,
      (
        i1.LocalDeletionExclusionEntityData,
        i0.BaseReferences<
          i0.GeneratedDatabase,
          i1.$LocalDeletionExclusionEntityTable,
          i1.LocalDeletionExclusionEntityData
        >,
      ),
      i1.LocalDeletionExclusionEntityData,
      i0.PrefetchHooks Function()
    >;

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
  static const i0.VerificationMeta _createdAtMeta = const i0.VerificationMeta(
    'createdAt',
  );
  @override
  late final i0.GeneratedColumn<DateTime> createdAt =
      i0.GeneratedColumn<DateTime>(
        'created_at',
        aliasedName,
        false,
        type: i0.DriftSqlType.dateTime,
        requiredDuringInsert: true,
      );
  @override
  List<i0.GeneratedColumn> get $columns => [
    remoteId,
    checksum,
    ownerId,
    createdAt,
  ];
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
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
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
      createdAt: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
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
  final String remoteId;
  final String checksum;
  final String ownerId;
  final DateTime createdAt;
  const LocalDeletionEntityData({
    required this.remoteId,
    required this.checksum,
    required this.ownerId,
    required this.createdAt,
  });
  @override
  Map<String, i0.Expression> toColumns(bool nullToAbsent) {
    final map = <String, i0.Expression>{};
    map['remote_id'] = i0.Variable<String>(remoteId);
    map['checksum'] = i0.Variable<String>(checksum);
    map['owner_id'] = i0.Variable<String>(ownerId);
    map['created_at'] = i0.Variable<DateTime>(createdAt);
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
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({i0.ValueSerializer? serializer}) {
    serializer ??= i0.driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'remoteId': serializer.toJson<String>(remoteId),
      'checksum': serializer.toJson<String>(checksum),
      'ownerId': serializer.toJson<String>(ownerId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  i1.LocalDeletionEntityData copyWith({
    String? remoteId,
    String? checksum,
    String? ownerId,
    DateTime? createdAt,
  }) => i1.LocalDeletionEntityData(
    remoteId: remoteId ?? this.remoteId,
    checksum: checksum ?? this.checksum,
    ownerId: ownerId ?? this.ownerId,
    createdAt: createdAt ?? this.createdAt,
  );
  LocalDeletionEntityData copyWithCompanion(
    i1.LocalDeletionEntityCompanion data,
  ) {
    return LocalDeletionEntityData(
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      checksum: data.checksum.present ? data.checksum.value : this.checksum,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionEntityData(')
          ..write('remoteId: $remoteId, ')
          ..write('checksum: $checksum, ')
          ..write('ownerId: $ownerId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(remoteId, checksum, ownerId, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is i1.LocalDeletionEntityData &&
          other.remoteId == this.remoteId &&
          other.checksum == this.checksum &&
          other.ownerId == this.ownerId &&
          other.createdAt == this.createdAt);
}

class LocalDeletionEntityCompanion
    extends i0.UpdateCompanion<i1.LocalDeletionEntityData> {
  final i0.Value<String> remoteId;
  final i0.Value<String> checksum;
  final i0.Value<String> ownerId;
  final i0.Value<DateTime> createdAt;
  const LocalDeletionEntityCompanion({
    this.remoteId = const i0.Value.absent(),
    this.checksum = const i0.Value.absent(),
    this.ownerId = const i0.Value.absent(),
    this.createdAt = const i0.Value.absent(),
  });
  LocalDeletionEntityCompanion.insert({
    required String remoteId,
    required String checksum,
    required String ownerId,
    required DateTime createdAt,
  }) : remoteId = i0.Value(remoteId),
       checksum = i0.Value(checksum),
       ownerId = i0.Value(ownerId),
       createdAt = i0.Value(createdAt);
  static i0.Insertable<i1.LocalDeletionEntityData> custom({
    i0.Expression<String>? remoteId,
    i0.Expression<String>? checksum,
    i0.Expression<String>? ownerId,
    i0.Expression<DateTime>? createdAt,
  }) {
    return i0.RawValuesInsertable({
      if (remoteId != null) 'remote_id': remoteId,
      if (checksum != null) 'checksum': checksum,
      if (ownerId != null) 'owner_id': ownerId,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  i1.LocalDeletionEntityCompanion copyWith({
    i0.Value<String>? remoteId,
    i0.Value<String>? checksum,
    i0.Value<String>? ownerId,
    i0.Value<DateTime>? createdAt,
  }) {
    return i1.LocalDeletionEntityCompanion(
      remoteId: remoteId ?? this.remoteId,
      checksum: checksum ?? this.checksum,
      ownerId: ownerId ?? this.ownerId,
      createdAt: createdAt ?? this.createdAt,
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
    if (createdAt.present) {
      map['created_at'] = i0.Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionEntityCompanion(')
          ..write('remoteId: $remoteId, ')
          ..write('checksum: $checksum, ')
          ..write('ownerId: $ownerId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $LocalDeletionExclusionEntityTable extends i2.LocalDeletionExclusionEntity
    with
        i0.TableInfo<
          $LocalDeletionExclusionEntityTable,
          i1.LocalDeletionExclusionEntityData
        > {
  @override
  final i0.GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalDeletionExclusionEntityTable(this.attachedDatabase, [this._alias]);
  static const i0.VerificationMeta _localIdMeta = const i0.VerificationMeta(
    'localId',
  );
  @override
  late final i0.GeneratedColumn<String> localId = i0.GeneratedColumn<String>(
    'local_id',
    aliasedName,
    false,
    type: i0.DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<i0.GeneratedColumn> get $columns => [localId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_deletion_exclusion_entity';
  @override
  i0.VerificationContext validateIntegrity(
    i0.Insertable<i1.LocalDeletionExclusionEntityData> instance, {
    bool isInserting = false,
  }) {
    final context = i0.VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_id')) {
      context.handle(
        _localIdMeta,
        localId.isAcceptableOrUnknown(data['local_id']!, _localIdMeta),
      );
    } else if (isInserting) {
      context.missing(_localIdMeta);
    }
    return context;
  }

  @override
  Set<i0.GeneratedColumn> get $primaryKey => {localId};
  @override
  i1.LocalDeletionExclusionEntityData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return i1.LocalDeletionExclusionEntityData(
      localId: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}local_id'],
      )!,
    );
  }

  @override
  $LocalDeletionExclusionEntityTable createAlias(String alias) {
    return $LocalDeletionExclusionEntityTable(attachedDatabase, alias);
  }

  @override
  bool get withoutRowId => true;
  @override
  bool get isStrict => true;
}

class LocalDeletionExclusionEntityData extends i0.DataClass
    implements i0.Insertable<i1.LocalDeletionExclusionEntityData> {
  final String localId;
  const LocalDeletionExclusionEntityData({required this.localId});
  @override
  Map<String, i0.Expression> toColumns(bool nullToAbsent) {
    final map = <String, i0.Expression>{};
    map['local_id'] = i0.Variable<String>(localId);
    return map;
  }

  factory LocalDeletionExclusionEntityData.fromJson(
    Map<String, dynamic> json, {
    i0.ValueSerializer? serializer,
  }) {
    serializer ??= i0.driftRuntimeOptions.defaultSerializer;
    return LocalDeletionExclusionEntityData(
      localId: serializer.fromJson<String>(json['localId']),
    );
  }
  @override
  Map<String, dynamic> toJson({i0.ValueSerializer? serializer}) {
    serializer ??= i0.driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{'localId': serializer.toJson<String>(localId)};
  }

  i1.LocalDeletionExclusionEntityData copyWith({String? localId}) =>
      i1.LocalDeletionExclusionEntityData(localId: localId ?? this.localId);
  LocalDeletionExclusionEntityData copyWithCompanion(
    i1.LocalDeletionExclusionEntityCompanion data,
  ) {
    return LocalDeletionExclusionEntityData(
      localId: data.localId.present ? data.localId.value : this.localId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionExclusionEntityData(')
          ..write('localId: $localId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => localId.hashCode;
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is i1.LocalDeletionExclusionEntityData &&
          other.localId == this.localId);
}

class LocalDeletionExclusionEntityCompanion
    extends i0.UpdateCompanion<i1.LocalDeletionExclusionEntityData> {
  final i0.Value<String> localId;
  const LocalDeletionExclusionEntityCompanion({
    this.localId = const i0.Value.absent(),
  });
  LocalDeletionExclusionEntityCompanion.insert({required String localId})
    : localId = i0.Value(localId);
  static i0.Insertable<i1.LocalDeletionExclusionEntityData> custom({
    i0.Expression<String>? localId,
  }) {
    return i0.RawValuesInsertable({if (localId != null) 'local_id': localId});
  }

  i1.LocalDeletionExclusionEntityCompanion copyWith({
    i0.Value<String>? localId,
  }) {
    return i1.LocalDeletionExclusionEntityCompanion(
      localId: localId ?? this.localId,
    );
  }

  @override
  Map<String, i0.Expression> toColumns(bool nullToAbsent) {
    final map = <String, i0.Expression>{};
    if (localId.present) {
      map['local_id'] = i0.Variable<String>(localId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalDeletionExclusionEntityCompanion(')
          ..write('localId: $localId')
          ..write(')'))
        .toString();
  }
}
