import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/client_count_repository.dart';
import '../../services/export_actions.dart';
import '../../state/app_state.dart';
import '../../widgets/motion.dart';

/// Cloud dashboard style overview for the client tracker.
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final week = data?.totals;
    final previous = ref.watch(previousWeekTotalsProvider);
    final suggestedWeek = ref.watch(suggestedWeekStartProvider);
    final weekDays = data?.days ?? const <DayWithCounts>[];
    // "This week" only when the selected week really is the current one;
    // after picking an older week the cards say which week they show.
    final weekCaption = data == null || data.dayFor(DateTime.now()) != null
        ? 'This week'
        : 'Week of ${DateFormat('MMM d').format(data.week.startDate)}';

    final metrics = <_MetricData>[
      _MetricData(
        'New clients',
        '${week?.newClients ?? 0}',
        weekCaption,
        Dt.newGreen(theme.brightness),
        Icons.person_add_alt_1_outlined,
        current: week?.newClients,
        previous: previous?.newClients,
      ),
      _MetricData(
        'Existing clients',
        '${week?.existingClients ?? 0}',
        weekCaption,
        Dt.existingBlue(theme.brightness),
        Icons.people_outline,
        current: week?.existingClients,
        previous: previous?.existingClients,
      ),
      _MetricData(
        'Total clients',
        '${week?.total ?? 0}',
        weekCaption,
        scheme.onSurface,
        Icons.groups_outlined,
        current: week?.total,
        previous: previous?.total,
        average: week?.dailyAverage,
      ),
      _MetricData(
        'Clients this month',
        '${month.total}',
        DateFormat('MMMM y').format(DateTime.now()),
        scheme.onSurface,
        Icons.calendar_month_outlined,
        average: month.dailyAverage,
      ),
      _MetricData(
        'Active staff',
        '$staff',
        'Current team',
        Dt.statusGreen(theme.brightness),
        Icons.badge_outlined,
      ),
    ];

    return LayoutBuilder(
      builder: (context, viewport) {
        final compact = viewport.maxWidth < 900;
        final compactHeight = viewport.maxHeight < 800;
        final pagePadding = compact ? 14.0 : 18.0;
        final verticalPadding = compactHeight ? 14.0 : 28.0;
        final sectionGap = compactHeight ? 8.0 : 12.0;
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: pagePadding,
            vertical: verticalPadding,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: Dt.contentMaxWidth,
                // Center compact dashboards in the available body while
                // allowing longer dashboards to scroll with equal top/bottom
                // breathing room.
                minHeight: (viewport.maxHeight - verticalPadding * 2).clamp(
                  0.0,
                  double.infinity,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (ref.watch(backupDueProvider)) ...[
                    const _BackupBanner(),
                    SizedBox(height: sectionGap),
                  ],
                  if (suggestedWeek != null) ...[
                    _StartWeekBanner(monday: suggestedWeek),
                    SizedBox(height: sectionGap),
                  ],
                  LayoutBuilder(
                    builder: (context, metricConstraints) {
                      final metricsCompact = metricConstraints.maxWidth < 900;
                      // Clamped: a window resized to near-zero width (or a
                      // browser tab laid out while hidden) must not produce
                      // negative constraints and take the whole page down.
                      final tileWidth =
                          (metricsCompact
                                  ? (metricConstraints.maxWidth - 10) / 2
                                  : (metricConstraints.maxWidth - 40) / 5)
                              .clamp(0.0, double.infinity);
                      return Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final item in metrics)
                            SizedBox(
                              width: tileWidth,
                              child: _MetricTile(data: item),
                            ),
                        ],
                      );
                    },
                  ),
                  SizedBox(height: sectionGap),
                  _Panel(
                    title: 'Active week',
                    icon: Icons.calendar_month_outlined,
                    trailing: Text(
                      data == null
                          ? 'No week started'
                          : '${DateFormat('MMM d').format(data.week.startDate)} – ${DateFormat('MMM d, y').format(data.week.endDate)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    child: data == null
                        ? const _EmptyPanelMessage(
                            'Create a new week to start tracking clients.',
                          )
                        : _WeekTable(days: weekDays),
                  ),
                  SizedBox(height: sectionGap),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 760;
                      final trend = _Panel(
                        title: 'Client volume by day',
                        icon: Icons.bar_chart,
                        trailing: _Legend(),
                        child: _WeekTrend(days: weekDays),
                      );
                      final staffPanel = _Panel(
                        title: 'Staff performance',
                        icon: Icons.groups_outlined,
                        trailing: Text(
                          _staffPanelCaption(data),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        child: _StaffPerformance(
                          rows: data?.staffTotals ?? const <StaffWeekTotals>[],
                        ),
                      );
                      if (wide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: trend),
                            const SizedBox(width: 12),
                            Expanded(child: staffPanel),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          trend,
                          const SizedBox(height: 12),
                          staffPanel,
                        ],
                      );
                    },
                  ),
                  SizedBox(height: sectionGap),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 760;
                      final recent = _Panel(
                        title: 'Recent weeks',
                        icon: Icons.history,
                        trailing: TextButton(
                          onPressed: () => ref
                              .read(appActionsProvider)
                              .selectTab(AppTab.history),
                          child: const Text('View history'),
                        ),
                        child: history.isEmpty
                            ? const _EmptyPanelMessage(
                                'Weekly summaries will appear here.',
                              )
                            : Column(
                                children: [
                                  for (final item in history.take(4))
                                    _HistoryRow(summary: item),
                                ],
                              ),
                      );
                      final quick = _Panel(
                        title: 'Quick actions',
                        icon: Icons.bolt_outlined,
                        child: Column(
                          children: [
                            _QuickAction(
                              icon: Icons.edit_note,
                              title: 'Enter client numbers',
                              subtitle: 'Open the weekly tracker',
                              onTap: () => ref
                                  .read(appActionsProvider)
                                  .selectTab(AppTab.week),
                            ),
                            _QuickAction(
                              icon: Icons.person_add_alt,
                              title: 'Manage your team',
                              subtitle: 'Add or update staff',
                              onTap: () => ref
                                  .read(appActionsProvider)
                                  .selectTab(AppTab.staff),
                            ),
                            _QuickAction(
                              icon: Icons.download_outlined,
                              title: 'Export this week',
                              subtitle: data == null
                                  ? 'Create a week before exporting'
                                  : 'Download an Excel summary',
                              onTap: data == null
                                  ? () => ref
                                        .read(appActionsProvider)
                                        .selectTab(AppTab.week)
                                  : () => exportWeekToFile(
                                      context,
                                      ref,
                                      data.week,
                                    ),
                            ),
                          ],
                        ),
                      );
                      if (wide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: recent),
                            const SizedBox(width: 12),
                            Expanded(child: quick),
                          ],
                        );
                      }
                      return Column(
                        children: [recent, const SizedBox(height: 12), quick],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "3 of 14 staff" once numbers exist — never "0 team members" next to an
/// Active staff card that says 14.
String _staffPanelCaption(CurrentWeekData? data) {
  if (data == null) return 'No week selected';
  final withEntries = data.staffTotals.where((s) => s.total > 0).length;
  if (withEntries == 0) return 'No entries yet';
  return '$withEntries of ${data.staffTotals.length} staff';
}

class _MetricData {
  const _MetricData(
    this.label,
    this.value,
    this.caption,
    this.color,
    this.icon, {
    this.current,
    this.previous,
    this.average,
  });
  final String label;
  final String value;
  final String caption;
  final Color color;
  final IconData icon;

  /// When both are set the tile shows the change versus the previous week.
  final int? current;
  final int? previous;

  /// Clients per working day so far, shown beside the value when set.
  final double? average;
}

/// "14 / day avg", or "14.5 / day avg" when the average isn't whole.
String _formatAverage(double avg) {
  final rounded = (avg * 10).round() / 10;
  final text = rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(1);
  return '$text / day avg';
}

/// One-click start for the current week (next week at weekends), shown only
/// while that week hasn't been created.
class _StartWeekBanner extends ConsumerWidget {
  const _StartWeekBanner({required this.monday});
  final DateTime monday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = DateFormat('MMMM d').format(monday);
    final staff = ref.watch(staffListProvider).where((s) => s.active).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Row(
        children: [
          Icon(
            Icons.event_available_outlined,
            size: 18,
            color: scheme.onSurface,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The week of $label hasn’t been started',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Creates Monday–Friday with your $staff active staff.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
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

/// "▲ 4 vs last week" under a metric. Muted on purpose: colour in this app
/// is reserved for the New/Existing data pair.
class _DeltaLabel extends StatelessWidget {
  const _DeltaLabel({
    required this.current,
    required this.previous,
    this.maxLines = 1,
  });
  final int current;
  final int previous;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diff = current - previous;
    final IconData icon;
    final String text;
    if (diff == 0) {
      icon = Icons.remove;
      text = 'Same as last week';
    } else {
      icon = diff > 0 ? Icons.arrow_drop_up : Icons.arrow_drop_down;
      final pct = previous == 0
          ? ''
          : ' (${(diff.abs() * 100 / previous).round()}%)';
      text = '${diff.abs()}$pct vs last week';
    }
    final style = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: diff == 0 ? 11 : 15, color: style?.color),
        Flexible(
          child: Text(
            text,
            style: style,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.data});
  final _MetricData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compactHeight = MediaQuery.sizeOf(context).height < 920;
    final phone = MediaQuery.sizeOf(context).width < 600;
    final delta = data.current != null && data.previous != null
        ? _DeltaLabel(
            current: data.current!,
            previous: data.previous!,
            maxLines: phone ? 2 : 1,
          )
        : null;
    final captionStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10,
      color: scheme.onSurfaceVariant,
    );
    return Container(
      height: phone ? null : (compactHeight ? 100 : 108),
      constraints: phone ? const BoxConstraints(minHeight: 112) : null,
      padding: EdgeInsets.all(compactHeight ? Dt.s12 : Dt.s16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(data.icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  data.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (phone) const SizedBox(height: 8) else const Spacer(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AnimatedValueText(
                data.value,
                style: Dt.tab(theme.textTheme.headlineSmall!)
                    .copyWith(fontWeight: FontWeight.w700, color: data.color),
              ),
              if (data.average != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      _formatAverage(data.average!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Dt.tab(theme.textTheme.labelSmall!)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          if (phone) ...[
            Text(data.caption, style: captionStyle),
            if (delta != null) ...[const SizedBox(height: 2), delta],
          ] else
            Row(
              children: [
                Text(data.caption, style: captionStyle),
                if (delta != null) ...[
                  Text('  ·  ', style: captionStyle),
                  Flexible(child: delta),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compactHeight = MediaQuery.sizeOf(context).height < 920;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: compactHeight ? 38 : 42,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Dt.s12),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
          Divider(height: 1, color: scheme.outline),
          Padding(
            padding: EdgeInsets.all(compactHeight ? Dt.s8 : Dt.s12),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _WeekTable extends StatelessWidget {
  const _WeekTable({required this.days});
  final List<DayWithCounts> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontSize: 10,
      fontWeight: FontWeight.w600,
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 7),
          child: Row(
            children: [
              Expanded(flex: 4, child: Text('WORK DAY', style: labelStyle)),
              Expanded(
                child: Text(
                  'NEW',
                  textAlign: TextAlign.right,
                  style: labelStyle,
                ),
              ),
              Expanded(
                child: Text(
                  MediaQuery.sizeOf(context).width < 600
                      ? 'EXIST.'
                      : 'EXISTING',
                  maxLines: 1,
                  textAlign: TextAlign.right,
                  style: labelStyle,
                ),
              ),
              Expanded(
                child: Text(
                  'TOTAL',
                  textAlign: TextAlign.right,
                  style: labelStyle,
                ),
              ),
            ],
          ),
        ),
        for (final day in days) ...[
          Divider(height: 1, color: scheme.outline.withValues(alpha: 0.7)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 6,
                        color: day.workingRows.any((r) => r.total > 0)
                            ? Dt.statusGreen(theme.brightness)
                            : scheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        DateFormat('EEE, MMM d').format(day.day.date),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Text(
                    '${_dayTotal(day).newClients}',
                    textAlign: TextAlign.right,
                    style: _numberStyle(theme, Dt.newGreen(theme.brightness)),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${_dayTotal(day).existingClients}',
                    textAlign: TextAlign.right,
                    style: _numberStyle(
                      theme,
                      Dt.existingBlue(theme.brightness),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${_dayTotal(day).total}',
                    textAlign: TextAlign.right,
                    style: _numberStyle(theme, scheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (days.isEmpty)
          const _EmptyPanelMessage('No daily totals are available yet.'),
      ],
    );
  }
}

DayTotals _dayTotal(DayWithCounts day) => DayTotals(
  newClients: day.workingRows.fold<int>(0, (sum, row) => sum + row.newClients),
  existingClients: day.workingRows.fold<int>(
    0,
    (sum, row) => sum + row.existingClients,
  ),
);

TextStyle _numberStyle(ThemeData theme, Color color) =>
    theme.textTheme.bodySmall!.copyWith(
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
      fontWeight: FontWeight.w500,
    );

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _LegendDot(
        color: Dt.newGreen(Theme.of(context).brightness),
        label: 'New',
      ),
      const SizedBox(width: 10),
      _LegendDot(
        color: Dt.existingBlue(Theme.of(context).brightness),
        label: 'Existing',
      ),
    ],
  );
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 10,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class _WeekTrend extends StatelessWidget {
  const _WeekTrend({required this.days});
  final List<DayWithCounts> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compactHeight = MediaQuery.sizeOf(context).height < 920;
    if (days.isEmpty) {
      return SizedBox(
        height: compactHeight ? 160 : 210,
        child: const _EmptyPanelMessage('Start a week to see the daily trend.'),
      );
    }
    final totals = days.map(_dayTotal).toList();
    final maxValue = totals.fold<int>(
      1,
      (max, value) => value.total > max ? value.total : max,
    );
    return SizedBox(
      height: 210,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 30,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final value in [
                  maxValue,
                  (maxValue * .66).round(),
                  (maxValue * .33).round(),
                  0,
                ])
                  Text(
                    '$value',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < totals.length; i++)
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '${totals[i].total}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 5),
                        SizedBox(
                          height: 144,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: SizedBox(
                              width: 28,
                              height: (144 * totals[i].total / maxValue).clamp(
                                2.0,
                                144.0,
                              ),
                              child: Column(
                                children: [
                                  if (totals[i].existingClients > 0)
                                    Expanded(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Dt.existingBlue(
                                            theme.brightness,
                                          ),
                                          borderRadius:
                                              const BorderRadius.vertical(
                                                top: Radius.circular(3),
                                              ),
                                        ),
                                        child: const SizedBox.expand(),
                                      ),
                                    ),
                                  if (totals[i].newClients > 0)
                                    Expanded(
                                      child: ColoredBox(
                                        color: Dt.newGreen(theme.brightness),
                                        child: const SizedBox.expand(),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          DateFormat('EEE').format(days[i].day.date),
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StaffPerformance extends StatelessWidget {
  const _StaffPerformance({required this.rows});
  final List<StaffWeekTotals> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compactHeight = MediaQuery.sizeOf(context).height < 920;
    if (rows.isEmpty) {
      return SizedBox(
        height: compactHeight ? 160 : 210,
        child: const _EmptyPanelMessage(
          'Staff totals appear here once numbers are entered.',
        ),
      );
    }
    final topRows = rows.toList()..sort((a, b) => b.total.compareTo(a.total));
    final maxValue = topRows.first.total.clamp(1, 1 << 30);
    return Column(
      children: [
        for (final row in topRows.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  child: Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 7,
                      child: Row(
                        children: [
                          Expanded(
                            flex: (row.newClients * 1000 ~/ maxValue).clamp(
                              1,
                              1000,
                            ),
                            child: ColoredBox(
                              color: Dt.newGreen(theme.brightness),
                            ),
                          ),
                          if (row.existingClients > 0)
                            Expanded(
                              flex: (row.existingClients * 1000 ~/ maxValue)
                                  .clamp(1, 1000),
                              child: ColoredBox(
                                color: Dt.existingBlue(theme.brightness),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 30,
                  child: Text(
                    '${row.total}',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${rows.length} team members',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.summary});
  final WeekSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.calendar_today_outlined,
            size: 14,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '${DateFormat('MMM d').format(summary.week.startDate)} – ${DateFormat('MMM d, y').format(summary.week.endDate)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Text(
            '${summary.totals.total} clients',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compactHeight = MediaQuery.sizeOf(context).height < 920;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Dt.rSm),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compactHeight ? 4 : 8),
        child: Row(
          children: [
            Container(
              width: 29,
              height: 29,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(Dt.rSm),
              ),
              child: Icon(icon, size: 15, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 17, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _EmptyPanelMessage extends StatelessWidget {
  const _EmptyPanelMessage(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height < 920 ? 60 : 80,
    child: Center(
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}

/// Gentle nudge to save a backup file when none has been saved on this
/// device for a week. The data lives only here, so a copy elsewhere (USB,
/// email, cloud drive) is what protects it.
class _BackupBanner extends ConsumerWidget {
  const _BackupBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final last = ref.watch(lastBackupProvider);
    final days = last == null ? null : DateTime.now().difference(last).inDays;
    final phone = MediaQuery.sizeOf(context).width < 600;
    final button = OutlinedButton.icon(
      onPressed: () => backupToFile(context, ref),
      icon: const Icon(Icons.download_outlined, size: 16),
      label: const Text('Back up now'),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Row(
        crossAxisAlignment: phone
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Icon(Icons.backup_outlined, size: 18, color: scheme.onSurface),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  days == null
                      ? 'No backup saved yet'
                      : 'Last backup was $days days ago',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Your numbers are stored only on this device. Save a copy '
                  'somewhere else, like a USB stick or email.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (phone) ...[const SizedBox(height: 8), button],
              ],
            ),
          ),
          if (!phone) ...[const SizedBox(width: 12), button],
        ],
      ),
    );
  }
}
