import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/revenue_repository.dart';
import '../../services/export_actions.dart' show deliverFile;
import '../../services/revenue_export.dart';
import '../../state/app_state.dart';
import '../../widgets/motion.dart';
import '../../widgets/panels.dart';

/// The period Insights looks at.
enum InsightsPeriod { week, month, year, custom }

/// Everything worked out for one period, from one read of the data.
class RevenueInsightsData {
  RevenueInsightsData({
    required this.from,
    required this.to,
    required this.days,
    required this.months,
    required this.entries,
    required this.previousCents,
    required this.lastYearCents,
    required this.months12,
    required this.weekdayAverages,
    required this.weekdaySpanWeeks,
  });

  /// The period (inclusive), never past today.
  final DateTime from;
  final DateTime to;

  /// Every day of the period, oldest first.
  final List<RevenueDay> days;

  /// Every month the period touches, oldest first.
  final List<RevenueDay> months;

  /// The period's transactions (refunds included, as negatives).
  final List<RevenueEntry> entries;

  /// The same length of time just before, and the same dates last year.
  final int previousCents;
  final int lastYearCents;

  /// The 12 months up to the period's end.
  final List<RevenueDay> months12;

  /// Average revenue on each weekday (1 = Monday).
  final Map<int, int> weekdayAverages;
  final int weekdaySpanWeeks;

  /// Net revenue: payments minus refunds.
  int get totalCents => entries.fold(0, (s, e) => s + e.amountCents);
  List<RevenueEntry> get payments => entries.where((e) => !e.isRefund).toList();
  List<RevenueEntry> get refunds => entries.where((e) => e.isRefund).toList();
  int get daysWithPayments => {for (final e in payments) e.date}.length;
  int get lengthInDays => to.difference(from).inDays + 1;
}

final revenueInsightsProvider = Provider.autoDispose
    .family<RevenueInsightsData, (DateTime, DateTime)>((ref, range) {
      ref.watch(dataVersionProvider);
      final repo = ref.read(revenueRepositoryProvider);
      final (from, to) = range;
      final length = to.difference(from).inDays + 1;
      int sum(List<RevenueDay> ds) =>
          ds.fold<int>(0, (s, d) => s + d.totalCents);
      DateTime yearBack(DateTime d) => DateTime(
        d.year - 1,
        d.month,
        // 29 Feb → 28 Feb.
        d.day.clamp(1, DateTime(d.year - 1, d.month + 1, 0).day),
      );

      // Weekdays: over the period, or the last 13 weeks for short periods.
      final wdFrom = length >= 28
          ? from
          : to.subtract(const Duration(days: 90));
      final byWeekday = <int, List<int>>{};
      for (final d in repo.daysBetween(wdFrom, to)) {
        byWeekday.putIfAbsent(d.date.weekday, () => []).add(d.totalCents);
      }
      return RevenueInsightsData(
        from: from,
        to: to,
        days: repo.daysBetween(from, to),
        months: repo.monthsBetween(from, to),
        entries: repo.entriesBetween(from, to),
        previousCents: sum(
          repo.daysBetween(
            from.subtract(Duration(days: length)),
            from.subtract(const Duration(days: 1)),
          ),
        ),
        lastYearCents: sum(repo.daysBetween(yearBack(from), yearBack(to))),
        months12: repo.monthsBetween(DateTime(to.year, to.month - 11, 1), to),
        weekdayAverages: {
          for (final MapEntry(:key, :value) in byWeekday.entries)
            key: value.isEmpty
                ? 0
                // To the whole shilling: cents on an average are noise.
                : (value.reduce((a, b) => a + b) / value.length / 100).round() *
                      100,
        },
        weekdaySpanWeeks: ((to.difference(wdFrom).inDays + 1) / 7).round(),
      );
    });

/// Charts and figures for revenue over a chosen period (week, month, year
/// or any dates): the total against the period before and the same period
/// last year, the money by day or month, how people pay, what payments are
/// for, the busiest weekdays, the largest payments, refunds, and revenue
/// per client. Every chart can be shown as a table.
class RevenueInsights extends ConsumerStatefulWidget {
  const RevenueInsights({super.key, required this.phone});
  final bool phone;

