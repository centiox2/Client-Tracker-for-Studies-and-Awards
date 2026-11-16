import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../services/daily_reports_service.dart';
import '../../state/app_state.dart';
import 'report_editor.dart';

/// The bell: a count of unread notifications, and work waiting for review.
/// Opens the notifications list.
class ReportBell extends ConsumerWidget {
  const ReportBell({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badge = ref.watch(reportBadgeProvider);
    final unread = badge?.unread ?? 0;
    return IconButton(
      key: const ValueKey('report-bell'),
      tooltip: unread == 0
          ? 'Notifications'
          : '$unread unread notification${unread == 1 ? '' : 's'}',
      visualDensity: compact ? VisualDensity.compact : null,
      onPressed: () => showReportNotifications(context, ref),
      icon: Badge.count(
        count: unread,
        isLabelVisible: unread > 0,
        child: Icon(
          unread > 0
              ? Icons.notifications_active_outlined
              : Icons.notifications_none,
          size: compact ? 20 : 22,
        ),
      ),
    );
  }
}

/// The newest notifications. Opening it marks them read; tapping one opens
/// its task.
Future<void> showReportNotifications(BuildContext context, WidgetRef ref) =>
    showDialog<void>(
      context: context,
      builder: (_) => const _NotificationsDialog(),
    );

class _NotificationsDialog extends ConsumerStatefulWidget {
  const _NotificationsDialog();

  @override
  ConsumerState<_NotificationsDialog> createState() =>
      _NotificationsDialogState();
}

class _NotificationsDialogState extends ConsumerState<_NotificationsDialog> {
  List<ReportNotification>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(dailyReportsProvider);
    try {
      final items = await service.notifications();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
      if (items.any((n) => !n.read)) {
        await service.markRead();
        ref.read(reportBadgeProvider.notifier).refresh();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _open(ReportNotification n) async {
    final id = n.reportId;
    final appActions = ref.read(appActionsProvider);
    // The 4 pm reminder: straight to the quick line, ready to type.
    if (n.kind == NotificationKind.reminder || id == null) {
      Navigator.pop(context);
      if (n.kind == NotificationKind.reminder) {
        ref.read(reportFocusProvider.notifier).request(ReportFocus.quickLine);
      }
      appActions.selectTab(AppTab.dailyReports);
      return;
    }
    final service = ref.read(dailyReportsProvider);
    try {
      final start = ref.read(reportStartProvider);
      final meta = start?.meta ?? await service.meta();
      // The task comes with the notification, so it opens at once.
      var task = n.report;
      if (task == null && n.task.isNotEmpty) {
        final found = await service.list(
          ReportFilter(search: '#$id', limit: 1),
        );
        task = found.where((t) => t.id == id).firstOrNull;
      }
      if (!mounted) return;
      if (task == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That task has been deleted.')),
        );
        return;
      }
      await showReportDetails(context, meta: meta, report: task);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeReportError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final items = _items;
    return AlertDialog(
      title: const Text('Notifications'),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 480,
        height: 460,
        child: items == null
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Text(describeReportError(_error!), style: muted),
              )
            : items.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Nothing yet. You’ll hear here when someone assigns you '
                    'a task, reviews your work, comments, or when something '
                    'is due.',
                    textAlign: TextAlign.center,
                    style: muted,
                  ),
                ),
              )
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: c.borderSubtle),
                itemBuilder: (context, i) {
                  final n = items[i];
                  final color = switch (n.kind) {
                    NotificationKind.returned ||
                    NotificationKind.overdue ||
                    NotificationKind.blocked => theme.colorScheme.error,
                    NotificationKind.approved => Dt.statusGreen(
                      theme.brightness,
                    ),
                    NotificationKind.assigned =>
                      n.urgency?.color(theme.brightness) ?? c.accent,
                    _ => c.accent,
                  };
                  return InkWell(
                    key: ValueKey('notification-${n.id}'),
                    borderRadius: BorderRadius.circular(Dt.rSm),
                    onTap: () => _open(n),
                    child: Container(
                      color: n.read
                          ? null
                          : c.accentSoft.withValues(alpha: 0.5),
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: color.withValues(alpha: 0.14),
                            child: Icon(n.kind.icon, size: 16, color: color),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  n.title,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: n.read
                                        ? FontWeight.w500
                                        : FontWeight.w700,
                                  ),
                                ),
                                if (n.detail.isNotEmpty)
                                  Text(
                                    n.detail,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                const SizedBox(height: 2),
                                Text(taskStamp(n.createdAt), style: muted),
                              ],
                            ),
                          ),
                          if (!n.read)
                            Container(
                              margin: const EdgeInsets.only(top: 6, left: 6),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: c.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            ref.read(appActionsProvider).selectTab(AppTab.dailyReports);
          },
          child: const Text('Open Daily reports'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
