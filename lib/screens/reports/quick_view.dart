part of 'reports_screen.dart';

/// "What's going on right now": today's numbers against the same day last
/// week, who is seeing clients, who hasn't yet and who's off, the week so
/// far, and the latest updates. Today means the last weekday at weekends.
class _QuickView extends ConsumerWidget {
  const _QuickView({super.key, required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final day = _lastWeekday(DateTime.now());
    final isToday = _sameDay(day, DateTime.now());
    final monday = day.subtract(Duration(days: day.weekday - 1));
    final lastWeekDay = day.subtract(const Duration(days: 7));
    final firstOfMonth = DateTime(day.year, day.month, 1);

    final today = ref.watch(reportProvider((day, day)));
    final sameDayLastWeek = ref.watch(
      reportProvider((lastWeekDay, lastWeekDay)),
    );
    final week = ref.watch(
      reportProvider((monday, monday.add(const Duration(days: 4)))),
    );
    final weekSoFar = ref.watch(reportProvider((monday, day)));
    final lastWeekSoFar = ref.watch(
      reportProvider((monday.subtract(const Duration(days: 7)), lastWeekDay)),
    );
    final monthSoFar = ref.watch(reportProvider((firstOfMonth, day)));

    final dayName = isToday ? 'today' : DateFormat('EEEE').format(day);
    final lastSameDay = 'last ${DateFormat('EEEE').format(day)}';
    final tracked = today.days.isNotEmpty;
    final holiday = tracked && today.days.first.isHoliday;

    final target = ref.watch(dailyTargetProvider);
    // A tile footer: the comparison line and/or progress toward the target.
    Widget? footer(Widget? delta, double? goal, int value) {
      final bar = goal == null || goal <= 0
          ? null
          : _TargetBar(value: value.toDouble(), target: goal);
      if (delta == null && bar == null) return null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [?delta, ?bar],
      );
    }

    final tiles = <Widget>[
      _Tile(
        label: isToday ? 'Clients today' : 'Clients on $dayName',
        value: '${today.total}',
        caption: target == null ? 'New + existing' : 'Target $target',
        footer: footer(
          sameDayLastWeek.days.isEmpty
              ? null
              : _Delta(
                  current: today.total,
                  previous: sameDayLastWeek.total,
                  against: lastSameDay,
                ),
          holiday ? null : target?.toDouble(),
          today.total,
        ),
      ),
      _Tile(
        label: 'New',
        value: '${today.newClients}',
        caption: isToday ? 'Today' : dayName,
        color: Dt.newGreen(theme.brightness),
      ),
      _Tile(
        label: 'Existing',
        value: '${today.existingClients}',
        caption: isToday ? 'Today' : dayName,
        color: Dt.existingBlue(theme.brightness),
      ),
      _Tile(
        label: 'This week so far',
        value: '${weekSoFar.total}',
        caption: '${_avg(weekSoFar.dailyAverage)} / day avg',
        footer: footer(
          lastWeekSoFar.days.isEmpty
              ? null
              : _Delta(
                  current: weekSoFar.total,
                  previous: lastWeekSoFar.total,
                  against: 'last week',
                ),
          // The target scales with the working days so far this week.
          target == null ? null : target * weekSoFar.staffedDaysSoFar * 1.0,
          weekSoFar.total,
        ),
      ),
      _Tile(
        label: '${DateFormat('MMMM').format(day)} so far',
        value: '${monthSoFar.total}',
        caption: '${_avg(monthSoFar.dailyAverage)} / day avg',
      ),
    ];

    final whoPanel = _Panel(
      title: isToday ? 'Who’s seeing clients today' : 'Clients on $dayName',
      icon: Icons.person_search_outlined,
      trailing: tracked && !holiday
          ? '${today.staffWithClients} of '
                '${today.staff.where((s) => s.daysOff == 0).length} working'
          : null,
      child: !tracked
          ? const _Empty(period: ReportPeriod.day)
          : holiday
          ? const _Note('Holiday — the whole team is off.')
          : _WhoToday(report: today),
    );

    final weekPanel = _Panel(
      title: 'This week',
      icon: Icons.bar_chart,
      trailingWidget: const _Legend(),
      child: week.days.isEmpty
          ? const _Empty(period: ReportPeriod.week)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DayBars(days: week.days, height: 170),
                _WeekFacts(week: week),
              ],
            ),
    );

    final activityPanel = _Panel(
      title: 'Latest updates',
      icon: Icons.history_toggle_off,
      child: _Activity(entries: week.activity.take(8).toList()),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LiveHeader(day: day, isToday: isToday, latest: week.activity),
        if (today.days.firstOrNull?.note case final note?) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.sticky_note_2_outlined,
                size: 14,
                color: Dt.textMuted(theme),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  note,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Dt.textMuted(theme),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final perRow = compact ? 2 : tiles.length;
            final w = ((c.maxWidth - 10 * (perRow - 1)) / perRow).clamp(
              0.0,
              double.infinity,
            );
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [for (final t in tiles) SizedBox(width: w, child: t)],
            );
          },
        ),
        const SizedBox(height: 12),
        if (compact) ...[
          whoPanel,
          const SizedBox(height: 12),
          weekPanel,
          const SizedBox(height: 12),
          activityPanel,
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: whoPanel),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: Column(
                  children: [
                    weekPanel,
                    const SizedBox(height: 12),
                    activityPanel,
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  static String _avg(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

/// "● Live · Tuesday 13 October · last update 15:49 by Joy".
class _LiveHeader extends StatelessWidget {
  const _LiveHeader({
    required this.day,
    required this.isToday,
    required this.latest,
  });

  final DateTime day;
  final bool isToday;
  final List<ReportActivity> latest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final last = latest.firstOrNull;
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (isToday)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LiveDot(
                color: Dt.statusGreen(theme.brightness),
                // A ring each time a new number comes in.
                pingKey: last?.updatedAt,
              ),
              const SizedBox(width: 6),
              Text(
                'Live',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        Text(
          DateFormat('EEEE d MMMM').format(day),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (last != null)
          Text(
            'Last update ${_Toolbar._relative(last.updatedAt)} · '
            '${last.staffName}',
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
      ],
    );
  }
}

/// Everyone working today, most clients first, then who hasn't logged a
/// client yet and who's off.
class _WhoToday extends StatelessWidget {
  const _WhoToday({required this.report});

  final Report report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seen = report.staff.where((s) => s.total > 0).toList();
    final notYet = report.staff
        .where((s) => s.total == 0 && s.daysOff == 0)
        .toList();
    final off = report.staff.where((s) => s.daysOff > 0).toList();
    final top = seen.isEmpty ? 0 : seen.first.total;
    final head = _headStyle(theme);
    const widths = [44.0, 60.0, 44.0];

    String names(List<ReportStaff> list) => list.map((s) => s.name).join(', ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (seen.isEmpty)
          const _Note('No clients logged yet.')
        else ...[
          _Row(
            header: true,
            widths: widths,
            cells: [
              Text('Staff', style: head),
              Text('New', style: head),
              Text('Existing', style: head),
              Text('Total', style: head),
            ],
          ),
          for (var i = 0; i < seen.length; i++)
            _Row(
              last: i == seen.length - 1 && notYet.isEmpty && off.isEmpty,
              widths: widths,
              onTap: () => showStaffProfile(context, seen[i].staffId),
              cells: [
                Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        seen[i].name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: _Bar(fraction: seen[i].total / top),
                      ),
                    ),
                  ],
                ),
                _count(
                  theme,
                  seen[i].newClients,
                  color: Dt.newGreen(theme.brightness),
                ),
                _count(
                  theme,
                  seen[i].existingClients,
                  color: Dt.existingBlue(theme.brightness),
                ),
                _count(theme, seen[i].total, bold: true),
              ],
            ),
        ],
        if (notYet.isNotEmpty)
          _NameGroup(
            label: 'No clients yet',
            names: names(notYet),
            last: off.isEmpty,
          ),
        if (off.isNotEmpty) _NameGroup(label: 'Off', names: names(off)),
      ],
    );
  }
}