  @override
  ConsumerState<RevenueInsights> createState() => _RevenueInsightsState();
}

class _RevenueInsightsState extends ConsumerState<RevenueInsights> {
  InsightsPeriod _period = InsightsPeriod.month;

  /// 0 = the current week/month/year; -1 the one before, and so on.
  int _offset = 0;
  DateTimeRange? _custom;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// The chosen period, cut off at today.
  (DateTime, DateTime, String) _range() {
    final today = _today();
    DateTime cap(DateTime d) => d.isAfter(today) ? today : d;
    switch (_period) {
      case InsightsPeriod.week:
        final monday = today.subtract(Duration(days: today.weekday - 1));
        final from = monday.add(Duration(days: 7 * _offset));
        final to = cap(from.add(const Duration(days: 6)));
        return (
          from,
          to,
          _offset == 0
              ? 'This week'
              : 'Week of ${DateFormat('d MMM y').format(from)}',
        );
      case InsightsPeriod.month:
        final from = DateTime(today.year, today.month + _offset, 1);
        final to = cap(DateTime(from.year, from.month + 1, 0));
        return (from, to, DateFormat('MMMM y').format(from));
      case InsightsPeriod.year:
        final from = DateTime(today.year + _offset, 1, 1);
        final to = cap(DateTime(from.year, 12, 31));
        return (from, to, '${from.year}');
      case InsightsPeriod.custom:
        final r =
            _custom ??
            DateTimeRange(
              start: today.subtract(const Duration(days: 29)),
              end: today,
            );
        final from = DateTime(r.start.year, r.start.month, r.start.day);
        final to = cap(DateTime(r.end.year, r.end.month, r.end.day));
        String f(DateTime d) => DateFormat('d MMM y').format(d);
        return (from, to, '${f(from)} – ${f(to)}');
    }
  }

