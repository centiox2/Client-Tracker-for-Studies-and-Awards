import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../ai_summary/ai_summary_screen.dart';
import '../../repositories/revenue_repository.dart' show formatMoney;
import '../../services/daily_reports_service.dart';
import '../../services/todo_service.dart';
import '../../state/app_state.dart';
import '../../state/mobile_navigation.dart';
import '../../widgets/app_page_header.dart';
import '../../widgets/card_board.dart';
import '../../widgets/clarity.dart';
import '../../widgets/panels.dart';
import '../../widgets/today_reports_panel.dart';
import '../../widgets/week_label.dart';

/// One concise snapshot for every page this person may open.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pages = ref
        .watch(availableAppTabsProvider)
        .where((tab) => tab != AppTab.home && tab != AppTab.aiSummary)
        .toList();
    final width = MediaQuery.sizeOf(context).width;
    return SingleChildScrollView(
      key: const ValueKey('overview-page'),
      padding: clarityPagePadding(width),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Dt.contentMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AppPageHeader(tab: AppTab.home),
              const SizedBox(height: 8),
              Text(
                'Business and team activity at a glance.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: context.clarity.textMuted),
              ),
              const SizedBox(height: 24),
              const AiSummaryPreview(),
              CardBoard(
                boardKey: 'workspace-overview',
                minColumnWidth: 330,
                cards: [
                  for (final (index, tab) in pages.indexed)
                    BoardCard(
                      tab.name,
                      _PageSnapshot(tab: tab),
                      column: index % 3,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Snapshot {
  const _Snapshot(this.value, this.label, {this.facts = const [], this.note});
  final String value;
  final String label;
  final List<(String, String)> facts;
  final String? note;
}

class _PageSnapshot extends ConsumerWidget {
  const _PageSnapshot({required this.tab});
  final AppTab tab;

  _Snapshot _read(WidgetRef ref) {
    final now = DateTime.now();
    final today = DateUtils.dateOnly(now);
    switch (tab) {
      case AppTab.week:
        final data = ref.watch(currentWeekProvider);
        final totals = data?.totals;
        return _Snapshot(
          totals == null ? '—' : '${totals.total}',
          'Clients in the selected week',
          facts: totals == null
              ? []
              : [
                  ('New clients', '${totals.newClients}'),
                  ('Existing clients', '${totals.existingClients}'),
                  ('Daily average', '${_average(totals.dailyAverage)} / day'),
                ],
          note: data == null
              ? 'No week yet. Open the tracker to start one.'
              : shortRangeLabel(data.week.startDate, data.week.endDate),
        );
      case AppTab.todo:
        final items = ref
            .watch(todoListProvider)
            .where((t) => !t.archived && !t.deleted)
            .toList();
        final mine = items.where((t) => !t.team);
        final open = mine.where((t) => !t.done).toList();
        final loaded = ref.read(todoListProvider.notifier).loaded;
        return _Snapshot(
          loaded ? '${open.length}' : '—',
          'Personal open items',
          facts: loaded
              ? [
                  (
                    'Planned today',
                    '${open.where((t) => t.planned == today).length}',
                  ),
                  ('Overdue', '${open.where((t) => t.overdue).length}'),
                  (
                    'Team open',
                    '${items.where((t) => t.team && !t.done).length}',
                  ),
                ]
              : [],
          note: loaded
              ? '${mine.where((t) => t.done && t.doneAt != null && DateUtils.isSameDay(t.doneAt, today)).length} completed today'
              : 'Loading your list…',
        );
      case AppTab.revenue:
        final currency = ref.watch(currencyProvider);
        final entries = ref.watch(revenueEntriesProvider(today));
        final month = ref.watch(
          revenueDaysProvider((DateTime(now.year, now.month), today)),
        );
        return _Snapshot(
          formatMoney(entries.fold(0, (n, e) => n + e.amountCents), currency),
          'Revenue today',
          facts: [
            (
              'Month to date',
              formatMoney(month.fold(0, (n, d) => n + d.totalCents), currency),
            ),
            (
              'Payments today',
              '${entries.where((e) => e.amountCents > 0).length}',
            ),
          ],
          note: 'Net of refunds · ${DateFormat('MMMM y').format(now)}',
        );
      case AppTab.applications:
        ref.watch(dataVersionProvider);
        final repository = ref.read(applicationRepositoryProvider);
        final apps = repository.all();
        bool thisMonth(DateTime? date) =>
            date != null && date.year == now.year && date.month == now.month;
        return _Snapshot(
          '${apps.where((a) => a.inProgress).length}',
          'Applications in progress',
          facts: [
            (
              'Offers this month',
              '${apps.where((a) => thisMonth(a.offerDate)).length}',
            ),
            (
              'COEs this month',
              '${apps.where((a) => thisMonth(a.coeDate)).length}',
            ),
            (
              'Offers overdue',
              '${apps.where((a) => a.offerOverdue(today)).length}',
            ),
          ],
          note: apps.isEmpty
              ? 'No application data has been imported.'
              : '${apps.length} total applications',
        );
      case AppTab.staff:
        final staff = ref.watch(staffListProvider);
        final active = staff.where((s) => s.active).length;
        return _Snapshot(
          '$active',
          'Active staff',
          facts: [
            ('All staff', '${staff.length}'),
            ('Inactive', '${staff.length - active}'),
          ],
          note: 'Team members and availability',
        );
      case AppTab.history:
        final weeks = ref.watch(historyProvider);
        return _Snapshot(
          '${weeks.length}',
          'Recorded weeks',
          facts: [
            (
              'Clients recorded',
              '${weeks.fold(0, (n, w) => n + w.totals.total)}',
            ),
          ],
          note: weeks.isEmpty
              ? 'Past weeks appear here as tracking begins.'
              : 'Latest: ${shortRangeLabel(weeks.first.week.startDate, weeks.first.week.endDate)}',
        );
      case AppTab.reports:
        final totals = ref.watch(monthTotalsProvider);
        return _Snapshot(
          '${totals.total}',
          'Clients this month',
          facts: [
            ('New clients', '${totals.newClients}'),
            ('Existing clients', '${totals.existingClients}'),
            ('Daily average', '${_average(totals.dailyAverage)} / day'),
          ],
          note:
              '${DateFormat('MMMM y').format(now)} · Performance, trends and exports',
        );
      case AppTab.settings:
        final theme = ref.watch(themeModeProvider);
        final scale = ref.watch(textScaleProvider);
        final pinned = ref.watch(mobileBarTabsProvider);
        return _Snapshot(
          ref.watch(currentUserProvider)?.fullName ??
              ref.watch(sessionProvider)?.label ??
              'Your account',
          'Your workspace preferences',
          facts: [
            (
              'Appearance',
              switch (theme) {
                ThemeMode.light => 'Light',
                ThemeMode.dark => 'Dark',
                ThemeMode.system => 'System',
              },
            ),
            (
              'Text size',
              TextScaleNotifier.sizes
                      .where((s) => (s.$1 - scale).abs() < 0.001)
                      .firstOrNull
                      ?.$2 ??
                  'Custom',
            ),
          ],
          note: 'Bottom bar: ${pinned.map(pageTitle).join(' · ')}',
        );
      case AppTab.dailyReports:
        final summary = ref.watch(todayReportsProvider);
        final data = summary.value;
        if (data != null) {
          final submitted = data.compliance
              .where((p) => p.submittedToday)
              .length;
          return _Snapshot(
            '${data.submitted}',
            'Submitted today',
            facts: [
              ('Open tasks', '${data.open}'),
              ('Overdue', '${data.overdue.length}'),
              ('Awaiting review', '${data.reviewed(ReviewState.submitted)}'),
            ],
            note: data.compliance.isEmpty
                ? 'Activity for the people you can see'
                : '$submitted of ${data.compliance.length} people reported today',
          );
        }
        final cached = ref.watch(reportViewProvider);
        if (cached != null) {
          return _Snapshot(
            '${cached.submissions.where((s) => DateUtils.isSameDay(s.date, today)).length}',
            'Your saved submissions today',
            facts: [
              (
                'Your open tasks',
                '${cached.tasks.where((t) => t.status.isOpen).length}',
              ),
              ('Awaiting your review', '${cached.badge.toReview}'),
            ],
            note: 'Saved activity · Department totals are unavailable',
          );
        }
        return _Snapshot(
          '—',
          summary.isLoading
              ? 'Loading daily reports…'
              : 'Daily reports unavailable',
          note: 'Open Daily reports to reconnect and view activity.',
        );
      case AppTab.aiSummary:
      case AppTab.home:
        throw StateError('Overview does not summarize itself.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = _read(ref);
    final theme = Theme.of(context);
    final c = context.clarity;
    return InkWell(
      onTap: () => ref.read(appActionsProvider).selectTab(tab),
      borderRadius: BorderRadius.circular(16),
      child: AppPanel(
        key: ValueKey('overview-${tab.name}'),
        title: pageTitle(tab),
        compactHeader: true,
        trailingWidget: IconButton(
          key: ValueKey('overview-open-${tab.name}'),
          onPressed: () => ref.read(appActionsProvider).selectTab(tab),
          tooltip: 'Open ${pageTitle(tab)}',
          icon: const Icon(Icons.arrow_forward, size: 18),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  snapshot.value,
                  style: Dt.tab(theme.textTheme.headlineMedium!),
                ),
              ),
              const SizedBox(height: 4),
              Text(snapshot.label, style: theme.textTheme.bodyMedium),
              if (snapshot.facts.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 20,
                  runSpacing: 12,
                  children: [
                    for (final (label, value) in snapshot.facts)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: c.textMuted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            value,
                            style: Dt.tab(theme.textTheme.titleSmall!),
                          ),
                        ],
                      ),
                  ],
                ),
              ],
              if (snapshot.note != null) ...[
                const SizedBox(height: 16),
                Text(snapshot.note!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _average(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);
