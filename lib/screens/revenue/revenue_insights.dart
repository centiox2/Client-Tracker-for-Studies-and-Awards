import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/revenue_repository.dart';
import '../../state/app_state.dart';
import '../../widgets/motion.dart';
import '../../widgets/panels.dart';

/// Everything worked out for the Insights view, from one read of the data.
class RevenueInsightsData {
  RevenueInsightsData({
    required this.today,
    required this.last30,
    required this.months,
    required this.monthEntries,
    required this.prevMonthToDateCents,
    required this.prevMonthCents,
    required this.weekdayAverages,
  });

  final DateTime today;

  /// The last 30 days, oldest first.
  final List<RevenueDay> last30;

  /// The last 12 months including this one, oldest first.
  final List<RevenueDay> months;

  /// This month's transactions.
  final List<RevenueEntry> monthEntries;

  /// Last month up to the same day of the month (a fair comparison).
  final int prevMonthToDateCents;

  /// All of last month.
  final int prevMonthCents;

  /// Average revenue on each weekday (1 = Monday) over the last 13 weeks.
  final Map<int, int> weekdayAverages;

  int get monthCents => monthEntries.fold(0, (s, e) => s + e.amountCents);
  int get monthDaysWithPayments =>
      {for (final e in monthEntries) e.date}.length;
}

final revenueInsightsProvider = Provider.autoDispose
    .family<RevenueInsightsData, DateTime>((ref, today) {
      ref.watch(dataVersionProvider);
      final repo = ref.read(revenueRepositoryProvider);
      final firstOfMonth = DateTime(today.year, today.month, 1);
      final prevFirst = DateTime(today.year, today.month - 1, 1);
      final prevLast = DateTime(today.year, today.month, 0);
      // Same day of last month, or its last day if shorter (31 Mar → 28 Feb).
      final prevSameDay = DateTime(
        prevFirst.year,
        prevFirst.month,
        today.day.clamp(1, prevLast.day),
      );
      int sum(List<RevenueDay> ds) =>
          ds.fold<int>(0, (s, d) => s + d.totalCents);

      final weeks = repo.daysBetween(
        today.subtract(const Duration(days: 91)),
        today,
      );
      final byWeekday = <int, List<int>>{};
      for (final d in weeks) {
        byWeekday.putIfAbsent(d.date.weekday, () => []).add(d.totalCents);
      }
      return RevenueInsightsData(
        today: today,
        last30: repo.daysBetween(
          today.subtract(const Duration(days: 29)),
          today,
        ),
        months: repo.monthsBetween(
          DateTime(today.year, today.month - 11, 1),
          today,
        ),
        monthEntries: repo.entriesBetween(firstOfMonth, today),
        prevMonthToDateCents: sum(repo.daysBetween(prevFirst, prevSameDay)),
        prevMonthCents: sum(repo.daysBetween(prevFirst, prevLast)),
        weekdayAverages: {
          for (final MapEntry(:key, :value) in byWeekday.entries)
            key: value.isEmpty
                ? 0
                // To the whole shilling: cents on an average are noise.
                : (value.reduce((a, b) => a + b) / value.length / 100).round() *
                      100,
        },
      );
    });

/// Charts and figures for revenue: this month against last, the last 30
/// days, the last 12 months, how people pay, the busiest weekdays, the
/// largest payments, and revenue per client.
class RevenueInsights extends ConsumerWidget {
  const RevenueInsights({super.key, required this.phone});
  final bool phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final data = ref.watch(revenueInsightsProvider(today));
    final currency = ref.watch(currencyProvider);
    final clients = ref.watch(
      reportProvider((DateTime(today.year, today.month, 1), today)),
    );
    String money(int c) => formatMoney(c, currency);
    // Averages to the whole shilling: cents on an average are just noise.
    String avgMoney(int c) => formatMoney((c / 100).round() * 100, currency);
    final monthName = DateFormat('MMMM').format(today);
    final prevMonthName = DateFormat('MMMM')
        .format(DateTime(today.year, today.month - 1, 1));

    final monthDays = data.last30
        .where((d) => d.date.month == today.month && d.date.year == today.year)
        .toList();
    final best = monthDays.where((d) => d.totalCents > 0).isEmpty
        ? null
        : monthDays.reduce((a, b) => b.totalCents > a.totalCents ? b : a);
    final tiles = <Widget>[
      _Stat(
        label: '$monthName so far',
        value: money(data.monthCents),
        caption: _change(
          data.monthCents,
          data.prevMonthToDateCents,
          'same days of $prevMonthName',
        ),
      ),
      _Stat(
        label: prevMonthName,
        value: money(data.prevMonthCents),
        caption: 'Whole month',
      ),
      _Stat(
        label: 'Average per day',
        value: data.monthDaysWithPayments == 0
            ? '–'
            : avgMoney(data.monthCents ~/ data.monthDaysWithPayments),
        caption:
            '${data.monthDaysWithPayments} '
            '${data.monthDaysWithPayments == 1 ? 'day' : 'days'} with '
            'payments this month',
      ),
      _Stat(
        label: 'Average payment',
        value: data.monthEntries.isEmpty
            ? '–'
            : avgMoney(data.monthCents ~/ data.monthEntries.length),
        caption:
            '${data.monthEntries.length} '
            '${data.monthEntries.length == 1 ? 'payment' : 'payments'} '
            'this month',
      ),
      _Stat(
        label: 'Best day this month',
        value: best == null ? '–' : money(best.totalCents),
        caption: best == null
            ? 'No payments this month yet'
            : DateFormat('EEEE d MMMM').format(best.date),
      ),
      _Stat(
        label: 'Revenue per client',
        value: clients.total == 0 || data.monthCents == 0
            ? '–'
            : avgMoney(data.monthCents ~/ clients.total),
        caption: '${clients.total} clients seen in $monthName',
      ),
    ];

