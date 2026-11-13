import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../state/app_state.dart';
import '../../widgets/motion.dart';
import '../../widgets/clarity.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/undo_snack.dart';
import '../../widgets/week_label.dart';
import '../weekly_tracker/new_week_dialog.dart';
import '../../services/search_text.dart';

/// Every recorded week, grouped by month, searchable, with Open and Delete.
/// Same panel style as the dashboard and Reports.
///
/// [readOnly] (the boss's view): no Delete, and a week opens as a report
/// instead of in the tracker.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key, this.readOnly = false});
  final bool readOnly;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  String _query = '';
  final _searchController = TextEditingController();

  // Shared by the Scrollbar and the list: on desktop a list doesn't attach
  // to the primary controller, so a scrollbar without one can't paint.
  final _scroll = ScrollController();

  @override
  void dispose() {
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final weeks = ref.watch(historyProvider);
    final filtered = _query.isEmpty
        ? weeks
        : weeks.where((w) => weekMatchesQuery(w, _query)).toList();
    final now = DateTime.now();
    final theme = Theme.of(context);

    if (weeks.isEmpty) {
      return widget.readOnly
          ? const EmptyState(
              icon: Icons.history,
              title: 'No weeks yet',
              message: 'Weeks appear here once clients are being tracked.',
            )
          : EmptyState(
              icon: Icons.history,
              title: 'No weeks yet',
              message: 'Create your first week to see it here.',
              actionLabel: 'New week',
              onAction: () => showNewWeekDialog(context, ref),
            );
    }

    // Group by the month each week starts in.
    final groups = <({DateTime month, List<WeekSummary> weeks})>[];
    for (final w in filtered) {
      final start = w.week.startDate;
      final month = DateTime(start.year, start.month);
      final last = groups.isEmpty ? null : groups.last;
      if (last != null && last.month == month) {
        last.weeks.add(w);
      } else {
        groups.add((month: month, weeks: [w]));
      }
    }

    return LayoutBuilder(
      builder: (context, viewport) {
        final pad = clarityHPad(context);
        final compact = viewport.maxWidth < 760;
        return Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(pad, 18, pad, 28),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: Dt.contentMaxWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _SearchField(
                            controller: _searchController,
                            query: _query,
                            onChanged: (v) => setState(() => _query = v),
                            onClear: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                          Text(
                            _query.isEmpty
                                ? '${weeks.length} '
                                      '${weeks.length == 1 ? 'week' : 'weeks'} '
                                      'recorded'
                                : '${filtered.length} of ${weeks.length} '
                                      'weeks match',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Dt.textMuted(theme),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: Text(
                            'No weeks match "$_query".',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Dt.textMuted(theme),
                            ),
                          ),
                        )
                      else
                        for (final (i, g) in groups.indexed) ...[
                          FadeSlideIn(
                            index: i,
                            child: _MonthPanel(
                              month: g.month,
                              weeks: g.weeks,
                              compact: compact,
                              now: now,
                              openLabel: widget.readOnly ? 'View' : 'Open',
                              onOpen: _openWeek,
                              onDelete: widget.readOnly ? null : _confirmDelete,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openWeek(int weekId) {
    final actions = ref.read(appActionsProvider);
    if (widget.readOnly) {
      final week = ref
          .read(historyProvider)
          .firstWhere((w) => w.week.id == weekId)
          .week;
      actions.openWeekReport(week.startDate);
    } else {
      actions.selectTab(AppTab.week, weekId: weekId);
    }
  }

  Future<void> _confirmDelete(int weekId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete week?'),
        content: const Text(
          'This removes the week, its five days and all recorded client '
          'numbers. You can undo it straight after.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final week = ref
          .read(historyProvider)
          .where((w) => w.week.id == weekId)
          .firstOrNull
          ?.week;
      final removed = ref.read(weekRepositoryProvider).deleteWeek(weekId);
      ref.read(dataVersionProvider.notifier).bump();
      if (!mounted) return;
      showUndoSnack(
        context,
        week == null
            ? 'Week deleted'
            : 'Deleted ${weekRangeLabel(week.startDate, week.endDate)}',
        () {
          removed.restore(ref.read(databaseProvider));
          ref.read(dataVersionProvider.notifier).bump();
        },
      );
    }
  }
}

/// Matches a week summary against a search query.
///
/// Weeks are searchable by their month-name label ("September") AND by any
/// date written as DD/MM/YYYY, D/M/YYYY or DD/MM (year inferred) — matching
/// the format shown in the app and promised by the search field's hint.
bool weekMatchesQuery(WeekSummary summary, String rawQuery) {
  final query = rawQuery.trim().toLowerCase();
  if (query.isEmpty) return true;
  final label = weekRangeLabel(
    summary.week.startDate,
    summary.week.endDate,
  ).toLowerCase();
  if (label.contains(query) || TextSearch(rawQuery).matches(label)) {
    return true;
  }

  // Date search: accept DD/MM/YYYY, D/M/YYYY or DD/MM (current year).
  final datePart = query.split(RegExp(r'\s+')).last;
  final m = RegExp(r'^(\d{1,2})/(\d{1,2})(?:/(\d{4}))?$').firstMatch(datePart);
  if (m != null) {
    final day = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final year = m.group(3) != null
        ? int.parse(m.group(3)!)
        : DateTime.now().year;
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      final start = summary.week.startDate;
      final end = summary.week.endDate;
      // Iterate the actual dates so a week crossing New Year matches searches
      // for both calendar years instead of requiring every date to share the
      // week's start year.
      final searchYear = m.group(3) == null ? DateTime.now().year : year;
      for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
        if (d.day == day && d.month == month && d.year == searchYear) {
          return true;
        }
      }
    }
  }
  return false;
}

// ---------------------------------------------------------------- widgets ---

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.query,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: SizedBox(
        height: 40,
        child: TextField(
          controller: controller,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 17),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 40,
            ),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: onClear,
                  ),
            hintText: MediaQuery.sizeOf(context).width < 900
                ? 'Month or date, e.g. September'
                : 'Search by month or date, e.g. September or 28/09/2026',
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// Column widths shared by a month panel's header and rows.
const double _numW = 72;
const double _barsW = 150;
const double _actionsW = 128;

/// One month: a panel whose header carries the month's totals, then a row
/// per week.
class _MonthPanel extends StatelessWidget {
  const _MonthPanel({
    required this.month,
    required this.weeks,
    required this.compact,
    required this.now,
    required this.openLabel,
    required this.onOpen,
    required this.onDelete,
  });

  final DateTime month;
  final List<WeekSummary> weeks;
  final bool compact;
  final DateTime now;
  final String openLabel;
  final ValueChanged<int> onOpen;

  /// Null hides Delete (read-only view).
  final ValueChanged<int>? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clients = weeks.fold<int>(0, (a, w) => a + w.totals.total);
    final head = (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
      fontSize: 12,
      color: Dt.textMuted(theme),
    );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    DateFormat('MMMM y').format(month),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  '${weeks.length} ${weeks.length == 1 ? 'week' : 'weeks'} · '
                  '$clients clients',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (!compact)
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Expanded(child: Text('Week', style: head)),
                  SizedBox(
                    width: _numW,
                    child: Text('New', style: head, textAlign: TextAlign.right),
                  ),
                  SizedBox(
                    width: _numW,
                    child: Text(
                      'Existing',
                      style: head,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: _numW,
                    child: Text(
                      'Total',
                      style: head,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: _barsW,
                    child: Text('Mon – Fri', style: head),
                  ),
                  const SizedBox(width: _actionsW),
                ],
              ),
            ),
          for (var i = 0; i < weeks.length; i++)
            _WeekRow(
              key: ValueKey('week-${weeks[i].week.id}'),
              summary: weeks[i],
              isCurrent: weeks[i].week.containsDate(now),
              compact: compact,
              last: i == weeks.length - 1,
              openLabel: openLabel,
              onOpen: () => onOpen(weeks[i].week.id),
              onDelete: onDelete == null
                  ? null
                  : () => onDelete!(weeks[i].week.id),
            ),
          // The month's totals (Clarity: a bold footer row).
          if (!compact && weeks.length > 1)
            Container(
              key: ValueKey('month-total-${month.year}-${month.month}'),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: context.clarity.bg,
                border: Border(top: BorderSide(color: scheme.outline)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${DateFormat('MMMM').format(month)} total',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  for (final n in [
                    weeks.fold<int>(0, (a, w) => a + w.totals.newClients),
                    weeks.fold<int>(0, (a, w) => a + w.totals.existingClients),
                    clients,
                  ])
                    SizedBox(
                      width: _numW,
                      child: Text(
                        '$n',
                        textAlign: TextAlign.right,
                        style: Dt.tab(theme.textTheme.bodyMedium!)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  const SizedBox(width: 24 + _barsW + _actionsW),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One week: its dates, new / existing / total, a bar per day, and actions.
/// Clicking the row opens the week in the tracker.
class _WeekRow extends ConsumerWidget {
  const _WeekRow({
    super.key,
    required this.summary,
    required this.isCurrent,
    required this.compact,
    required this.last,
    required this.openLabel,
    required this.onOpen,
    required this.onDelete,
  });

  final WeekSummary summary;
  final bool isCurrent;
  final bool compact;
  final bool last;
  final String openLabel;
  final VoidCallback onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final days = ref.watch(weekRepositoryProvider).getDays(summary.week.id);
    final perDay = [
      for (final d in days)
        (date: d.date, total: summary.totals.perDay[d.id]?.total ?? 0),
    ];

    Widget count(int v, {Color? color, bool bold = false}) => Text(
      v == 0 ? '–' : '$v',
      textAlign: TextAlign.right,
      style: Dt.tab(theme.textTheme.bodyMedium!).copyWith(
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        color: v == 0 ? Dt.textFaint(theme) : color,
      ),
    );

    // Wraps (badge under the dates) rather than cutting the dates short.
    final title = Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          weekRangeLabel(summary.week.startDate, summary.week.endDate),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (isCurrent) const _ThisWeekBadge(),
      ],
    );
    final range = Text(
      '${displayDate(summary.week.startDate)} – '
      '${displayDate(summary.week.endDate)}',
      style: Dt.tab(theme.textTheme.labelSmall!)
          .copyWith(color: Dt.textMuted(theme)),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(onPressed: onOpen, child: Text(openLabel)),
        if (onDelete != null)
          IconButton(
            tooltip: 'Delete week',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.delete_outline, size: 17, color: scheme.error),
            onPressed: onDelete,
          ),
      ],
    );
    final border = last
        ? null
        : Border(
            bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.6)),
          );

    if (compact) {
      return InkWell(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 10, 6, 10),
          decoration: BoxDecoration(border: border),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    const SizedBox(height: 2),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${summary.totals.newClients} new',
                            style: TextStyle(
                              color: Dt.newGreen(theme.brightness),
                            ),
                          ),
                          const TextSpan(text: '  ·  '),
                          TextSpan(
                            text: '${summary.totals.existingClients} existing',
                            style: TextStyle(
                              color: Dt.existingBlue(theme.brightness),
                            ),
                          ),
                          TextSpan(text: '  ·  ${summary.totals.total} total'),
                        ],
                      ),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Dt.textMuted(theme),
                      ),
                    ),
                  ],
                ),
              ),
              actions,
            ],
          ),
        ),
      );
    }

    return InkWell(
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.only(left: 14, top: 10, bottom: 10),
        decoration: BoxDecoration(border: border),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [title, const SizedBox(height: 2), range],
              ),
            ),
            SizedBox(
              width: _numW,
              child: count(
                summary.totals.newClients,
                color: Dt.newGreen(theme.brightness),
              ),
            ),
            SizedBox(
              width: _numW,
              child: count(
                summary.totals.existingClients,
                color: Dt.existingBlue(theme.brightness),
              ),
            ),
            SizedBox(
              width: _numW,
              child: count(summary.totals.total, bold: true),
            ),
            const SizedBox(width: 24),
            SizedBox(
              width: _barsW,
              child: _DayBars(days: perDay),
            ),
            SizedBox(
              width: _actionsW,
              child: Align(alignment: Alignment.centerRight, child: actions),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small neutral badge marking the week that contains today.
class _ThisWeekBadge extends StatelessWidget {
  const _ThisWeekBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(Dt.rPill),
      ),
      child: Text(
        'This week',
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: Dt.textMuted(theme),
        ),
      ),
    );
  }
}

/// Five small bars, one per weekday, scaled to the week's busiest day; the
/// exact numbers are in each bar's tooltip.
class _DayBars extends StatelessWidget {
  const _DayBars({required this.days});

  final List<({DateTime date, int total})> days;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final max = days.fold<int>(0, (m, d) => d.total > m ? d.total : m);
    const h = 22.0;
    return SizedBox(
      height: h,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final d in days)
            Expanded(
              child: Tooltip(
                message:
                    '${DateFormat('EEE d MMM').format(d.date)}: '
                    '${d.total} ${d.total == 1 ? 'client' : 'clients'}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Container(
                    height: d.total == 0 || max == 0
                        ? 2
                        : (h * d.total / max).clamp(3.0, h),
                    decoration: BoxDecoration(
                      color: d.total == 0
                          ? scheme.onSurface.withValues(alpha: 0.12)
                          : scheme.onSurface.withValues(alpha: 0.55),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
