import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/client_count_repository.dart';
import '../../services/export_actions.dart';
import '../../state/app_state.dart';
import '../../widgets/app_page_header.dart';
import '../../widgets/clarity.dart';
import '../../widgets/panels.dart';
import '../../widgets/week_label.dart';

/// Overview: this week's numbers at a glance — headline figures, the week
/// day by day (chart and table), who's logged the most, recent weeks.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(currentWeekProvider);
    final month = ref.watch(monthTotalsProvider);
    final staff = ref
        .watch(staffListProvider)
        .where((person) => person.active)
        .length;
    final history = ref.watch(historyProvider);
    final canEdit = ref.watch(canEditProvider);
    final week = data?.totals;
    final previous = ref.watch(previousWeekTotalsProvider);
    final suggestedWeek = ref.watch(suggestedWeekStartProvider);
    final now = DateTime.now();
    // "this week" only when the week shown really is the current one.
    final isCurrent = data == null || data.dayFor(now) != null;
    final unit = isCurrent
        ? 'this week'
        : 'week of ${DateFormat('d MMM').format(data.week.startDate)}';
    final logged = data?.staffTotals.where((s) => s.total > 0).length ?? 0;

    (String?, DeltaTone) delta(int? cur, int? prev) {
      if (cur == null || prev == null) return (null, DeltaTone.neutral);
      return deltaVsLast(cur, prev);
    }

    final (newDelta, newTone) = delta(week?.newClients, previous?.newClients);
    final (exDelta, exTone) = delta(
      week?.existingClients,
      previous?.existingClients,
    );
    final (totDelta, totTone) = delta(week?.total, previous?.total);

    final kpis = [
      KpiCard(
        label: 'New clients',
        value: '${week?.newClients ?? 0}',
        unit: unit,
        caption: newDelta,
        tone: newTone,
      ),
      KpiCard(
        label: 'Existing clients',
        value: '${week?.existingClients ?? 0}',
        unit: unit,
        caption: exDelta,
        tone: exTone,
      ),
      KpiCard(
        label: 'Total clients',
        value: '${week?.total ?? 0}',
        unit: week == null ? unit : _formatAverage(week.dailyAverage),
        caption: totDelta,
        tone: totTone,
      ),
      KpiCard(
        label: 'Clients this month',
        value: '${month.total}',
        unit: _formatAverage(month.dailyAverage),
        caption: DateFormat('MMMM y').format(now),
      ),
      KpiCard(
        label: 'Active staff',
        value: '$staff',
        unit: 'team',
        caption: data == null ? null : '$logged logged clients $unit',
      ),
    ];

    final actions = <Widget>[
      if (canEdit || history.isNotEmpty) WeekRangeButton(canStart: canEdit),
      if (data != null)
        OutlinedButton.icon(
          key: const ValueKey('export-week'),
          onPressed: () => exportWeekToFile(context, ref, data.week),
          icon: const Icon(Icons.file_download_outlined),
          label: const Text('Export'),
        ),
      if (canEdit)
        FilledButton.icon(
          key: const ValueKey('enter-numbers'),
          onPressed: () => ref.read(appActionsProvider).selectTab(AppTab.week),
          icon: const Icon(Icons.add),
          label: const Text('Enter today’s numbers'),
        ),
    ];

    final width = MediaQuery.sizeOf(context).width;
    return SingleChildScrollView(
      padding: clarityPagePadding(width),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppPageHeader(tab: AppTab.home, actions: actions),
              const SizedBox(height: 24),
              if (suggestedWeek != null && canEdit) ...[
                _StartWeekBanner(monday: suggestedWeek),
                const SizedBox(height: Dt.gap),
              ],
              KpiGrid(
                orderKey: 'overview',
                minWidth: width < 640 ? 150 : 190,
                children: kpis,
              ),
              const SizedBox(height: 24),
              MainAndSide(
                main: _ThisWeek(data: data, isCurrent: isCurrent),
                side: [
                  _StaffPanel(data: data, staffCount: staff),
                  _RecentWeeks(history: history, currentId: data?.week.id),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "14 / day", or "14.5 / day" when the average isn't whole.
String _formatAverage(double avg) {
  final rounded = (avg * 10).round() / 10;
  final text = rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
  return '$text / day';
}

/// One-click start for the current week (next week at weekends), shown only
/// while that week hasn't been created.
class _StartWeekBanner extends ConsumerWidget {
  const _StartWeekBanner({required this.monday});
  final DateTime monday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final label = DateFormat('d MMMM').format(monday);
    final staff = ref.watch(staffListProvider).where((s) => s.active).length;
    return ClarityCard(
      padding: const EdgeInsets.fromLTRB(20, 14, 14, 14),
      child: Row(
        children: [
          Icon(Icons.event_available_outlined, size: 18, color: c.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The week of $label hasn’t been started',
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  'Creates Monday–Friday with your $staff active staff.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: () {
              final actions = ref.read(appActionsProvider);
              final week = actions.createWeek(monday);
              actions.selectTab(AppTab.home, weekId: week.id);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Week of $label started')));
            },
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: const Text('Start week'),
          ),
        ],
      ),
    );
  }
}

/// The week day by day: a stacked chart, then a table with each day's
/// status ("Entered", "Due today", "Upcoming") and numbers.
class _ThisWeek extends StatelessWidget {
  const _ThisWeek({required this.data, required this.isCurrent});
  final CurrentWeekData? data;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final data = this.data;
    if (data == null) {
      return AppPanel(
        title: 'This week',
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'No week yet. Start one to begin tracking clients.',
            style: theme.textTheme.bodyMedium?.copyWith(color: c.textMuted),
          ),
        ),
      );
    }
    final days = data.days;
    final today = DateUtils.dateOnly(DateTime.now());
    final entered = days
        .where((d) => d.workingRows.any((r) => r.total > 0))
        .length;
    final start = data.week.startDate, end = data.week.endDate;
    final range = start.month == end.month
        ? '${DateFormat('EEE d').format(start)} – '
              '${DateFormat('EEE d MMMM').format(end)}'
        : '${DateFormat('EEE d MMM').format(start)} – '
              '${DateFormat('EEE d MMM').format(end)}';
    final phone = MediaQuery.sizeOf(context).width < 640;

    final head = theme.textTheme.labelSmall?.copyWith(
      color: c.textMuted,
      fontWeight: FontWeight.w500,
    );
    final cell = Dt.tab(theme.textTheme.bodyMedium!);
    final pad = EdgeInsets.symmetric(horizontal: phone ? 14 : 20);

    Widget num(int? v, {bool bold = false}) => Expanded(
      flex: 2,
      child: Text(
        v == null ? '—' : '$v',
        textAlign: TextAlign.right,
        style: cell.copyWith(
          color: v == null ? c.textMuted : c.text,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );

    StatusPill status(DayWithCounts d, bool has) {
      final date = DateUtils.dateOnly(d.day.date);
      if (d.isHoliday) return const StatusPill('Holiday');
      if (has) return const StatusPill('Entered', tone: PillTone.positive);
      if (date == today) {
        return const StatusPill('Due today', tone: PillTone.warning);
      }
      if (date.isAfter(today)) return const StatusPill('Upcoming');
      return const StatusPill('Not entered', tone: PillTone.warning);
    }

    return AppPanel(
      title: isCurrent
          ? 'This week'
          : 'Week of ${DateFormat('d MMM').format(start)}',
      subtitle: '$range · $entered of ${days.length} days entered',
      trailingWidget: phone ? null : const NewExistingLegend(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (phone)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: NewExistingLegend(),
              ),
            ),
          StackedDayChart(
            height: phone ? 140 : 180,
            days: [
              for (final d in days)
                ChartDay(
                  date: d.day.date,
                  newClients: d.workingRows.fold(0, (a, r) => a + r.newClients),
                  existingClients: d.workingRows.fold(
                    0,
                    (a, r) => a + r.existingClients,
                  ),
                  isHoliday: d.isHoliday,
                ),
            ],
          ),
          Container(
            padding: pad.add(const EdgeInsets.symmetric(vertical: 12)),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.borderSubtle)),
            ),
            child: Row(
              children: [
                Expanded(flex: 5, child: Text('Day', style: head)),
                if (!phone)
                  Expanded(flex: 4, child: Text('Status', style: head)),
                Expanded(
                  flex: 2,
                  child: Text('New', textAlign: TextAlign.right, style: head),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    phone ? 'Exist.' : 'Existing',
                    textAlign: TextAlign.right,
                    style: head,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text('Total', textAlign: TextAlign.right, style: head),
                ),
              ],
            ),
          ),
          for (final d in days)
            Builder(
              builder: (context) {
                final has = d.workingRows.any((r) => r.total > 0);
                final n = d.workingRows.fold(0, (a, r) => a + r.newClients);
                final e = d.workingRows.fold(
                  0,
                  (a, r) => a + r.existingClients,
                );
                return Container(
                  key: ValueKey('overview-day-${d.day.id}'),
                  padding: pad.add(const EdgeInsets.symmetric(vertical: 12)),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: c.borderSubtle)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: phone
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    DateFormat('EEE d MMM').format(d.day.date),
                                    style: cell.copyWith(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  status(d, has),
                                ],
                              )
                            : Text(
                                DateFormat('EEEE, d MMM').format(d.day.date),
                                style: cell.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                      ),
                      if (!phone)
                        Expanded(
                          flex: 4,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: status(d, has),
                          ),
                        ),
                      num(has ? n : null),
                      num(has ? e : null),
                      num(has ? n + e : null, bold: true),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Who's logged the most this week, as meters.
