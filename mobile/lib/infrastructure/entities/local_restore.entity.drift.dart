// dart format width=80
// ignore_for_file: type=lint
import 'package:drift/drift.dart' as i0;
import 'package:immich_mobile/infrastructure/entities/local_restore.entity.drift.dart'
    as i1;
import 'package:immich_mobile/infrastructure/entities/local_restore.entity.dart'
    as i2;

typedef $$LocalRestoreEntityTableCreateCompanionBuilder =
    i1.LocalRestoreEntityCompanion Function({
      required String assetId,
      required String ownerId,
    });
typedef $$LocalRestoreEntityTableUpdateCompanionBuilder =
    i1.LocalRestoreEntityCompanion Function({
      i0.Value<String> assetId,
      i0.Value<String> ownerId,
    });

class $$LocalRestoreEntityTableFilterComposer
    extends i0.Composer<i0.GeneratedDatabase, i1.$LocalRestoreEntityTable> {
  $$LocalRestoreEntityTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.ColumnFilters<String> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => i0.ColumnFilters(column),
  );

  i0.ColumnFilters<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => i0.ColumnFilters(column),
  );
}

class $$LocalRestoreEntityTableOrderingComposer
    extends i0.Composer<i0.GeneratedDatabase, i1.$LocalRestoreEntityTable> {
  $$LocalRestoreEntityTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.ColumnOrderings<String> get assetId => $composableBuilder(
    column: $table.assetId,
    builder: (column) => i0.ColumnOrderings(column),
  );

  i0.ColumnOrderings<String> get ownerId => $composableBuilder(
    column: $table.ownerId,
    builder: (column) => i0.ColumnOrderings(column),
  );
}

class $$LocalRestoreEntityTableAnnotationComposer
    extends i0.Composer<i0.GeneratedDatabase, i1.$LocalRestoreEntityTable> {
  $$LocalRestoreEntityTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  i0.GeneratedColumn<String> get assetId =>
      $composableBuilder(column: $table.assetId, builder: (column) => column);

  i0.GeneratedColumn<String> get ownerId =>
      $composableBuilder(column: $table.ownerId, builder: (column) => column);
}

class $$LocalRestoreEntityTableTableManager
    extends
        i0.RootTableManager<
          i0.GeneratedDatabase,
          i1.$LocalRestoreEntityTable,
          i1.LocalRestoreEntityData,
          i1.$$LocalRestoreEntityTableFilterComposer,
          i1.$$LocalRestoreEntityTableOrderingComposer,
          i1.$$LocalRestoreEntityTableAnnotationComposer,
          $$LocalRestoreEntityTableCreateCompanionBuilder,
          $$LocalRestoreEntityTableUpdateCompanionBuilder,
          (
            i1.LocalRestoreEntityData,
            i0.BaseReferences<
              i0.GeneratedDatabase,
              i1.$LocalRestoreEntityTable,
              i1.LocalRestoreEntityData
            >,
          ),
          i1.LocalRestoreEntityData,
          i0.PrefetchHooks Function()
        > {
  $$LocalRestoreEntityTableTableManager(
    i0.GeneratedDatabase db,
    i1.$LocalRestoreEntityTable table,
  ) : super(
        i0.TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => i1
              .$$LocalRestoreEntityTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              i1.$$LocalRestoreEntityTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              i1.$$LocalRestoreEntityTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                i0.Value<String> assetId = const i0.Value.absent(),
                i0.Value<String> ownerId = const i0.Value.absent(),
              }) => i1.LocalRestoreEntityCompanion(
                assetId: assetId,
                ownerId: ownerId,
              ),
          createCompanionCallback:
              ({required String assetId, required String ownerId}) =>
                  i1.LocalRestoreEntityCompanion.insert(
                    assetId: assetId,
                    ownerId: ownerId,
                  ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), i0.BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalRestoreEntityTableProcessedTableManager =
    i0.ProcessedTableManager<
      i0.GeneratedDatabase,
      i1.$LocalRestoreEntityTable,
      i1.LocalRestoreEntityData,
      i1.$$LocalRestoreEntityTableFilterComposer,
      i1.$$LocalRestoreEntityTableOrderingComposer,
      i1.$$LocalRestoreEntityTableAnnotationComposer,
      $$LocalRestoreEntityTableCreateCompanionBuilder,
      $$LocalRestoreEntityTableUpdateCompanionBuilder,
      (
        i1.LocalRestoreEntityData,
        i0.BaseReferences<
          i0.GeneratedDatabase,
          i1.$LocalRestoreEntityTable,
          i1.LocalRestoreEntityData
        >,
      ),
      i1.LocalRestoreEntityData,
      i0.PrefetchHooks Function()
    >;