class _NameGroup extends StatelessWidget {
  const _NameGroup({
    required this.label,
    required this.names,
    this.last = true,
  });

  final String label;
  final String names;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label, style: _headStyle(theme))),
          Expanded(
            child: Text(
              names,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Dt.textMuted(theme),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Plain horizontal bar scaled to the day's top performer.
class _Bar extends StatelessWidget {
  const _Bar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Stack(
          children: [
            Container(color: scheme.onSurface.withValues(alpha: 0.08)),
            AnimatedFraction(
              fraction: fraction,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
          ],
        ),
      ),
    );
  }
}

/// Busiest day and top person of the week, under the chart.
class _WeekFacts extends StatelessWidget {
  const _WeekFacts({required this.week});
  final Report week;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busiest = week.days.fold<ReportDay?>(
      null,
      (b, d) => d.total > (b?.total ?? 0) ? d : b,
    );
    final topStaff = week.staff.firstOrNull;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final strong = style?.copyWith(
      color: theme.colorScheme.onSurface,
      fontWeight: FontWeight.w600,
    );
    if (busiest == null) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Busiest day  '),
                TextSpan(
                  text:
                      '${DateFormat('EEEE').format(busiest.date)} '
                      '(${busiest.total})',
                  style: strong,
                ),
              ],
            ),
            style: style,
          ),
          if (topStaff != null && topStaff.total > 0)
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Most clients  '),
                  TextSpan(
                    text: '${topStaff.name} (${topStaff.total})',
                    style: strong,
                  ),
                ],
              ),
              style: style,
            ),
        ],
      ),
    );
  }
}

/// The most recently changed tallies this week.
class _Activity extends StatelessWidget {
  const _Activity({required this.entries});
  final List<ReportActivity> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (entries.isEmpty) return const _Note('No numbers entered this week.');
    final now = DateTime.now();
    return Column(
      children: [
        for (var i = 0; i < entries.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              border: i == entries.length - 1
                  ? null
                  : Border(
                      bottom: BorderSide(
                        color: theme.colorScheme.outline.withValues(alpha: 0.6),
                      ),
                    ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 74,
                  child: Text(
                    _sameDay(entries[i].updatedAt, now)
                        ? DateFormat('HH:mm').format(entries[i].updatedAt)
                        : DateFormat('EEE HH:mm').format(entries[i].updatedAt),
                    style: _num(theme, color: Dt.textMuted(theme)),
                  ),
                ),
                Expanded(
                  child: Text(
                    entries[i].staffName,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    '${entries[i].newClients} new · '
                    '${entries[i].existingClients} existing'
                    '${_sameDay(entries[i].date, now) ? '' : ' (${DateFormat('EEE').format(entries[i].date)})'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
