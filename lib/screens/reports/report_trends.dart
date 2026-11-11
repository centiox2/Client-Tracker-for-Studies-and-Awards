part of 'reports_screen.dart';

/// How far back Trends looks.
enum _TrendRange { months3, months6, months12, all }

/// The longer view: which weekdays are busiest, month by month, and who is
/// up or down over the last four weeks.
class _TrendsView extends ConsumerStatefulWidget {
  const _TrendsView({super.key, required this.compact});

  final bool compact;

  @override
  ConsumerState<_TrendsView> createState() => _TrendsViewState();
}

class _TrendsViewState extends ConsumerState<_TrendsView> {
  _TrendRange _range = _TrendRange.months6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final first = ref.watch(firstTrackedDayProvider) ?? today;
    DateTime monthsBack(int n) => DateTime(today.year, today.month - n + 1, 1);
    final from = switch (_range) {
      _TrendRange.months3 => monthsBack(3),
      _TrendRange.months6 => monthsBack(6),
      _TrendRange.months12 => monthsBack(12),
      _TrendRange.all => first,
    };
    final report = ref.watch(reportProvider((from, today)));

    // Last four weeks so far against the four weeks before, per person.
    final monday = today.subtract(Duration(days: today.weekday - 1));
    final recentFrom = monday.subtract(const Duration(days: 21));
    final recent = ref.watch(reportProvider((recentFrom, today)));
    final before = ref.watch(
      reportProvider((
        recentFrom.subtract(const Duration(days: 28)),
        today.subtract(const Duration(days: 28)),
      )),
    );

    final weekdays = report.weekdayAverages;
    final worked = weekdays.where((w) => w.days > 0).toList();
    final busiest = worked.isEmpty
        ? null
        : worked.reduce((a, b) => b.average > a.average ? b : a);
    final quietest = worked.isEmpty
        ? null
        : worked.reduce((a, b) => b.average < a.average ? b : a);
    final months = report.months;
    final bestMonth = months.isEmpty
        ? null
        : months.reduce((a, b) => b.total > a.total ? b : a);

    final picker = SegmentedButton<_TrendRange>(
      segments: const [
        ButtonSegment(value: _TrendRange.months3, label: Text('3 months')),
        ButtonSegment(value: _TrendRange.months6, label: Text('6 months')),
        ButtonSegment(value: _TrendRange.months12, label: Text('12 months')),
        ButtonSegment(value: _TrendRange.all, label: Text('All time')),
      ],
      selected: {_range},
      showSelectedIcon: false,
      expandedInsets: MediaQuery.sizeOf(context).width < 600
          ? EdgeInsets.zero
          : null,
      style: MediaQuery.sizeOf(context).width < 600 ? Dt.phoneSegments : null,
      onSelectionChanged: (s) => setState(() => _range = s.first),
    );

    if (report.days.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          picker,
          const SizedBox(height: 14),
          const _Note('Nothing tracked in this period yet.'),
        ],
      );
    }

    String dayName(int weekday) =>
        DateFormat('EEEE')
            .format(DateTime(2024, 1, weekday)); // 1 Jan 2024 = Mon
    final tiles = <Widget>[
      _Tile(
        label: 'Clients',
        value: '${report.total}',
        caption:
            '${DateFormat('d MMM y').format(report.days.first.date)} – today',
      ),
      _Tile(
        label: 'Average per day',
        value: _QuickView._avg(report.dailyAverage),
        caption: '${report.staffedDaysSoFar} working days',
      ),
      _Tile(
        label: 'Busiest weekday',
        value: busiest == null ? '–' : dayName(busiest.weekday),
        caption: busiest == null
            ? ''
            : '${_QuickView._avg(busiest.average)} clients a day',
      ),
      _Tile(
        label: 'Best month',
        value: bestMonth == null
            ? '–'
            : DateFormat('MMM y').format(bestMonth.start),
        caption: bestMonth == null ? '' : '${bestMonth.total} clients',
      ),
    ];

    final weekdayPanel = _Panel(
      title: 'Busiest days of the week',
      icon: Icons.view_week_outlined,
      trailingWidget: const _Legend(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _WeekdayChart(averages: weekdays, busiest: busiest?.weekday),
          if (busiest != null && quietest != null && busiest != quietest)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                '${dayName(busiest.weekday)} is usually the busiest day '
                '(${_QuickView._avg(busiest.average)} clients) and '
                '${dayName(quietest.weekday)} the quietest '
                '(${_QuickView._avg(quietest.average)}). Average per working '
                'day; holidays are skipped.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Dt.textMuted(theme),
                ),
              ),
            ),
        ],
      ),
    );

    final monthPanel = _Panel(
      title: 'Month by month',
      icon: Icons.calendar_month_outlined,
      trailingWidget: const _Legend(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BucketBars(
            buckets: months,
            label: (m) =>
                DateFormat(months.length > 12 ? 'MMM\nyy' : 'MMM').format(m),
            tooltip: (m) => DateFormat('MMMM y').format(m),
          ),
          _BucketTable(
            buckets: months,
            label: (m) => DateFormat('MMMM y').format(m),
            compact: widget.compact,
            newestFirst: true,
          ),
        ],
      ),
    );

    final staffPanel = _Panel(
      title: 'Staff: last 4 weeks vs the 4 before',
      icon: Icons.trending_up,
      child: _StaffTrendTable(recent: recent, before: before),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(alignment: Alignment.centerLeft, child: picker),
        const SizedBox(height: 14),
        _TileGrid(perRow: widget.compact ? 2 : tiles.length, children: tiles),
        const SizedBox(height: 12),
        if (widget.compact) ...[
          weekdayPanel,
          const SizedBox(height: 12),
          staffPanel,
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: weekdayPanel),
              const SizedBox(width: 12),
              Expanded(child: staffPanel),
            ],
          ),
        const SizedBox(height: 12),
        monthPanel,
      ],
    );
  }
}

