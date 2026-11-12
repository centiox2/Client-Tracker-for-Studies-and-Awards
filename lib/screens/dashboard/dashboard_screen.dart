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
import '../../widgets/card_board.dart';
import '../../design/airtable_tags.dart';
import '../../repositories/revenue_repository.dart' show formatMoney;
import '../../widgets/today_reports_panel.dart';
import '../applications/applications_screen.dart' show showApplicationDetails;
import '../reports/reports_screen.dart' show showStaffProfile;

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

    // Each card opens the page behind its number, when this account may.
    final user = ref.watch(currentUserProvider);
    VoidCallback? go(AppTab tab) => (user?.mayOpen(tab.name) ?? true)
        ? () => ref
              .read(appActionsProvider)
              .selectTab(tab, weekId: tab == AppTab.week ? data?.week.id : null)
        : null;
    final kpis = [
      KpiCard(
        label: 'New clients',
        value: '${week?.newClients ?? 0}',
        onTap: go(AppTab.week),
        unit: unit,
        caption: newDelta,
        tone: newTone,
      ),
      KpiCard(
        label: 'Existing clients',
        value: '${week?.existingClients ?? 0}',
        onTap: go(AppTab.week),
        unit: unit,
        caption: exDelta,
        tone: exTone,
      ),
      KpiCard(
        label: 'Total clients',
        value: '${week?.total ?? 0}',
        onTap: go(AppTab.week),
        unit: week == null ? unit : _formatAverage(week.dailyAverage),
        caption: totDelta,
        tone: totTone,
      ),
      KpiCard(
        label: 'Clients this month',
        value: '${month.total}',
        onTap: go(AppTab.reports),
        unit: _formatAverage(month.dailyAverage),
        caption: DateFormat('MMMM y').format(now),
      ),
      KpiCard(
        label: 'Active staff',
        value: '$staff',
        onTap: go(AppTab.staff),
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
    bool may(AppTab t) => user?.mayOpen(t.name) ?? true;
    final linked = ref.watch(linkedStaffProvider);
    final cards = <BoardCard>[
      BoardCard('week', _ThisWeek(data: data, isCurrent: isCurrent)),
      if (linked != null)
        BoardCard('you', _YouPanel(data: data, staffId: linked.id), column: 1),
      BoardCard('mix', _MixPanel(data: data, unit: unit), column: 1),
      BoardCard('staff', _StaffPanel(data: data, staffCount: staff), column: 1),
      if (ref.watch(seesRevenueProvider) && may(AppTab.revenue))
        const BoardCard('revenue', _RevenuePanel(), column: 2),
      if (may(AppTab.applications))
        const BoardCard('applications', _ApplicationsPanel(), column: 2),
      if (ref.watch(accountsEnabledProvider) && may(AppTab.dailyReports))
        const BoardCard('daily', TodayReportsPanel(), column: 2),
      const BoardCard('month', _MonthPanel()),
      BoardCard(
        'recent',
        _RecentWeeks(history: history, currentId: data?.week.id),
        column: 1,
      ),
    ];
    return SingleChildScrollView(
      padding: clarityPagePadding(width),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Dt.contentMaxWidth),
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
              const SizedBox(height: Dt.gap),
              CardBoard(boardKey: 'overview', cards: cards),
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

/// Who's logged the most this week: each person's new (green) and existing
/// (blue) clients as one bar. A name opens that person's record.
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
    final me = ref.watch(linkedStaffProvider)?.id;
    return AppPanel(
      title: 'Staff performance',
      trailing: data == null
          ? null
          : '${active.length} of ${rows.length} with clients',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (active.isEmpty)
              Text(
                'Staff totals appear here once numbers are entered.',
                style: theme.textTheme.bodyMedium?.copyWith(color: c.textMuted),
              )
            else ...[
              const Align(
                alignment: Alignment.centerLeft,
                child: NewExistingLegend(),
              ),
              const SizedBox(height: 10),
            ],
            for (final r in active.take(8))
              SplitMeter(
                key: ValueKey('staff-meter-${r.staffId}'),
                label: r.staffId == me ? '${r.name} (you)' : r.name,
                newCount: r.newClients,
                existingCount: r.existingClients,
                max: top,
                onTap: () => showStaffProfile(context, r.staffId),
              ),
            const SizedBox(height: 8),
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
                child: Text('All $staffCount staff →'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// New against existing clients for the week shown, as a split bar with
/// the shares.
class _MixPanel extends StatelessWidget {
  const _MixPanel({required this.data, required this.unit});
  final CurrentWeekData? data;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final n = data?.totals.newClients ?? 0;
    final e = data?.totals.existingClients ?? 0;
    final total = n + e;
    String share(int v) => total == 0 ? '–' : '${(v * 100 / total).round()}%';
    Widget side(String label, int v, Color color) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(share(v), style: Dt.tab(theme.textTheme.headlineSmall!)),
          Text(
            '$v clients',
            style: theme.textTheme.bodySmall?.copyWith(color: c.textMuted),
          ),
        ],
      ),
    );
    return AppPanel(
      key: const ValueKey('client-mix'),
      title: 'Client mix',
      trailing: unit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 12,
                child: total == 0
                    ? ColoredBox(color: c.track)
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (n > 0)
                            Expanded(
                              flex: n,
                              child: ColoredBox(color: c.seriesNew),
                            ),
                          if (n > 0 && e > 0) const SizedBox(width: 2),
                          if (e > 0)
                            Expanded(
                              flex: e,
                              child: ColoredBox(color: c.seriesExisting),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                side('New', n, c.seriesNew),
                side('Existing', e, c.seriesExisting),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The signed-in person's own numbers (their account is linked to a staff
/// member in Settings › Users): this week, today, and their place.
class _YouPanel extends ConsumerWidget {
  const _YouPanel({required this.data, required this.staffId});
  final CurrentWeekData? data;
  final int staffId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final rows = (data?.staffTotals ?? const <StaffWeekTotals>[]).toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    final mine = rows.where((r) => r.staffId == staffId).firstOrNull;
    final rank = mine == null || mine.total == 0
        ? null
        : rows.indexWhere((r) => r.staffId == staffId) + 1;
    final today = data?.dayFor(DateTime.now());
    final todayRow = today?.rows.where((r) => r.staffId == staffId).firstOrNull;
    final offToday = today?.offStaffIds.contains(staffId) ?? false;
    final name = ref.watch(linkedStaffProvider)?.name ?? '';
    Widget fact(String label, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: 2),
          Text(value, style: Dt.tab(theme.textTheme.titleLarge!)),
        ],
      ),
    );
    return AppPanel(
      key: const ValueKey('your-numbers'),
      title: 'Your numbers',
      subtitle: name,
      trailingWidget: TextButton(
        key: const ValueKey('your-record'),
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 28),
        ),
        onPressed: () => showStaffProfile(context, staffId),
        child: const Text('Your record'),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                fact('This week', '${mine?.total ?? 0}'),
                fact(
                  'Today',
                  offToday
                      ? 'Off'
                      : today == null
                      ? '–'
                      : '${todayRow?.total ?? 0}',
                ),
                fact('Place', rank == null ? '–' : '#$rank of ${rows.length}'),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              mine == null
                  ? 'You’re not on this week’s board.'
                  : '${mine.newClients} new · ${mine.existingClients} existing '
                        'this week',
              style: theme.textTheme.bodySmall?.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Today's and this month's money, and the latest payments (Revenue).
class _RevenuePanel extends ConsumerWidget {
  const _RevenuePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final currency = ref.watch(currencyProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final first = DateTime(now.year, now.month);
    final lastFirst = DateTime(now.year, now.month - 1);
    final lastSame = DateTime(
      lastFirst.year,
      lastFirst.month,
      now.day.clamp(1, DateTime(now.year, now.month, 0).day),
    );
    final month = ref.watch(revenueDaysProvider((first, today)));
    final last = ref.watch(revenueDaysProvider((lastFirst, lastSame)));
    final entries = ref.watch(revenueEntriesProvider(today));
    final monthCents = month.fold(0, (a, d) => a + d.totalCents);
    final lastCents = last.fold(0, (a, d) => a + d.totalCents);
    final todayCents = entries.fold(0, (a, e) => a + e.amountCents);
    final (delta, tone) = lastCents == 0
        ? (null, DeltaTone.neutral)
        : deltaVsLast(monthCents, lastCents, vs: 'same days last month');
    void open() => ref.read(appActionsProvider).selectTab(AppTab.revenue);
    return AppPanel(
      key: const ValueKey('overview-revenue'),
      title: 'Money in',
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: FigureStat(
                    label: 'Today',
                    value: formatMoney(todayCents, currency),
                    caption:
                        '${entries.where((e) => e.amountCents > 0).length} '
                        'payments',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FigureStat(
                    label: DateFormat('MMMM').format(now),
                    value: formatMoney(monthCents, currency),
                    caption: delta,
                    tone: tone,
                  ),
                ),
              ],
            ),
            if (entries.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(height: 1, color: c.borderSubtle),
              for (final e in entries.take(4))
                InkWell(
                  onTap: open,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            e.note.isEmpty
                                ? (e.purpose.isEmpty ? 'Payment' : e.purpose)
                                : e.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatMoney(e.amountCents, currency),
                          style: Dt.tab(theme.textTheme.bodyMedium!)
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Where applications stand (from the latest Airtable upload), with the
/// ones that need a nudge. A student opens their card.
class _ApplicationsPanel extends ConsumerWidget {
  const _ApplicationsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    ref.watch(dataVersionProvider);
    final apps = ref.read(applicationRepositoryProvider).all();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final first = DateTime(now.year, now.month);
    bool thisMonth(DateTime? d) => d != null && !d.isBefore(first);
    final inProgress = apps.where((a) => a.inProgress).length;
    final offers = apps.where((a) => thisMonth(a.offerDate)).length;
    final coes = apps.where((a) => thisMonth(a.coeDate)).length;
    final waiting = [
      for (final a in apps)
        if (a.offerOverdue(today)) (a, a.offerWaitDays(today)!),
    ]..sort((x, y) => y.$2.compareTo(x.$2));
    void open() => ref.read(appActionsProvider).selectTab(AppTab.applications);
    return AppPanel(
      key: const ValueKey('overview-applications'),
      title: 'Application pipeline',
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
        child: apps.isEmpty
            ? Text(
                'No applications yet. They come from the Airtable tracker '
                '(Applications page).',
                style: theme.textTheme.bodyMedium?.copyWith(color: c.textMuted),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FigureStat(
                          label: 'In progress',
                          value: '$inProgress',
                        ),
                      ),
                      Expanded(
                        child: FigureStat(
                          label: 'Offers',
                          value: '$offers',
                          caption: 'this month',
                        ),
                      ),
                      Expanded(
                        child: FigureStat(
                          label: 'COEs',
                          value: '$coes',
                          caption: 'this month',
                        ),
                      ),
                    ],
                  ),
                  if (waiting.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'WAITING FOR AN OFFER LETTER · ${waiting.length}',
                      style: microLabel(theme),
                    ),
                    for (final (a, days) in waiting.take(4))
                      InkWell(
                        key: ValueKey('overview-offer-${a.key}'),
                        onTap: () => showApplicationDetails(context, ref, a),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  a.student,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                              if (a.assignee.isNotEmpty) ...[
                                TagChip(
                                  a.assignee,
                                  AirtableTags.assignee(a.assignee),
                                  dense: true,
                                ),
                                const SizedBox(width: 8),
                              ],
                              Text(
                                '$days d',
                                style: Dt.tab(theme.textTheme.bodySmall!)
                                    .copyWith(
                                      color: days > 21
                                          ? c.negativeFg
                                          : c.warningFg,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// This month so far against the same days of last month (Reports).
class _MonthPanel extends ConsumerWidget {
  const _MonthPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final first = DateTime(now.year, now.month);
    final lastFirst = DateTime(now.year, now.month - 1);
    final lastSame = DateTime(
      lastFirst.year,
      lastFirst.month,
      now.day.clamp(1, DateTime(now.year, now.month, 0).day),
    );
    final cur = ref.watch(reportProvider((first, today)));
    final prev = ref.watch(reportProvider((lastFirst, lastSame)));
    final rows = [
      ('New clients', cur.newClients, prev.newClients),
      ('Existing clients', cur.existingClients, prev.existingClients),
      ('Total', cur.total, prev.total),
    ];
    return AppPanel(
      key: const ValueKey('overview-month'),
      title: '${DateFormat('MMMM').format(now)} so far',
      subtitle:
          'Against ${DateFormat('MMMM').format(lastFirst)} 1–${lastSame.day}',
      trailingWidget: TextButton(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 28),
        ),
        onPressed: () => ref.read(appActionsProvider).selectTab(AppTab.reports),
        child: const Text('Reports'),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(
          children: [
            for (final (label, n, before) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: label == 'Total' ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                    Text(
                      '$n',
                      style: Dt.tab(theme.textTheme.titleSmall!)
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(
                      width: 72,
                      child: Text(
                        n == before
                            ? 'same'
                            : n > before
                            ? '+${n - before}'
                            : '−${before - n}',
                        textAlign: TextAlign.right,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: n > before
                              ? c.positiveFg
                              : n < before
                              ? c.negativeFg
                              : c.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              // The daily average is on the Month card above; not again here.
              child: Text(
                '${cur.staffedDaysSoFar} working '
                '${cur.staffedDaysSoFar == 1 ? 'day' : 'days'} so far',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: c.textMuted),
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