class _StaffPanel extends ConsumerWidget {
  const _StaffPanel({required this.data, required this.staffCount});
  final CurrentWeekData? data;
  final int staffCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final rows = (data?.staffTotals ?? const <StaffWeekTotals>[]).toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    final active = rows.where((r) => r.total > 0).toList();
    final top = active.isEmpty ? 1 : active.first.total;
    return AppPanel(
      title: 'Staff performance',
      trailing: data == null
          ? null
          : '${active.length} of ${rows.length} active',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (active.isEmpty)
              Text(
                'Staff totals appear here once numbers are entered.',
                style: theme.textTheme.bodyMedium?.copyWith(color: c.textMuted),
              ),
            for (final (i, r) in active.take(6).indexed) ...[
              if (i > 0) const SizedBox(height: 14),
              Meter(label: r.name, value: r.total, max: top),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('view-all-staff'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                ),
                onPressed: () =>
                    ref.read(appActionsProvider).selectTab(AppTab.staff),
                child: Text('View all $staffCount staff →'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last few weeks and their totals.
class _RecentWeeks extends ConsumerWidget {
  const _RecentWeeks({required this.history, required this.currentId});
  final List<WeekSummary> history;
  final int? currentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final today = DateUtils.dateOnly(DateTime.now());
    return AppPanel(
      title: 'Recent weeks',
      trailingWidget: TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 28),
        ),
        onPressed: () => ref.read(appActionsProvider).selectTab(AppTab.history),
        child: const Text('History'),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: history.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Weekly summaries will appear here.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: c.textMuted,
                  ),
                ),
              )
            : ListRows(
                rows: [
                  for (final w in history.take(4))
                    (
                      shortRangeLabel(w.week.startDate, w.week.endDate),
                      !today.isBefore(DateUtils.dateOnly(w.week.startDate)) &&
                              !today.isAfter(DateUtils.dateOnly(w.week.endDate))
                          ? 'in progress'
                          : null,
                      '${w.totals.total}',
                      () {
                        ref.read(currentWeekIdProvider.notifier).set(w.week.id);
                      },
                    ),
                ],
              ),
      ),
    );
  }
}