  Future<void> _pickCustom() async {
    final today = _today();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2007),
      lastDate: today,
      initialDateRange:
          _custom ??
          DateTimeRange(
            start: today.subtract(const Duration(days: 29)),
            end: today,
          ),
    );
    if (r != null) {
      setState(() {
        _custom = r;
        _period = InsightsPeriod.custom;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = widget.phone;
    final theme = Theme.of(context);
    final today = _today();
    final (from, to, periodLabel) = _range();
    final data = ref.watch(revenueInsightsProvider((from, to)));
    final currency = ref.watch(currencyProvider);
    final clients = ref.watch(reportProvider((from, to)));
    String money(int c) => formatMoney(c, currency);
    // Averages to the whole shilling: cents on an average are just noise.
    String avgMoney(int c) => formatMoney((c / 100).round() * 100, currency);
    final payments = data.payments;
    final paidCents = payments.fold<int>(0, (s, e) => s + e.amountCents);
    final refunds = data.refunds;
    final refundCents = refunds.fold<int>(0, (s, e) => -e.amountCents + s);
    final previousName = switch (_period) {
      InsightsPeriod.week => 'the week before',
      InsightsPeriod.month => 'the month before',
      InsightsPeriod.year => 'the year before',
      InsightsPeriod.custom => 'the ${data.lengthInDays} days before',
    };
    final best = data.days.where((d) => d.totalCents > 0).isEmpty
        ? null
        : data.days.reduce((a, b) => b.totalCents > a.totalCents ? b : a);

    // ---- Period picker ---------------------------------------------------
    final picker = Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SegmentedButton<InsightsPeriod>(
          key: const ValueKey('insights-period'),
          segments: const [
            ButtonSegment(value: InsightsPeriod.week, label: Text('Week')),
            ButtonSegment(value: InsightsPeriod.month, label: Text('Month')),
            ButtonSegment(value: InsightsPeriod.year, label: Text('Year')),
            ButtonSegment(value: InsightsPeriod.custom, label: Text('Dates')),
          ],
          selected: {_period},
          showSelectedIcon: false,
          style: phone ? Dt.phoneSegments : null,
          onSelectionChanged: (s) {
            if (s.first == InsightsPeriod.custom) {
              _pickCustom();
              return;
            }
            setState(() {
              _period = s.first;
              _offset = 0;
            });
          },
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_period != InsightsPeriod.custom)
              IconButton(
                tooltip: 'Earlier',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _offset--),
                icon: const Icon(Icons.chevron_left, size: 20),
              ),
            if (_period == InsightsPeriod.custom)
              TextButton.icon(
                onPressed: _pickCustom,
                icon: const Icon(Icons.date_range, size: 16),
                label: Text(periodLabel),
              )
            else
              Text(
                periodLabel,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (_period != InsightsPeriod.custom)
              IconButton(
                tooltip: 'Later',
                visualDensity: VisualDensity.compact,
                onPressed: _offset < 0 ? () => setState(() => _offset++) : null,
                icon: const Icon(Icons.chevron_right, size: 20),
              ),
          ],
        ),
        OutlinedButton.icon(
          key: const ValueKey('insights-download'),
          onPressed: () => deliverFile(
            context,
            dialogTitle: 'Save revenue as Excel',
            fileName:
                'revenue_${DateFormat('yyyyMMdd').format(from)}_'
                '${DateFormat('yyyyMMdd').format(to)}.xlsx',
            extension: 'xlsx',
            bytes: revenueToExcel(
              data.entries,
              from: from,
              to: to,
              currency: currency,
              title: 'Revenue · $periodLabel',
            ),
          ),
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('Download'),
        ),
      ],
    );

    // ---- Tiles -----------------------------------------------------------
    final tiles = <Widget>[
      _Stat(
        label: 'Revenue',
        value: money(data.totalCents),
        caption: [
          _change(data.totalCents, data.previousCents, previousName),
          _change(data.totalCents, data.lastYearCents, 'same dates last year'),
        ].join('\n'),
      ),
      _Stat(
        label: 'Average per day',
        value: data.daysWithPayments == 0
            ? '–'
            : avgMoney(data.totalCents ~/ data.daysWithPayments),
        caption:
            '${data.daysWithPayments} '
            '${data.daysWithPayments == 1 ? 'day' : 'days'} with payments',
      ),
      _Stat(
        label: 'Average payment',
        value: payments.isEmpty ? '–' : avgMoney(paidCents ~/ payments.length),
        caption:
            '${payments.length} '
            '${payments.length == 1 ? 'payment' : 'payments'}',
      ),
      _Stat(
        label: 'Best day',
        value: best == null ? '–' : money(best.totalCents),
        caption: best == null
            ? 'No payments yet'
            : DateFormat('EEE d MMM y').format(best.date),
      ),
      _Stat(
        label: 'Revenue per client',
        value: clients.total == 0 || data.totalCents <= 0
            ? '–'
            : avgMoney(data.totalCents ~/ clients.total),
        caption: '${clients.total} clients seen',
      ),
      _Stat(
        label: 'Refunds',
        value: refunds.isEmpty ? 'None' : money(refundCents),
        caption: refunds.isEmpty
            ? 'Money paid back'
            : '${refunds.length} ${refunds.length == 1 ? 'refund' : 'refunds'}'
                  ' · already taken off the revenue',
      ),
    ];

    // ---- Charts ----------------------------------------------------------
    final byDay = data.lengthInDays <= 62;
    final mainChart = _ChartPanel(
      title: byDay ? 'By day' : 'By month',
      icon: Icons.bar_chart,
      trailing: money(data.totalCents),
      currency: currency,
      showAverage: byDay,
      averageLabel: 'average day with payments',
      bars: byDay
          ? [
              for (final d in data.days)
                MoneyBar(
                  label: data.days.length <= 7
                      ? DateFormat('EEE').format(d.date)
                      : '${d.date.day}',
                  name: DateFormat('EEE d MMM y').format(d.date),
                  tooltip:
                      '${DateFormat('EEE d MMM').format(d.date)}\n'
                      '${money(d.totalCents)} · ${d.count} '
                      '${d.count == 1 ? 'payment' : 'payments'}',
                  cents: d.totalCents,
                  count: d.count,
                  highlight: d.date == today,
                ),
            ]
          : [
              for (final m in data.months)
                MoneyBar(
                  label: DateFormat(phone ? 'MMMMM' : 'MMM').format(m.date),
                  name: DateFormat('MMMM y').format(m.date),
                  tooltip:
                      '${DateFormat('MMMM y').format(m.date)}\n'
                      '${money(m.totalCents)} · ${m.count} '
                      '${m.count == 1 ? 'payment' : 'payments'}',
                  cents: m.totalCents,
                  count: m.count,
                  highlight:
                      m.date.year == today.year && m.date.month == today.month,
                ),
            ],
    );
    final yearChart = _ChartPanel(
      title: '12 months to ${DateFormat('MMM y').format(data.to)}',
      icon: Icons.calendar_view_month_outlined,
      trailing: money(data.months12.fold(0, (s, d) => s + d.totalCents)),
      currency: currency,
      bars: [
        for (final m in data.months12)
          MoneyBar(
            label: DateFormat(phone ? 'MMMMM' : 'MMM').format(m.date),
            name: DateFormat('MMMM y').format(m.date),
            tooltip:
                '${DateFormat('MMMM y').format(m.date)}\n'
                '${money(m.totalCents)} · ${m.count} '
                '${m.count == 1 ? 'payment' : 'payments'}',
            cents: m.totalCents,
            count: m.count,
            highlight: m.date.year == today.year && m.date.month == today.month,
          ),
      ],
    );

    List<_HBarRow> shareRows(String Function(RevenueEntry) key) {
      final by = <String, (int, int)>{};
      for (final e in payments) {
        final k = key(e);
        final (c, n) = by[k] ?? (0, 0);
        by[k] = (c + e.amountCents, n + 1);
      }
      final rows = by.entries.toList()
        ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
      return [
        for (final r in rows)
          _HBarRow(
            label: r.key,
            cents: r.value.$1,
            detail:
                '${paidCents == 0 ? 0 : (r.value.$1 * 100 / paidCents).round()}% · '
                '${r.value.$2} ${r.value.$2 == 1 ? 'payment' : 'payments'}',
          ),
      ];
    }

    final methodPanel = _HBarPanel(
      title: 'How people pay',
      icon: Icons.account_balance_wallet_outlined,
      rows: shareRows((e) => paymentMethodOf(e.note)),
      currency: currency,
      empty: 'No payments in this period.',
    );
    final purposePanel = _HBarPanel(
      title: 'What payments are for',
      icon: Icons.sell_outlined,
      rows: shareRows((e) => e.purpose.isEmpty ? 'Not set' : e.purpose),
      currency: currency,
      empty: 'No payments in this period.',
    );

    final weekdays = [
      for (var w = 1; w <= 7; w++)
        if (w <= 5 || (data.weekdayAverages[w] ?? 0) > 0) w,
    ];
    final bestWeekday = weekdays.isEmpty
        ? null
        : weekdays.reduce(
            (a, b) =>
                (data.weekdayAverages[b] ?? 0) > (data.weekdayAverages[a] ?? 0)
                ? b
                : a,
          );
    final weekdayPanel = _HBarPanel(
      title: 'Busiest weekdays · ${data.weekdaySpanWeeks} weeks',
      icon: Icons.view_week_outlined,
      rows: data.weekdayAverages.values.every((v) => v == 0)
          ? const []
          : [
              for (final w in weekdays)
                _HBarRow(
                  label: DateFormat('EEEE').format(DateTime(2024, 1, w)),
                  cents: data.weekdayAverages[w] ?? 0,
                  detail: 'average',
                  bold: w == bestWeekday,
                ),
            ],
      currency: currency,
      empty: 'Not enough payments yet to compare weekdays.',
    );

    final top = [...payments]
      ..sort((a, b) => b.amountCents.compareTo(a.amountCents));
    final largestPanel = AppPanel(
      title: 'Largest payments',
      icon: Icons.emoji_events_outlined,
      child: top.isEmpty
          ? const _Empty('No payments in this period.')
          : Column(
              children: [
                for (final (i, e) in top.take(5).indexed)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        top: i == 0
                            ? BorderSide.none
                            : BorderSide(color: theme.colorScheme.outline),
                      ),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 74,
                          child: Text(
                            DateFormat(
                              e.date.year == today.year ? 'd MMM' : 'd MMM yy',
                            ).format(e.date),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Dt.textMuted(theme),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            [
                              if (e.note.isNotEmpty) e.note,
                              if (e.purpose.isNotEmpty) e.purpose,
                            ].join(' · ').ifEmpty('Transaction'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          money(e.amountCents),
                          style: Dt.tab(theme.textTheme.bodySmall!)
                              .copyWith(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );

    Widget pair(Widget a, Widget b) => phone
        ? Column(children: [a, const SizedBox(height: 12), b])
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: 12),
              Expanded(child: b),
            ],
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        picker,
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final perRow = phone ? 2 : 3;
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
        mainChart,
        if (byDay) ...[const SizedBox(height: 12), yearChart],
        const SizedBox(height: 12),
        pair(methodPanel, purposePanel),
        const SizedBox(height: 12),
        pair(weekdayPanel, largestPanel),
      ],
    );
  }

  static String _change(int now, int before, String against) {
    if (before == 0) {
      return now == 0 ? 'Nothing vs $against' : 'Nothing on $against';
    }
    final pct = ((now - before) * 100 / before).round();
    if (pct == 0) return 'Same as $against';
    return '${pct > 0 ? '+' : '−'}${pct.abs()}% vs $against';
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// A chart panel with a "Table" switch: the same numbers as rows, to read
/// or copy exactly.
class _ChartPanel extends StatefulWidget {
  const _ChartPanel({
    required this.title,
    required this.icon,
    required this.trailing,
    required this.bars,
    required this.currency,
    this.showAverage = false,
    this.averageLabel = 'average',
  });
  final String title;
  final IconData icon;
  final String trailing;
  final List<MoneyBar> bars;
  final String currency;
  final bool showAverage;
  final String averageLabel;

  @override
  State<_ChartPanel> createState() => _ChartPanelState();
}

class _ChartPanelState extends State<_ChartPanel> {
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppPanel(
      title: widget.title,
      icon: widget.icon,
      trailingWidget: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.trailing,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: _table ? 'Show as chart' : 'Show as table',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: () => setState(() => _table = !_table),
            icon: Icon(_table ? Icons.bar_chart : Icons.table_rows_outlined),
          ),
        ],
      ),
      child: _table
          ? _MoneyTable(bars: widget.bars, currency: widget.currency)
          : MoneyBars(
              bars: widget.bars,
              currency: widget.currency,
              showAverage: widget.showAverage,
              averageLabel: widget.averageLabel,
            ),
    );
  }
}