/// Mon–Fri average clients per working day, as stacked bars.
class _WeekdayChart extends StatelessWidget {
  const _WeekdayChart({required this.averages, this.busiest});

  final List<WeekdayAverage> averages;
  final int? busiest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = averages.fold<double>(
      0,
      (m, a) => a.average > m ? a.average : m,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      child: Column(
        children: [
          for (final a in averages)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    child: Text(
                      DateFormat('EEE').format(DateTime(2024, 1, a.weekday)),
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: a.weekday == busiest
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  Expanded(
                    child: GrowIn(
                      axis: Axis.horizontal,
                      index: a.weekday,
                      child: Tooltip(
                        message:
                            '${_QuickView._avg(a.newAverage)} new · '
                            '${_QuickView._avg(a.existingAverage)} existing a day\n'
                            'over ${a.days} working '
                            '${a.days == 1 ? 'day' : 'days'}',
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final w = max == 0
                                ? 0.0
                                : c.maxWidth * a.average / max;
                            final nw = a.average == 0
                                ? 0.0
                                : w * a.newAverage / a.average;
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                height: 14,
                                width: w,
                                child: Row(
                                  children: [
                                    Container(
                                      width: nw,
                                      color: Dt.newGreen(theme.brightness),
                                    ),
                                    Expanded(
                                      child: Container(
                                        color: Dt.existingBlue(
                                          theme.brightness,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: Text(
                      a.days == 0 ? '–' : _QuickView._avg(a.average),
                      textAlign: TextAlign.right,
                      style: _num(
                        theme,
                        bold: a.weekday == busiest,
                        color: a.days == 0 ? Dt.textFaint(theme) : null,
                      ),
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

/// Stacked New/Existing bars for months or weeks.
class _BucketBars extends StatelessWidget {
  const _BucketBars({
    required this.buckets,
    required this.label,
    required this.tooltip,
    this.height = 180,
  });

  final List<ReportBucket> buckets;
  final String Function(DateTime start) label;
  final String Function(DateTime start) tooltip;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final max = buckets.fold<int>(0, (m, b) => b.total > m ? b.total : m);
    final dense = buckets.length > 12;
    const valueH = 16.0;
    const labelH = 28.0;
    final plotH = height - valueH - labelH - 8;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      child: SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final b in buckets)
              Expanded(
                child: Tooltip(
                  message:
                      '${tooltip(b.start)}\n${b.newClients} new · '
                      '${b.existingClients} existing\n'
                      '${_QuickView._avg(b.dailyAverage)} a day',
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(
                        height: valueH,
                        child: Text(
                          b.total == 0 ? '' : '${b.total}',
                          style: Dt.tab(theme.textTheme.labelSmall!).copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: dense ? 9 : 11,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      () {
                        final h = max == 0 ? 0.0 : plotH * b.total / max;
                        final nh = b.total == 0
                            ? 0.0
                            : h * b.newClients / b.total;
                        return GrowIn(
                          index: buckets.indexOf(b),
                          child: SizedBox(
                            width: dense ? 12 : 26,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (nh > 0)
                                  Container(
                                    height: nh,
                                    decoration: BoxDecoration(
                                      color: Dt.newGreen(theme.brightness),
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(4),
                                      ),
                                    ),
                                  ),
                                if (h - nh > 0)
                                  Container(
                                    height: h - nh,
                                    color: Dt.existingBlue(theme.brightness),
                                  ),
                                if (h == 0)
                                  Container(
                                    height: 2,
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.14,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }(),
                      Container(height: 1, color: scheme.outline),
                      SizedBox(
                        height: labelH,
                        child: Center(
                          child: Text(
                            label(b.start),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: dense ? 9 : 11,
                              height: 1.1,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Months (or weeks) as rows: New, Existing, Total, a day, and the change
/// from the one before.
class _BucketTable extends StatelessWidget {
  const _BucketTable({
    required this.buckets,
    required this.label,
    required this.compact,
    this.newestFirst = false,
  });

  final List<ReportBucket> buckets;
  final String Function(DateTime start) label;
  final bool compact;
  final bool newestFirst;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = _headStyle(theme);
    final widths = compact
        ? const [44.0, 60.0, 48.0, 64.0]
        : const [64.0, 72.0, 64.0, 72.0, 96.0];
    final order = [for (var i = 0; i < buckets.length; i++) i];
    if (newestFirst) order.setAll(0, order.reversed.toList());
    return Column(
      children: [
        _Row(
          header: true,
          widths: widths,
          cells: [
            Text('Month', style: head),
            Text('New', style: head),
            Text('Existing', style: head),
            Text('Total', style: head),
            if (!compact) Text('A day', style: head),
            Text('Change', style: head),
          ],
        ),
        for (var k = 0; k < order.length; k++)
          () {
            final i = order[k];
            final b = buckets[i];
            final prev = i == 0 ? null : buckets[i - 1].total;
            return _Row(
              last: k == order.length - 1,
              widths: widths,
              cells: [
                Text(
                  label(b.start),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                _count(
                  theme,
                  b.newClients,
                  color: Dt.newGreen(theme.brightness),
                ),
                _count(
                  theme,
                  b.existingClients,
                  color: Dt.existingBlue(theme.brightness),
                ),
                _count(theme, b.total, bold: true),
                if (!compact)
                  Text(
                    b.staffedDays == 0 ? '–' : _QuickView._avg(b.dailyAverage),
                    style: _num(theme, color: Dt.textMuted(theme)),
                  ),
                _ChangeCell(current: b.total, previous: prev, percent: true),
              ],
            );
          }(),
      ],
    );
  }
}

/// Everyone's last four weeks so far against the four weeks before.
class _StaffTrendTable extends StatelessWidget {
  const _StaffTrendTable({required this.recent, required this.before});

  final Report recent;
  final Report before;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = _headStyle(theme);
    final earlier = {for (final s in before.staff) s.staffId: s.total};
    final staff = recent.staff
        .where((s) => s.total > 0 || earlier[s.staffId] != null)
        .toList();
    if (staff.isEmpty) return const _Note('Not enough weeks tracked yet.');
    const widths = [64.0, 64.0, 76.0];
    return Column(
      children: [
        _Row(
          header: true,
          widths: widths,
          cells: [
            Text('Staff', style: head),
            Text('Before', style: head),
            Text('Last 4 wks', style: head),
            Text('Change', style: head),
          ],
        ),
        for (var i = 0; i < staff.length; i++)
          _Row(
            last: i == staff.length - 1,
            widths: widths,
            onTap: () => showStaffProfile(context, staff[i].staffId),
            cells: [
              Text(
                staff[i].name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              _count(theme, earlier[staff[i].staffId] ?? 0),
              _count(theme, staff[i].total, bold: true),
              _ChangeCell(
                current: staff[i].total,
                previous: earlier[staff[i].staffId],
              ),
            ],
          ),
      ],
    );
  }
}

/// "▲ 4" / "▼ 2" (or a percentage) — muted, since colour is reserved for
/// the New/Existing pair.
class _ChangeCell extends StatelessWidget {
  const _ChangeCell({
    required this.current,
    required this.previous,
    this.percent = false,
  });

  final int current;

  /// Null: nothing to compare with.
  final int? previous;
  final bool percent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prev = previous;
    if (prev == null) {
      return Text('–', style: _num(theme, color: Dt.textFaint(theme)));
    }
    final diff = current - prev;
    if (diff == 0) {
      return Text('same', style: _num(theme, color: Dt.textMuted(theme)));
    }
    final text = percent && prev > 0
        ? '${(diff.abs() * 100 / prev).round()}%'
        : '${diff.abs()}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          diff > 0 ? Icons.arrow_drop_up : Icons.arrow_drop_down,
          size: 18,
          color: diff > 0
              ? Dt.statusGreen(theme.brightness)
              : theme.colorScheme.error,
        ),
        Text(text, style: _num(theme, color: Dt.textMuted(theme))),
      ],
    );
  }
}