    final last30 = AppPanel(
      title: 'Last 30 days',
      icon: Icons.bar_chart,
      trailing: money(data.last30.fold(0, (s, d) => s + d.totalCents)),
      child: MoneyBars(
        bars: [
          for (final d in data.last30)
            MoneyBar(
              label: '${d.date.day}',
              tooltip:
                  '${DateFormat('EEE d MMM').format(d.date)}\n'
                  '${money(d.totalCents)} · ${d.count} '
                  '${d.count == 1 ? 'payment' : 'payments'}',
              cents: d.totalCents,
              highlight: d.date == today,
            ),
        ],
        currency: currency,
        showAverage: true,
        averageLabel: 'average day with payments',
      ),
    );

    final months = AppPanel(
      title: 'Last 12 months',
      icon: Icons.calendar_view_month_outlined,
      trailing: money(data.months.fold(0, (s, d) => s + d.totalCents)),
      child: MoneyBars(
        bars: [
          for (final m in data.months)
            MoneyBar(
              label: DateFormat(phone ? 'MMMMM' : 'MMM').format(m.date),
              tooltip:
                  '${DateFormat('MMMM y').format(m.date)}\n'
                  '${money(m.totalCents)} · ${m.count} '
                  '${m.count == 1 ? 'payment' : 'payments'}',
              cents: m.totalCents,
              highlight:
                  m.date.year == today.year && m.date.month == today.month,
            ),
        ],
        currency: currency,
      ),
    );

    // How people pay: share of this month's money by method.
    final byMethod = <String, (int cents, int count)>{};
    for (final e in data.monthEntries) {
      final m = paymentMethodOf(e.note);
      final (c, n) = byMethod[m] ?? (0, 0);
      byMethod[m] = (c + e.amountCents, n + 1);
    }
    final methods = byMethod.entries.toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    final methodPanel = AppPanel(
      title: 'How people pay · $monthName',
      icon: Icons.account_balance_wallet_outlined,
      child: methods.isEmpty
          ? const _Empty('No payments this month yet.')
          : _HBars(
              rows: [
                for (final m in methods)
                  _HBarRow(
                    label: m.key,
                    cents: m.value.$1,
                    detail:
                        '${(m.value.$1 * 100 / data.monthCents).round()}% · '
                        '${m.value.$2} ${m.value.$2 == 1 ? 'payment' : 'payments'}',
                  ),
              ],
              currency: currency,
            ),
    );

    // Busiest weekdays (weekend only if money came in then).
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
    final weekdayPanel = AppPanel(
      title: 'Busiest weekdays · last 13 weeks',
      icon: Icons.view_week_outlined,
      child: data.weekdayAverages.values.every((v) => v == 0)
          ? const _Empty('Not enough payments yet to compare weekdays.')
          : _HBars(
              rows: [
                for (final w in weekdays)
                  _HBarRow(
                    label: DateFormat('EEEE').format(DateTime(2024, 1, w)),
                    cents: data.weekdayAverages[w] ?? 0,
                    detail: 'average',
                    bold: w == bestWeekday,
                  ),
              ],
              currency: currency,
            ),
    );

    final top = [...data.monthEntries]
      ..sort((a, b) => b.amountCents.compareTo(a.amountCents));
    final largestPanel = AppPanel(
      title: 'Largest payments · $monthName',
      icon: Icons.emoji_events_outlined,
      child: top.isEmpty
          ? const _Empty('No payments this month yet.')
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
                          width: 64,
                          child: Text(
                            DateFormat('d MMM').format(e.date),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Dt.textMuted(theme),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            e.note.isEmpty ? 'Transaction' : e.note,
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
        LayoutBuilder(
          builder: (context, c) {
            final perRow = phone ? 2 : tiles.length;
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
        last30,
        const SizedBox(height: 12),
        months,
        const SizedBox(height: 12),
        pair(methodPanel, weekdayPanel),
        const SizedBox(height: 12),
        largestPanel,
      ],
    );
  }

  static String _change(int now, int before, String against) {
    if (before == 0) {
      return now == 0 ? 'Nothing yet' : 'vs nothing on the $against';
    }
    final pct = ((now - before) * 100 / before).round();
    if (pct == 0) return 'Same as the $against';
    return '${pct > 0 ? '+' : '−'}${pct.abs()}% vs the $against';
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
      padding: const EdgeInsets.all(14),
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
            maxLines: 2,
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
  });
  final String label;
  final String tooltip;
  final int cents;

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
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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
