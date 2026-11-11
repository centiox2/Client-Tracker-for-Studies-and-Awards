part of 'reports_screen.dart';

// ------------------------------------------------------------- legend ----

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) => const NewExistingLegend();
}

// ------------------------------------------------------------- deltas ----

/// "▲ 4 (20%) vs last week" in muted ink — colour stays reserved for the
/// New/Existing data pair.
class _Delta extends StatelessWidget {
  const _Delta({
    required this.current,
    required this.previous,
    required this.against,
    this.format,
  });

  final int current;
  final int previous;

  /// Formats the difference (e.g. as money); plain number when null.
  final String Function(int)? format;

  /// What is being compared with, e.g. "last week".
  final String against;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diff = current - previous;
    final style = theme.textTheme.labelSmall?.copyWith(
      fontSize: 10.5,
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (diff == 0) {
      return Text('Same as $against', style: style, maxLines: 1);
    }
    final pct = previous == 0
        ? ''
        : ' (${(diff.abs() * 100 / previous).round()}%)';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          diff > 0 ? Icons.arrow_drop_up : Icons.arrow_drop_down,
          size: 16,
          color: style?.color,
        ),
        Flexible(
          child: Text(
            '${format?.call(diff.abs()) ?? diff.abs()}$pct vs $against',
            style: style,
            // Wraps on a phone instead of cutting off "vs last week".
            maxLines: MediaQuery.sizeOf(context).width < 600 ? 2 : 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// --------------------------------------------------------- day bars ----

/// Reports' per-day chart: the shared [StackedDayChart] fed from a report.
class _DayBars extends StatelessWidget {
  const _DayBars({required this.days, this.height = 180});

  final List<ReportDay> days;
  final double height;

  @override
  Widget build(BuildContext context) => StackedDayChart(
    height: height,
    days: [
      for (final d in days)
        ChartDay(
          date: d.date,
          newClients: d.newClients,
          existingClients: d.existingClients,
          offCount: d.offCount,
          isHoliday: d.isHoliday,
        ),
    ],
  );
}

// ----------------------------------------------------- staff × day grid ----

enum _Metric { total, newOnly, existingOnly }

/// Every staff member × every day in the range — the full detail. A week
/// fits the width; a month scrolls sideways with the names pinned.
class _StaffDayMatrix extends StatefulWidget {
  const _StaffDayMatrix({required this.report});

  final Report report;

  @override
  State<_StaffDayMatrix> createState() => _StaffDayMatrixState();
}

class _StaffDayMatrixState extends State<_StaffDayMatrix> {
  _Metric _metric = _Metric.total;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _value(ReportCell c) => switch (_metric) {
    _Metric.total => c.total,
    _Metric.newOnly => c.newClients,
    _Metric.existingOnly => c.existingClients,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = widget.report;
    final days = report.days;
    final staff = [...report.staff]
      ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder));
    final now = DateTime.now();
    final wide = days.length > 7;
    const nameW = 150.0;
    const totalW = 64.0;
    const rowH = 34.0;
    final head = _headStyle(theme);
    final hairline = BorderSide(color: scheme.outline.withValues(alpha: 0.6));

    int rowTotal(ReportStaff s) => switch (_metric) {
      _Metric.total => s.total,
      _Metric.newOnly => s.newClients,
      _Metric.existingOnly => s.existingClients,
    };
    int dayTotal(ReportDay d) => switch (_metric) {
      _Metric.total => d.total,
      _Metric.newOnly => d.newClients,
      _Metric.existingOnly => d.existingClients,
    };

    Widget cell(ReportStaff s, ReportDay d) {
      final c = report.cellFor(s.staffId, d.dayId);
      final today = _sameDay(d.date, now);
      final Widget content;
      final String tip;
      if (c == null) {
        content = Text('', style: head);
        tip = '${s.name} wasn’t on this week’s rota';
      } else if (c.off) {
        content = Text(
          d.isHoliday ? 'Hol.' : 'Off',
          style: theme.textTheme.labelSmall?.copyWith(
            color: Dt.textFaint(theme),
          ),
        );
        tip =
            '${s.name} · ${DateFormat('EEE d MMM').format(d.date)}\n'
            '${d.isHoliday ? 'Holiday' : 'Off'}';
      } else {
        final v = _value(c);
        content = Text(
          v == 0 ? '–' : '$v',
          style: _num(theme, color: v == 0 ? Dt.textFaint(theme) : null),
        );
        tip =
            '${s.name} · ${DateFormat('EEE d MMM').format(d.date)}\n'
            '${c.newClients} new · ${c.existingClients} existing';
      }
      return Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 200),
        child: Container(
          width: wide ? 44 : null,
          height: rowH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(left: hairline),
            color: today ? scheme.onSurface.withValues(alpha: 0.04) : null,
          ),
          child: content,
        ),
      );
    }

    Widget dayHeader(ReportDay d) {
      final today = _sameDay(d.date, now);
      return Container(
        width: wide ? 44 : null,
        height: rowH,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(left: hairline),
          color: today ? scheme.onSurface.withValues(alpha: 0.04) : null,
        ),
        child: Text(
          wide
              ? '${DateFormat('E').format(d.date)[0]}\n${d.date.day}'
              : DateFormat('EEE d').format(d.date),
          textAlign: TextAlign.center,
          style: head.copyWith(
            height: 1.15,
            fontWeight: today ? FontWeight.w700 : null,
            color: today ? scheme.onSurface : null,
          ),
        ),
      );
    }

    Widget dayCells(List<Widget> cells) => wide
        ? Row(children: cells)
        : Row(children: [for (final c in cells) Expanded(child: c)]);

    final rows = <Widget>[
      // Header.
      _matrixRow(
        name: Text('Staff', style: head),
        days: dayCells([for (final d in days) dayHeader(d)]),
        total: Text('Total', style: head),
        border: BorderSide(color: scheme.outline),
        nameW: nameW,
        totalW: totalW,
        height: rowH + 6,
      ),
      for (final s in staff)
        _matrixRow(
          name: Text(
            s.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              color: rowTotal(s) == 0 ? Dt.textMuted(theme) : null,
            ),
          ),
          days: dayCells([for (final d in days) cell(s, d)]),
          total: _count(theme, rowTotal(s), bold: true),
          border: hairline,
          nameW: nameW,
          totalW: totalW,
          height: rowH,
        ),
      // Footer: day totals.
      _matrixRow(
        name: Text(
          'Day total',
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        days: dayCells([
          for (final d in days)
            Container(
              width: wide ? 44 : null,
              height: rowH,
              alignment: Alignment.center,
              decoration: BoxDecoration(border: Border(left: hairline)),
              child: d.isHoliday
                  ? Text('Hol.', style: head)
                  : _count(theme, dayTotal(d), bold: true),
            ),
        ]),
        total: _count(theme, switch (_metric) {
          _Metric.total => report.total,
          _Metric.newOnly => report.newClients,
          _Metric.existingOnly => report.existingClients,
        }, bold: true),
        border: null,
        top: BorderSide(color: scheme.outline),
        nameW: nameW,
        totalW: totalW,
        height: rowH + 4,
      ),
    ];

    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
          child: Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<_Metric>(
                segments: const [
                  ButtonSegment(value: _Metric.total, label: Text('Total')),
                  ButtonSegment(value: _Metric.newOnly, label: Text('New')),
                  ButtonSegment(
                    value: _Metric.existingOnly,
                    label: Text('Existing'),
                  ),
                ],
                selected: {_metric},
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (s) => setState(() => _metric = s.first),
              ),
              Text(
                'Hover a number for the new / existing split.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Dt.textFaint(theme),
                ),
              ),
            ],
          ),
        ),
        if (!wide)
          table
        else
          Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 10),
              child: SizedBox(
                width: nameW + totalW + 28 + 44.0 * days.length,
                child: table,
              ),
            ),
          ),
      ],
    );
  }

  Widget _matrixRow({
    required Widget name,
    required Widget days,
    required Widget total,
    required BorderSide? border,
    required double nameW,
    required double totalW,
    required double height,
    BorderSide? top,
  }) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: Border(
          bottom: border ?? BorderSide.none,
          top: top ?? BorderSide.none,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: nameW,
            child: Align(alignment: Alignment.centerLeft, child: name),
          ),
          Expanded(child: days),
          SizedBox(
            width: totalW,
            child: Align(alignment: Alignment.centerRight, child: total),
          ),
        ],
      ),
    );
  }
}
