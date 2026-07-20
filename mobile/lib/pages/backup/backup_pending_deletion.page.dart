import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/local_deletion.repository.dart';
import 'package:immich_mobile/pages/common/large_leading_tile.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:intl/intl.dart';

@RoutePage()
class BackupPendingDeletionPage extends ConsumerWidget {
  const BackupPendingDeletionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(pendingDeletionsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t.backup_controller_page_deletions)),
      body: result.when(
        data: (List<PendingDeletion> pending) {
          if (pending.isEmpty) {
            return Center(child: Text(context.t.backup_pending_deletions_empty, style: context.textTheme.bodyMedium));
          }
          final dateFormat = DateFormat.yMMMd(resolvedDateTimeLocale()).add_Hm();
          return ListView.separated(
            padding: const EdgeInsets.only(top: 16.0),
            separatorBuilder: (context, index) => Divider(color: context.colorScheme.outlineVariant),
            itemCount: pending.length,
            itemBuilder: (context, index) {
              final deletion = pending[index];
              final scheduledAt = deletion.createdAt.add(kLocalDeletionSettleDuration);
              return LargeLeadingTile(
                onTap: () {},
                title: Text(
                  deletion.name ?? deletion.remoteId,
                  style: context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500, fontSize: 16),
                ),
                subtitle: Text(
                  context.t.backup_pending_deletion_scheduled(date: dateFormat.format(scheduledAt.toLocal())),
                  style: TextStyle(fontSize: 13.0, color: context.colorScheme.onSurfaceSecondary),
                ),
                leading: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: Thumbnail.remote(
                      remoteId: deletion.remoteId,
                      thumbhash: deletion.thumbHash ?? '',
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              );
            },
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
