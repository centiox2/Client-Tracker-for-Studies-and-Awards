import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/client_count_repository.dart';
import '../../design/airtable_tags.dart';
import '../../repositories/revenue_repository.dart' show formatMoney;
import '../../services/todo_service.dart';
import '../../services/ai_summary_service.dart';
import '../../state/app_state.dart';
import '../../state/mobile_navigation.dart';
import '../../widgets/app_page_header.dart';
import '../../widgets/clarity.dart';
import '../../widgets/panels.dart';
import '../../widgets/card_board.dart';
import '../ai_summary/ai_summary_screen.dart';
import '../applications/applications_screen.dart' show showApplicationDetails;

/// The familiar client graphs, with the four requested business areas.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = ref.watch(availableAppTabsProvider);
    final tracker = allowed.contains(AppTab.week);
    final data = tracker ? ref.watch(currentWeekProvider) : null;
    final previous = tracker ? ref.watch(previousWeekTotalsProvider) : null;
    final totals = data?.totals;
    final now = DateTime.now();
    final isCurrent = data == null || data.dayFor(now) != null;
    final unit = isCurrent
        ? 'this week'
        : 'week of ${DateFormat('d MMM').format(data.week.startDate)}';
    final width = MediaQuery.sizeOf(context).width;
    void open(AppTab tab) => ref.read(appActionsProvider).selectTab(tab);
    KpiCard metric(String label, int? value, int? before, {String? average}) {
      final (caption, tone) = value == null || before == null
          ? (null, DeltaTone.neutral)
          : deltaVsLast(value, before);
      return KpiCard(
        label: label,
        value: value == null ? '—' : '$value',
        unit: average ?? unit,
        caption: caption,
        tone: tone,
        onTap: () => open(AppTab.week),
      );
    }

    final cards = <BoardCard>[
      if (tracker)
        BoardCard(
          'week',
          _ThisWeek(
            key: const ValueKey('overview-week'),
            data: data,
            isCurrent: isCurrent,
          ),
        ),
      if (allowed.contains(AppTab.revenue))
        const BoardCard('revenue', _RevenuePanel(), column: 1),
      if (allowed.contains(AppTab.applications))
        const BoardCard('applications', _ApplicationsPanel(), column: 2),
      if (allowed.contains(AppTab.todo))
        const BoardCard('todo', _TodoPanel(), column: 1),
      if (tracker) BoardCard('mix', _MixPanel(data: data, unit: unit)),
      if (summaryAccessGranted(ref.watch(aiSummaryAccessProvider)))
        const BoardCard('ai', AiSummaryPreview(bottomPadding: 0), column: 2),
    ];
    return SingleChildScrollView(
      key: const ValueKey('overview-page'),
      padding: clarityPagePadding(width),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Dt.contentMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppPageHeader(
                tab: AppTab.home,
                actions: [
                  if (tracker)
                    WeekRangeButton(canStart: ref.watch(canEditProvider)),
                ],
              ),
              const SizedBox(height: 24),
              KpiGrid(
                orderKey: 'overview',
                minWidth: width < 640 ? 150 : 190,
                children: [
                  if (tracker) ...[
                    metric(
                      'New clients',
                      totals?.newClients,
                      previous?.newClients,
                    ),
                    metric(
                      'Existing clients',
                      totals?.existingClients,
                      previous?.existingClients,
                    ),
                    metric(
                      'Total clients',
                      totals?.total,
                      previous?.total,
                      average: totals == null
                          ? null
                          : _formatAverage(totals.dailyAverage),
                    ),
                  ],
                  if (allowed.contains(AppTab.staff))
                    KpiCard(
                      key: const ValueKey('overview-staff'),
                      label: 'Active staff',
                      value:
                          '${ref.watch(staffListProvider).where((s) => s.active).length}',
                      unit: 'team',
                      onTap: () => open(AppTab.staff),
                    ),
                ],
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

String _formatAverage(double avg) {
  final rounded = (avg * 10).round() / 10;
  return '${rounded == rounded.roundToDouble() ? rounded.toStringAsFixed(0) : rounded.toStringAsFixed(1)} / day';
}

class _ThisWeek extends ConsumerWidget {
  const _ThisWeek({super.key, required this.data, required this.isCurrent});
  final CurrentWeekData? data;
  final bool isCurrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final data = this.data;
    final open = IconButton(
      key: const ValueKey('overview-open-week'),
      tooltip: 'Open Weekly tracker',
      onPressed: () => ref.read(appActionsProvider).selectTab(AppTab.week),
      icon: const Icon(Icons.arrow_forward, size: 18),
    );
    if (data == null) {
      return AppPanel(
        title: 'This week',
        compactHeader: true,
        trailingWidget: open,
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
      trailingWidget: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        children: [if (!phone) const NewExistingLegend(), open],
      ),
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
        key: const ValueKey('overview-open-revenue'),
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
    // The same rule as the Applications page: this calendar month only.
    bool thisMonth(DateTime? d) =>
        d != null && d.year == now.year && d.month == now.month;
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
        key: const ValueKey('overview-open-applications'),
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

class _TodoPanel extends ConsumerWidget {
  const _TodoPanel();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref
        .watch(todoListProvider)
        .where((t) => !t.deleted && !t.archived)
        .toList();
    final loaded = ref.read(todoListProvider.notifier).loaded;
    final open = items.where((t) => !t.done).toList()
      ..sort((a, b) {
        final overdue = (b.overdue ? 1 : 0).compareTo(a.overdue ? 1 : 0);
        if (overdue != 0) return overdue;
        final starred = (b.starred ? 1 : 0).compareTo(a.starred ? 1 : 0);
        if (starred != 0) return starred;
        return (a.planned ?? DateTime(9999)).compareTo(
          b.planned ?? DateTime(9999),
        );
      });
    void showList() => ref.read(appActionsProvider).selectTab(AppTab.todo);
    final theme = Theme.of(context);
    Widget list(String title, List<TodoItem> tasks) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$title · ${tasks.length}', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        if (tasks.isEmpty) const Text('No open items.'),
        for (final item in tasks.take(5))
          InkWell(
            onTap: showList,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.radio_button_unchecked, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.title, style: theme.textTheme.bodyMedium),
                        if (item.overdue || item.planned != null)
                          Text(
                            item.overdue
                                ? 'Overdue'
                                : 'Planned ${DateFormat('d MMM').format(item.planned!)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: item.overdue
                                  ? context.clarity.warningFg
                                  : context.clarity.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (tasks.length > 5)
          TextButton(
            onPressed: showList,
            child: Text('View ${tasks.length - 5} more'),
          ),
      ],
    );
    final personal = open.where((t) => !t.team).toList();
    final team = open.where((t) => t.team).toList();
    return InkWell(
      onTap: showList,
      child: AppPanel(
        key: const ValueKey('overview-todo'),
        title: 'To-do',
        compactHeader: true,
        trailingWidget: IconButton(
          key: const ValueKey('overview-open-todo'),
          tooltip: 'Open your to-do list',
          onPressed: showList,
          icon: const Icon(Icons.arrow_forward, size: 18),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: !loaded
              ? const Text('Loading your list…')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    list('Your list', personal),
                    if (team.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      list(
                        ref.read(todoListProvider.notifier).teamName ??
                            'Team list',
                        team,
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      '${items.where((t) => t.done).length} completed',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
