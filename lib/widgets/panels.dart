import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../design/app_theme.dart';
import 'motion.dart';

/// Bordered panel with a title bar — the app's standard container (dashboard,
/// Reports, tracker analytics).
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.trailingWidget,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final String? trailing;

  /// Header content on the right that isn't plain text (e.g. a legend).
  final Widget? trailingWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FadeSlideIn(
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(Dt.rMd),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: scheme.outline)),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (trailing != null)
                    Text(
                      trailing!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ?trailingWidget,
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
    Widget item(String label, Color c) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        item('New', Dt.newGreen(theme.brightness)),
        const SizedBox(width: 12),
        item('Existing', Dt.existingBlue(theme.brightness)),
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

/// Clients per day as stacked bars (existing at the base, new on top), with
/// the day's total above each bar and a tooltip carrying the exact split.
/// One axis, thin bars, 2px gaps between segments, today marked in ink.
class StackedDayChart extends StatelessWidget {
  const StackedDayChart({super.key, required this.days, this.height = 180});

  final List<ChartDay> days;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final max = days.fold<int>(0, (m, d) => d.total > m ? d.total : m);
    final dense = days.length > 7;
    const labelH = 18.0;
    const valueH = 16.0;
    // Value label + gaps + the 2px segment spacer all come out of height.
    final plotH = height - labelH - valueH - 8;

    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;

    Widget bar(ChartDay d) {
      final isToday = sameDay(d.date, now);
      final future = d.date.isAfter(now);
      final h = max == 0 ? 0.0 : plotH * d.total / max;
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                height: valueH,
                child: Text(
                  d.total == 0 ? '' : '${d.total}',
                  style: Dt.tab(theme.textTheme.labelSmall!).copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: dense ? 9.5 : 11,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              GrowIn(
                index: days.indexOf(d),
                child: Container(
                  width: dense ? 14 : 28,
                  constraints: BoxConstraints(maxWidth: dense ? 14 : 28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (newH > 0)
                        Container(
                          height: newH,
                          decoration: BoxDecoration(
                            color: Dt.newGreen(theme.brightness),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                          ),
                        ),
                      // 2px surface gap between the stacked segments.
                      if (newH > 0 && exH > 0) const SizedBox(height: 2),
                      if (exH > 0)
                        Container(
                          height: exH,
                          decoration: BoxDecoration(
                            color: Dt.existingBlue(theme.brightness),
                            borderRadius: newH > 0
                                ? null
                                : const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                          ),
                        ),
                      if (h == 0)
                        Container(
                          height: 2,
                          color: scheme.onSurface.withValues(
                            alpha: future ? 0.06 : 0.14,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              SizedBox(
                height: labelH,
                child: Center(
                  child: Text(
                    dense ? '${d.date.day}' : DateFormat('EEE').format(d.date),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: dense ? 9.5 : 11,
                      fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                      color: isToday
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                      decoration: isToday ? TextDecoration.underline : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            // Baseline.
            Positioned(
              left: 0,
              right: 0,
              bottom: labelH + 2,
              child: Container(height: 1, color: scheme.outline),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [for (final d in days) bar(d)],
            ),
          ],
        ),
      ),
    );
  }
}
