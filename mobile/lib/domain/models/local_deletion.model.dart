import 'package:freezed_annotation/freezed_annotation.dart';

part 'local_deletion.model.freezed.dart';

@freezed
abstract class PendingDeletion with _$PendingDeletion {
  const factory PendingDeletion({
    required String remoteId,
    required DateTime createdAt,
    required bool awaitingConfirmation,
    String? name,
    String? thumbHash,
    String? albumId,
    String? albumName,
  }) = _PendingDeletion;
}