/// The bars of a chart as a table: period, revenue, payments.
class _MoneyTable extends StatelessWidget {
  const _MoneyTable({required this.bars, required this.currency});
  final List<MoneyBar> bars;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final head = theme.textTheme.labelSmall?.copyWith(color: muted);
    Widget row(List<Widget> cells, {bool top = true}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
      decoration: BoxDecoration(
        border: Border(
          top: top
              ? BorderSide(color: theme.colorScheme.outline)
              : BorderSide.none,
        ),
      ),
      child: Row(children: cells),
    );
    return SelectionArea(
      child: Column(
        children: [
          row(top: false, [
            Expanded(child: Text('Period', style: head)),
            SizedBox(
              width: 140,
              child: Text('Revenue', style: head, textAlign: TextAlign.right),
            ),
            SizedBox(
              width: 80,
              child: Text('Payments', style: head, textAlign: TextAlign.right),
            ),
          ]),
          for (final b in bars.reversed)
            row([
              Expanded(
                child: Text(
                  b.name ?? b.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: b.highlight ? FontWeight.w700 : null,
                  ),
                ),
              ),
              SizedBox(
                width: 140,
                child: Text(
                  b.cents == 0 ? '–' : formatMoney(b.cents, currency),
                  textAlign: TextAlign.right,
                  style: Dt.tab(theme.textTheme.bodySmall!),
                ),
              ),
              SizedBox(
                width: 80,
                child: Text(
                  '${b.count}',
                  textAlign: TextAlign.right,
                  style: Dt.tab(theme.textTheme.bodySmall!)
                      .copyWith(color: muted),
                ),
              ),
            ]),
        ],
      ),
    );
  }
}

