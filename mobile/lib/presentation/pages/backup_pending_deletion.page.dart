import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/pages/common/large_leading_tile.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:intl/intl.dart';

@RoutePage()
class BackupPendingDeletionPage extends HookConsumerWidget {
  const BackupPendingDeletionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(pendingDeletionsProvider);
    final repository = ref.watch(driftProvider).localDeletionRepository;
    final backgroundSync = ref.watch(backgroundSyncProvider);
    final expandedAlbumIds = useState(const <String?>{});

    Future<void> decide(Future<void> decision) async {
      await decision;
      unawaited(backgroundSync.flushLocalDeletions());
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.t.backup_controller_page_deletions)),
      body: result.when(
        data: (List<PendingDeletion> pending) {
          if (pending.isEmpty) {
            return Center(child: Text(context.t.backup_pending_deletions_empty, style: context.textTheme.bodyMedium));
          }
          final awaiting = pending.where((d) => d.awaitingConfirmation).toList();
          final scheduled = pending.where((d) => !d.awaitingConfirmation).toList();
          final groups = groupBy(
            awaiting,
            (PendingDeletion d) => d.albumId,
          ).values.sortedBy((group) => (group.first.albumName ?? '').toLowerCase());

          void toggle(String? albumId) {
            final ids = {...expandedAlbumIds.value};
            if (!ids.remove(albumId)) {
              ids.add(albumId);
            }
            expandedAlbumIds.value = ids;
          }

          return CustomScrollView(
            slivers: [
              if (awaiting.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _AwaitingConfirmationHeader(
                    onKeepAll: () => decide(repository.discard(awaiting.map((d) => d.remoteId))),
                    onTrashAll: () => showDialog<void>(
                      context: context,
                      builder: (context) => ConfirmDialog(
                        title: context.t.backup_pending_deletions_trash_all,
                        content: context.t.backup_pending_deletions_trash_all_confirmation(count: awaiting.length),
                        ok: context.t.backup_pending_deletions_trash,
                        onOk: () => decide(repository.confirm(awaiting.map((d) => d.remoteId))),
                      ),
                    ),
                  ),
                ),
                for (final group in groups) ...[
                  SliverToBoxAdapter(
                    child: _AwaitingConfirmationGroup(
                      group: group,
                      isExpanded: expandedAlbumIds.value.contains(group.first.albumId),
                      onToggle: () => toggle(group.first.albumId),
                      onKeep: () => decide(repository.discard(group.map((d) => d.remoteId))),
                      onTrash: () => decide(repository.confirm(group.map((d) => d.remoteId))),
                    ),
                  ),
                  if (expandedAlbumIds.value.contains(group.first.albumId)) _AwaitingConfirmationGrid(group: group),
                ],
                if (scheduled.isNotEmpty)
                  SliverToBoxAdapter(child: Divider(height: 32, color: context.colorScheme.outlineVariant)),
              ],
              SliverPadding(
                padding: EdgeInsets.only(
                  top: awaiting.isEmpty ? 16.0 : 0,
                  bottom: MediaQuery.paddingOf(context).bottom + 16.0,
                ),
                sliver: SliverList.separated(
                  separatorBuilder: (context, index) => Divider(color: context.colorScheme.outlineVariant),
                  itemCount: scheduled.length,
                  itemBuilder: (context, index) =>
                      _PendingDeletionTile(deletion: scheduled[index], isHeldBack: awaiting.isNotEmpty),
                ),
              ),
            ],
          );
        },
        error: (Object error, StackTrace stackTrace) {
          return Center(child: Text(error.toString()));
        },
        loading: () {
          return const SizedBox(height: 48, width: 48, child: Center(child: CircularProgressIndicator.adaptive()));
        },
      ),
    );
  }
}

class _AwaitingConfirmationHeader extends StatelessWidget {
  final Future<void> Function() onKeepAll;
  final Future<void> Function() onTrashAll;

  const _AwaitingConfirmationHeader({required this.onKeepAll, required this.onTrashAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t.backup_pending_deletions_awaiting_title, style: context.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            context.t.backup_pending_deletions_awaiting_description,
            style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary),
          ),
          const SizedBox(height: 8),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              ImmichTextButton(
                labelText: context.t.backup_pending_deletions_keep_all,
                variant: .ghost,
                expanded: false,
                onPressed: onKeepAll,
              ),
              ImmichTextButton(
                labelText: context.t.backup_pending_deletions_trash_all,
                variant: .ghost,
                expanded: false,
                onPressed: onTrashAll,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AwaitingConfirmationGroup extends StatelessWidget {
  final List<PendingDeletion> group;
  final bool isExpanded;
  final VoidCallback onToggle;
  final Future<void> Function() onKeep;
  final Future<void> Function() onTrash;

  const _AwaitingConfirmationGroup({
    required this.group,
    required this.isExpanded,
    required this.onToggle,
    required this.onKeep,
    required this.onTrash,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          onTap: onToggle,
          title: Text(
            group.first.albumName ?? context.t.other,
            style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500, fontSize: 16),
          ),
          subtitle: Text(
            context.t.items_count(count: group.length),
            style: TextStyle(fontSize: 13.0, color: context.colorScheme.onSurfaceSecondary),
          ),
          trailing: Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              ImmichTextButton(
                labelText: context.t.backup_pending_deletions_keep,
                variant: .ghost,
                expanded: false,
                onPressed: onKeep,
              ),
              ImmichTextButton(
                labelText: context.t.backup_pending_deletions_trash,
                variant: .ghost,
                expanded: false,
                onPressed: onTrash,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AwaitingConfirmationGrid extends StatelessWidget {
  final List<PendingDeletion> group;

  const _AwaitingConfirmationGrid({required this.group});

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          crossAxisSpacing: 2.0,
          mainAxisSpacing: 2.0,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final deletion = group[index];
          return Thumbnail.remote(remoteId: deletion.remoteId, thumbhash: deletion.thumbHash ?? '', fit: BoxFit.cover);
        }, childCount: group.length),
      ),
    );
  }
}

class _PendingDeletionTile extends StatelessWidget {
  final PendingDeletion deletion;
  final bool isHeldBack;

  const _PendingDeletionTile({required this.deletion, required this.isHeldBack});

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat.yMMMd(resolvedDateTimeLocale()).add_Hm();
    final scheduledAt = deletion.createdAt.add(kLocalDeletionSettleDuration);
    return LargeLeadingTile(
      onTap: () {},
      title: Text(
        deletion.name ?? context.t.unknown,
        style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500, fontSize: 16),
      ),
      subtitle: Text(
        isHeldBack
            ? context.t.backup_pending_deletions_waiting
            : context.t.backup_pending_deletions_scheduled(date: dateFormat.format(scheduledAt.toLocal())),
        style: TextStyle(fontSize: 13.0, color: context.colorScheme.onSurfaceSecondary),
      ),
      leading: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: SizedBox(
          width: 64,
          height: 64,
          child: Thumbnail.remote(remoteId: deletion.remoteId, thumbhash: deletion.thumbHash ?? '', fit: BoxFit.cover),
        ),
      ),
    );
  }
}
