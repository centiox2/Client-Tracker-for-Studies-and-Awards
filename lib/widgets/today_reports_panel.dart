import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_theme.dart';
import '../services/daily_reports_service.dart';
import '../state/app_state.dart';
import '../state/cloud_sync.dart';
import 'clarity.dart';
import 'panels.dart';

/// Today's daily reports for everyone this account sees: who has reported,
/// what is open or overdue. On Overview and in Reports.
/// Who has recorded their daily report today (online).
final todayReportsProvider = FutureProvider.autoDispose<ReportSummary?>((
  ref,
) async {
  ref.watch(reportsChangedProvider);
  ref.watch(cloudSyncProvider.select((s) => s.phase == SyncPhase.live));
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  try {
    return await ref.read(dailyReportsProvider).summary(today, today);
  } catch (_) {
    return null;
  }
});

class TodayReportsPanel extends ConsumerWidget {
  const TodayReportsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final summary = ref.watch(todayReportsProvider);
    void open() => ref.read(appActionsProvider).selectTab(AppTab.dailyReports);
    final s = summary.value;
    final people = s?.compliance ?? const <ComplianceRow>[];
    final done = people.where((p) => p.submittedToday).length;
    final missing = [
      for (final p in people)
        if (!p.submittedToday) p,
    ];
    return AppPanel(
      key: const ValueKey('overview-daily'),
      title: 'Today’s reports',
      trailingWidget: TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 28),
        ),
        onPressed: open,
        child: const Text('Open'),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: summary.isLoading && s == null
            ? const SizedBox(
                height: 48,
                child: Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : s == null
            ? Text(
                'Daily reports show here when you’re online.',
                style: theme.textTheme.bodyMedium?.copyWith(color: c.textMuted),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FigureStat(
                          label: 'Reported today',
                          value: people.isEmpty
                              ? '${s.total}'
                              : '$done of ${people.length}',
                        ),
                      ),
                      Expanded(
                        child: FigureStat(
                          label: 'Open items',
                          value: '${s.open}',
                        ),
                      ),
                      Expanded(
                        child: FigureStat(
                          label: 'Overdue',
                          value: '${s.overdue.length}',
                          tone: s.overdue.isEmpty
                              ? DeltaTone.neutral
                              : DeltaTone.down,
                        ),
                      ),
                    ],
                  ),
                  if (missing.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Not yet today: '
                      '${missing.take(6).map((p) => p.fullName).join(', ')}'
                      '${missing.length > 6 ? ' and ${missing.length - 6} more' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