/// A panel of labelled horizontal bars, with a table switch too.
class _HBarPanel extends StatefulWidget {
  const _HBarPanel({
    required this.title,
    required this.icon,
    required this.rows,
    required this.currency,
    required this.empty,
  });
  final String title;
  final IconData icon;
  final List<_HBarRow> rows;
  final String currency;
  final String empty;

  @override
  State<_HBarPanel> createState() => _HBarPanelState();
}

class _HBarPanelState extends State<_HBarPanel> {
  bool _table = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppPanel(
      title: widget.title,
      icon: widget.icon,
      trailingWidget: widget.rows.isEmpty
          ? null
          : IconButton(
              tooltip: _table ? 'Show as chart' : 'Show as table',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: () => setState(() => _table = !_table),
              icon: Icon(_table ? Icons.bar_chart : Icons.table_rows_outlined),
            ),
      child: widget.rows.isEmpty
          ? _Empty(widget.empty)
          : _table
          ? SelectionArea(
              child: Column(
                children: [
                  for (final (i, r) in widget.rows.indexed)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          top: i == 0
                              ? BorderSide.none
                              : BorderSide(color: theme.colorScheme.outline),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              r.label,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          Text(
                            formatMoney(r.cents, widget.currency),
                            style: Dt.tab(theme.textTheme.bodySmall!),
                          ),
                          SizedBox(
                            width: 150,
                            child: Text(
                              r.detail,
                              textAlign: TextAlign.right,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Dt.textMuted(theme),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            )
          : _HBars(rows: widget.rows, currency: widget.currency),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.caption,
  });
  final String label;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 104),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: Dt.tab(theme.textTheme.titleLarge!)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            caption,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Dt.textMuted(Theme.of(context))),
    ),
  );
}

