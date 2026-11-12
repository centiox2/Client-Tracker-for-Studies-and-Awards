import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:intl/intl.dart';

import '../design/app_theme.dart';
import 'motion.dart';

/// A Clarity card with a header: title (16/600) and an optional subtitle on
/// the left, a caption or legend on the right, a subtle line below. The
/// app's standard container.
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.title,
    this.icon,
    required this.child,
    this.subtitle,
    this.trailing,
    this.trailingWidget,
  });

  final String title;

  /// Kept for older call sites; Clarity card headers carry no icon.
  final IconData? icon;
  final Widget child;
  final String? subtitle;

  /// A short caption on the right ("9 of 15 active").
  final String? trailing;

  /// Header content on the right that isn't plain text (a legend, a link).
  final Widget? trailingWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    return FadeSlideIn(
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(Dt.rMd),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.borderSubtle)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: c.textMuted,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      trailing!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: c.textMuted,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                  if (trailingWidget != null) ...[
                    const SizedBox(width: 12),
                    // A link or legend never makes the header taller than
                    // its title: every card's header lines up, and a
                    // button keeps its full tap area (it reaches into the
                    // header's padding).
                    SizedBox(
                      height: 22,
                      child: OverflowBox(
                        maxHeight: 48,
                        fit: OverflowBoxFit.deferToChild,
                        child: Theme(
                          data: theme.copyWith(
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: trailingWidget!,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

/// "● New  ● Existing" — always shown beside a two-series chart so the
/// series are never told apart by colour alone.
class NewExistingLegend extends StatelessWidget {
  const NewExistingLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    Widget item(String label, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: c.textSecondary,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        item('New', c.seriesNew),
        const SizedBox(width: 16),
        item('Existing', c.seriesExisting),
      ],
    );
  }
}

/// One day's numbers for [StackedDayChart].
class ChartDay {
  const ChartDay({
    required this.date,
    required this.newClients,
    required this.existingClients,
    this.offCount = 0,
    this.isHoliday = false,
  });

  final DateTime date;
  final int newClients;
  final int existingClients;
  final int offCount;
  final bool isHoliday;

  int get total => newClients + existingClients;
}

/// Clients per day as stacked bars: new (orange) at the bottom, existing
/// (blue) on top, 4px top corners, the day's total above each bar, a tidy
/// y-axis with gridlines every quarter. A day with nothing entered shows no
/// bar (not a zero bar). A tooltip carries the exact split.
class StackedDayChart extends StatelessWidget {
  const StackedDayChart({super.key, required this.days, this.height = 180});

  final List<ChartDay> days;

  /// Height of the plot area (bars), without the labels.
  final double height;

  /// A round axis top for [max] with four equal steps (17 → 20, 43 → 60).
  static int niceTop(int max) {
    if (max <= 0) return 20;
    final raw = max / 4;
    var unit = 1;
    while (unit * 10 <= raw) {
      unit *= 10;
    }
    for (final m in [1, 2, 5, 10]) {
      if (unit * m >= raw) return unit * m * 4;
    }
    return unit * 40;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final now = DateTime.now();
    final max = days.fold<int>(0, (m, d) => d.total > m ? d.total : m);
    final top = niceTop(max);
    final dense = days.length > 7;
    const totalH = 20.0;
    final plotH = height;

    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;

    final small = theme.textTheme.labelSmall!.copyWith(
      color: c.textMuted,
      fontWeight: FontWeight.w400,
      fontSize: dense ? 10.5 : 11,
    );

    Widget column(int index, ChartDay d) {
      final h = top == 0 ? 0.0 : plotH * d.total / top;
      final newH = d.total == 0 ? 0.0 : h * d.newClients / d.total;
      final exH = h - newH;
      final tip = d.isHoliday
          ? '${DateFormat('EEE d MMM').format(d.date)}\nHoliday'
          : '${DateFormat('EEE d MMM').format(d.date)}\n'
                '${d.newClients} new · ${d.existingClients} existing'
                '${d.offCount > 0 ? '\n${d.offCount} staff off' : ''}';
      return Expanded(
        child: Tooltip(
          message: tip,
          waitDuration: const Duration(milliseconds: 150),
          child: LayoutBuilder(
            builder: (context, box) {
              final barW = (box.maxWidth * 0.44).clamp(4.0, 48.0);
              return Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (d.total > 0)
                    SizedBox(
                      height: totalH,
                      child: Text(
                        '${d.total}',
                        style: Dt.tab(theme.textTheme.labelSmall!).copyWith(
                          fontWeight: FontWeight.w600,
                          color: c.textSecondary,
                          fontSize: dense ? 10.5 : 12,
                        ),
                      ),
                    ),
                  if (d.total > 0)
                    GrowIn(
                      index: index,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                        child: SizedBox(
                          width: barW,
                          child: Column(
                            children: [
                              if (exH > 0)
                                Container(height: exH, color: c.seriesExisting),
                              if (newH > 0)
                                Container(height: newH, color: c.seriesNew),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
    }

    final axisW = dense ? 24.0 : 28.0;
    return Semantics(
      label:
          'Clients per day: '
          '${[for (final d in days)
            if (d.total > 0) '${DateFormat('EEE d').format(d.date)} ${d.newClients} new and ${d.existingClients} existing'].join(', ')}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          children: [
            SizedBox(
              height: plotH + totalH,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Y-axis: 0, ¼, ½, ¾, top.
                  SizedBox(
                    width: axisW,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (var q = 0; q <= 4; q++)
                          Positioned(
                            right: 6,
                            bottom: plotH * q / 4 - 7,
                            child: Text('${top * q ~/ 4}', style: small),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        for (var q = 1; q <= 4; q++)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: plotH * q / 4,
                            child: Container(height: 1, color: c.gridline),
                          ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(height: 1, color: c.borderStrong),
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (final (i, d) in days.indexed) column(i, d),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SizedBox(width: axisW),
                for (final d in days)
                  Expanded(
                    child: Center(
                      child: Text(
                        dense
                            ? '${d.date.day}'
                            : DateFormat('EEE d').format(d.date),
                        maxLines: 1,
                        style: small.copyWith(
                          fontWeight: sameDay(d.date, now)
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: sameDay(d.date, now) ? c.text : c.textMuted,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