class $LocalRestoreEntityTable extends i2.LocalRestoreEntity
    with i0.TableInfo<$LocalRestoreEntityTable, i1.LocalRestoreEntityData> {
  @override
  final i0.GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalRestoreEntityTable(this.attachedDatabase, [this._alias]);
  static const i0.VerificationMeta _assetIdMeta = const i0.VerificationMeta(
    'assetId',
  );
  @override
  late final i0.GeneratedColumn<String> assetId = i0.GeneratedColumn<String>(
    'asset_id',
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
  List<i0.GeneratedColumn> get $columns => [assetId, ownerId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_restore_entity';
  @override
  i0.VerificationContext validateIntegrity(
    i0.Insertable<i1.LocalRestoreEntityData> instance, {
    bool isInserting = false,
  }) {
    final context = i0.VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('asset_id')) {
      context.handle(
        _assetIdMeta,
        assetId.isAcceptableOrUnknown(data['asset_id']!, _assetIdMeta),
      );
    } else if (isInserting) {
      context.missing(_assetIdMeta);
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
  Set<i0.GeneratedColumn> get $primaryKey => {assetId};
  @override
  i1.LocalRestoreEntityData map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return i1.LocalRestoreEntityData(
      assetId: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}asset_id'],
      )!,
      ownerId: attachedDatabase.typeMapping.read(
        i0.DriftSqlType.string,
        data['${effectivePrefix}owner_id'],
      )!,
    );
  }

  @override
  $LocalRestoreEntityTable createAlias(String alias) {
    return $LocalRestoreEntityTable(attachedDatabase, alias);
  }

  @override
  bool get withoutRowId => true;
  @override
  bool get isStrict => true;
}

class LocalRestoreEntityData extends i0.DataClass
    implements i0.Insertable<i1.LocalRestoreEntityData> {
  /// Local asset id awaiting resolution.
  final String assetId;

  /// Owner (user id) the watch belongs to. Scopes the list per account so it is
  /// cleared on account switch; intentionally NOT a foreign key, for the same
  /// reason as the local → server deletion queue's owner column.
  final String ownerId;
  const LocalRestoreEntityData({required this.assetId, required this.ownerId});
  @override
  Map<String, i0.Expression> toColumns(bool nullToAbsent) {
    final map = <String, i0.Expression>{};
    map['asset_id'] = i0.Variable<String>(assetId);
    map['owner_id'] = i0.Variable<String>(ownerId);
    return map;
  }

  factory LocalRestoreEntityData.fromJson(
    Map<String, dynamic> json, {
    i0.ValueSerializer? serializer,
  }) {
    serializer ??= i0.driftRuntimeOptions.defaultSerializer;
    return LocalRestoreEntityData(
      assetId: serializer.fromJson<String>(json['assetId']),
      ownerId: serializer.fromJson<String>(json['ownerId']),
    );
  }
  @override
  Map<String, dynamic> toJson({i0.ValueSerializer? serializer}) {
    serializer ??= i0.driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'assetId': serializer.toJson<String>(assetId),
      'ownerId': serializer.toJson<String>(ownerId),
    };
  }

  i1.LocalRestoreEntityData copyWith({String? assetId, String? ownerId}) =>
      i1.LocalRestoreEntityData(
        assetId: assetId ?? this.assetId,
        ownerId: ownerId ?? this.ownerId,
      );
  LocalRestoreEntityData copyWithCompanion(
    i1.LocalRestoreEntityCompanion data,
  ) {
    return LocalRestoreEntityData(
      assetId: data.assetId.present ? data.assetId.value : this.assetId,
      ownerId: data.ownerId.present ? data.ownerId.value : this.ownerId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalRestoreEntityData(')
          ..write('assetId: $assetId, ')
          ..write('ownerId: $ownerId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(assetId, ownerId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is i1.LocalRestoreEntityData &&
          other.assetId == this.assetId &&
          other.ownerId == this.ownerId);
}

class LocalRestoreEntityCompanion
    extends i0.UpdateCompanion<i1.LocalRestoreEntityData> {
  final i0.Value<String> assetId;
  final i0.Value<String> ownerId;
  const LocalRestoreEntityCompanion({
    this.assetId = const i0.Value.absent(),
    this.ownerId = const i0.Value.absent(),
  });
  LocalRestoreEntityCompanion.insert({
    required String assetId,
    required String ownerId,
  }) : assetId = i0.Value(assetId),
       ownerId = i0.Value(ownerId);
  static i0.Insertable<i1.LocalRestoreEntityData> custom({
    i0.Expression<String>? assetId,
    i0.Expression<String>? ownerId,
  }) {
    return i0.RawValuesInsertable({
      if (assetId != null) 'asset_id': assetId,
      if (ownerId != null) 'owner_id': ownerId,
    });
  }

  i1.LocalRestoreEntityCompanion copyWith({
    i0.Value<String>? assetId,
    i0.Value<String>? ownerId,
  }) {
    return i1.LocalRestoreEntityCompanion(
      assetId: assetId ?? this.assetId,
      ownerId: ownerId ?? this.ownerId,
    );
  }

  @override
  Map<String, i0.Expression> toColumns(bool nullToAbsent) {
    final map = <String, i0.Expression>{};
    if (assetId.present) {
      map['asset_id'] = i0.Variable<String>(assetId.value);
    }
    if (ownerId.present) {
      map['owner_id'] = i0.Variable<String>(ownerId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalRestoreEntityCompanion(')
          ..write('assetId: $assetId, ')
          ..write('ownerId: $ownerId')
          ..write(')'))
        .toString();
  }
}