/// One bar of a [MoneyBars] chart.
class MoneyBar {
  const MoneyBar({
    required this.label,
    required this.tooltip,
    required this.cents,
    this.highlight = false,
    this.name,
    this.count = 0,
  });
  final String label;
  final String tooltip;
  final int cents;

  /// The full name of the period, for the table view ("Tue 3 Nov 2026").
  final String? name;

  /// How many payments made it.
  final int count;

  /// Today / this month: label in bold ink.
  final bool highlight;
}

/// Money over time as columns: one series in the brand colour, one axis,
/// thin bars with 4px rounded tops on a baseline, a tooltip on every bar
/// (hover or long-press), and only the largest bar labelled. Optionally a
/// dashed line at the average of the bars that have money.
class MoneyBars extends StatelessWidget {
  const MoneyBars({
    super.key,
    required this.bars,
    required this.currency,
    this.height = 180,
    this.showAverage = false,
    this.averageLabel = 'average',
  });

  final List<MoneyBar> bars;
  final String currency;
  final double height;
  final bool showAverage;
  final String averageLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = Dt.brand(theme.brightness);
    final max = bars.fold<int>(0, (m, b) => b.cents > m ? b.cents : m);
    final withMoney = bars.where((b) => b.cents > 0).toList();
    final avg = withMoney.isEmpty
        ? 0
        : (withMoney.fold<int>(0, (s, b) => s + b.cents) /
                      withMoney.length /
                      100)
                  .round() *
              100;
    final maxIndex = bars.indexWhere((b) => b.cents == max && max > 0);
    final dense = bars.length > 14;
    const labelH = 18.0;
    const valueH = 16.0;
    final plotH = height - labelH - valueH - 8;

    if (max == 0) {
      return const _Empty('No payments in this period yet.');
    }

    Widget bar(int i, MoneyBar b) {
      final h = plotH * b.cents / max;
      return Expanded(
        child: Tooltip(
          message: b.tooltip,
          waitDuration: const Duration(milliseconds: 120),
          // Taller than the bar: easy to hover even for small days.
          child: Container(
            color: Colors.transparent,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(
                  height: valueH,
                  // May spill over the neighbouring (empty) columns.
                  child: i == maxIndex
                      ? OverflowBox(
                          maxWidth: 90,
                          child: Text(
                            formatMoneyShort(b.cents, currency),
                            maxLines: 1,
                            style: Dt.tab(theme.textTheme.labelSmall!).copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 10.5,
                            ),
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 4),
                GrowIn(
                  index: i,
                  // At most 60% of the column (and 26px), so neighbouring
                  // bars always have a gap, however narrow the screen.
                  child: LayoutBuilder(
                    builder: (context, c) => Container(
                      width: (c.maxWidth * 0.6).clamp(2.0, 26.0),
                      height: b.cents == 0 ? 2 : h.clamp(2.0, plotH),
                      decoration: BoxDecoration(
                        color: b.cents == 0
                            ? scheme.onSurface.withValues(alpha: 0.12)
                            : color,
                        borderRadius: b.cents == 0
                            ? null
                            : const BorderRadius.vertical(
                                top: Radius.circular(4),
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: labelH,
                  // A label may spill over its neighbours' (empty) slots.
                  child: OverflowBox(
                    maxWidth: 40,
                    child: Text(
                      // Dense charts label every few bars, and the highlight.
                      !dense || i % 5 == 0 || b.highlight ? b.label : '',
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: dense ? 9.5 : 11,
                        fontWeight: b.highlight
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color: b.highlight
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final avgY = labelH + 2 + plotH * avg / max;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: height,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: labelH + 2,
                  child: Container(height: 1, color: scheme.outline),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [for (final (i, b) in bars.indexed) bar(i, b)],
                ),
                if (showAverage && avg > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: avgY,
                    child: IgnorePointer(
                      child: CustomPaint(
                        size: const Size(double.infinity, 1),
                        painter: _DashPainter(
                          scheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (showAverage && avg > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: CustomPaint(
                      size: const Size(18, 1),
                      painter: _DashPainter(
                        scheme.onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '${formatMoney(avg, currency)} $averageLabel',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Dt.textMuted(theme),
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

class _DashPainter extends CustomPainter {
  _DashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, 0), Offset((x + 4).clamp(0, size.width), 0), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}

class _HBarRow {
  const _HBarRow({
    required this.label,
    required this.cents,
    required this.detail,
    this.bold = false,
  });
  final String label;
  final int cents;
  final String detail;
  final bool bold;
}

/// Labelled horizontal bars in the brand colour: name, bar, amount and a
/// detail line. Identity is in the label, never the colour.
class _HBars extends StatelessWidget {
  const _HBars({required this.rows, required this.currency});
  final List<_HBarRow> rows;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final max = rows.fold<int>(0, (m, r) => r.cents > m ? r.cents : m);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      r.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: r.bold ? FontWeight.w700 : null,
                      ),
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) => Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 10,
                          width: max == 0 || r.cents == 0
                              ? 2
                              : (c.maxWidth * r.cents / max).clamp(
                                  2.0,
                                  c.maxWidth,
                                ),
                          decoration: BoxDecoration(
                            color: r.cents == 0
                                ? scheme.onSurface.withValues(alpha: 0.12)
                                : Dt.brand(theme.brightness),
                            borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 118,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatMoney(r.cents, currency),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Dt.tab(theme.textTheme.bodySmall!)
                              .copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          r.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                            color: Dt.textMuted(theme),
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
