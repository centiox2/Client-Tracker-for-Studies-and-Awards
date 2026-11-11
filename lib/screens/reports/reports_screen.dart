import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/application_repository.dart';
import '../../repositories/report_repository.dart';
import '../../repositories/revenue_repository.dart';
import '../../services/export_actions.dart';
import '../../services/fullscreen.dart';
import '../../services/report_export.dart';
import '../../state/app_state.dart';
import '../../widgets/clarity.dart';
import '../../widgets/motion.dart';
import '../../widgets/panels.dart';
import '../applications/applications_screen.dart' show ApplicationUpdateRow;

part 'quick_view.dart';
part 'report_charts.dart';
part 'report_trends.dart';
part 'staff_profile.dart';
part 'tv_view.dart';
part 'daily_summary.dart';

enum ReportPeriod { day, week, month, year }

/// The three ways to look at the numbers.
enum _View { quick, details, trends }

/// Who saw how many clients, for a day, a week or a month. Open to anyone
/// without signing in (read-only); the admin also gets "Edit in tracker".
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  /// Quick view (what's going on now), the detailed period report, or
  /// longer-term trends.
  _View _view = _View.quick;
  ReportPeriod _period = ReportPeriod.week;

  /// Compare with the same period a year earlier instead of the one before.
  bool _vsLastYear = false;
  DateTime _anchor = _lastWeekday(DateTime.now());

  @override
  void initState() {
    super.initState();
    // Opened from History's "View report": show that week in Details.
    final requested = ref.read(reportWeekRequestProvider);
    if (requested != null) {
      _view = _View.details;
      _period = ReportPeriod.week;
      _anchor = requested;
      // Cleared after the build, so a later visit opens on Quick view.
      Future.microtask(
        () => ref.read(reportWeekRequestProvider.notifier).set(null),
      );
    }
  }

  (DateTime, DateTime) get _range {
    final a = DateTime(_anchor.year, _anchor.month, _anchor.day);
    return switch (_period) {
      ReportPeriod.day => (a, a),
      ReportPeriod.week => (
        a.subtract(Duration(days: a.weekday - 1)),
        a.subtract(Duration(days: a.weekday - 5)),
      ),
      ReportPeriod.month => (
        DateTime(a.year, a.month, 1),
        DateTime(a.year, a.month + 1, 0),
      ),
      ReportPeriod.year => (DateTime(a.year, 1, 1), DateTime(a.year, 12, 31)),
    };
  }

  void _step(int delta) => setState(() {
    _anchor = switch (_period) {
      ReportPeriod.day => _stepWeekday(_anchor, delta),
      ReportPeriod.week => _anchor.add(Duration(days: 7 * delta)),
      ReportPeriod.month => DateTime(_anchor.year, _anchor.month + delta, 1),
      ReportPeriod.year => DateTime(_anchor.year + delta, 1, 1),
    };
  });

  bool get _isCurrent {
    final (from, to) = _range;
    final today = DateTime.now();
    final t = DateTime(today.year, today.month, today.day);
    return !t.isBefore(from) && !t.isAfter(to) ||
        (_period == ReportPeriod.day && _sameDay(_anchor, _lastWeekday(t)));
  }

  /// The period before, for comparisons. A period still in progress is
  /// compared with the same point in the previous one (this week so far vs
  /// last week up to the same weekday), so half a week isn't measured
  /// against a whole one.
  (DateTime, DateTime) get _previousRange {
    final (from, to) = _range;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final end = to.isAfter(today) && !from.isAfter(today) ? today : to;
    if (_vsLastYear || _period == ReportPeriod.year) {
      // 52 weeks back keeps weekdays aligned (Monday with Monday); months
      // and years compare like for like.
      const year = Duration(days: 364);
      return switch (_period) {
        ReportPeriod.day ||
        ReportPeriod.week => (from.subtract(year), end.subtract(year)),
        ReportPeriod.month || ReportPeriod.year => (
          DateTime(from.year - 1, from.month, 1),
          DateTime(
            end.year - 1,
            end.month,
            end.day.clamp(1, DateTime(end.year - 1, end.month + 1, 0).day),
          ),
        ),
      };
    }
    return switch (_period) {
      ReportPeriod.day => (_stepWeekday(from, -1), _stepWeekday(from, -1)),
      ReportPeriod.week => (
        from.subtract(const Duration(days: 7)),
        end.subtract(const Duration(days: 7)),
      ),
      ReportPeriod.month => (
        DateTime(from.year, from.month - 1, 1),
        // Same day-of-month last month, clamped to that month's length.
        DateTime(
          from.year,
          from.month - 1,
          end.day.clamp(1, DateTime(from.year, from.month, 0).day),
        ),
      ),
      ReportPeriod.year => throw StateError('handled above'),
    };
  }

  String get _previousLabel => _vsLastYear
      ? switch (_period) {
          ReportPeriod.day => 'same day last year',
          ReportPeriod.week => 'same week last year',
          ReportPeriod.month => 'same month last year',
          ReportPeriod.year => 'last year',
        }
      : switch (_period) {
          ReportPeriod.day => 'previous day',
          ReportPeriod.week => 'last week',
          ReportPeriod.month => 'last month',
          ReportPeriod.year => 'last year',
        };

  String get _label {
    final (from, to) = _range;
    return switch (_period) {
      ReportPeriod.day => DateFormat('EEEE d MMMM y').format(from),
      ReportPeriod.week =>
        'Week of ${DateFormat('d MMM').format(from)} – '
            '${DateFormat('d MMM y').format(to)}',
      ReportPeriod.month => DateFormat('MMMM y').format(from),
      ReportPeriod.year => DateFormat('y').format(from),
    };
  }

  @override
  Widget build(BuildContext context) {
    final report = ref.watch(reportProvider(_range));
    final previous = ref.watch(reportProvider(_previousRange));
    // Admin and admin team can jump from a report to edit its week.
    final isAdmin = ref.watch(canEditProvider);
    final theme = Theme.of(context);
    final ranged = _period != ReportPeriod.day && report.days.isNotEmpty;
    final yearly = _period == ReportPeriod.year;
    final prior = previous.days.isEmpty ? null : previous;

    return LayoutBuilder(
      builder: (context, viewport) {
        final compact = viewport.maxWidth < 760;
        final pad = clarityHPad(context);
        return ListView(
          padding: EdgeInsets.fromLTRB(pad, 18, pad, 28),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Dt.contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    UnderlineTabs<_View>(
                      key: const ValueKey('reports-view'),
                      tabs: const [
                        (_View.quick, 'Quick view'),
                        (_View.details, 'Details'),
                        (_View.trends, 'Trends'),
                      ],
                      selected: _view,
                      onChanged: (v) => setState(() => _view = v),
                      trailing: _view != _View.quick
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: compact
                                  ? [
                                      IconButton(
                                        tooltip: 'Share summary',
                                        onPressed: () =>
                                            showDailySummary(context),
                                        icon: const Icon(Icons.ios_share),
                                      ),
                                      IconButton(
                                        tooltip: 'TV mode',
                                        onPressed: () => openTvView(context),
                                        icon: const Icon(Icons.tv),
                                      ),
                                    ]
                                  : [
                                      OutlinedButton.icon(
                                        onPressed: () =>
                                            showDailySummary(context),
                                        icon: const Icon(Icons.ios_share),
                                        label: const Text('Share summary'),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: () => openTvView(context),
                                        icon: const Icon(Icons.tv),
                                        label: const Text('TV mode'),
                                      ),
                                    ],
                            ),
                    ),
                    const SizedBox(height: 16),
                    if (_view != _View.details)
                      FadeThroughSwitcher(
                        child: _view == _View.quick
                            ? _QuickView(
                                key: const ValueKey('quick'),
                                compact: compact,
                              )
                            : _TrendsView(
                                key: const ValueKey('trends'),
                                compact: compact,
                              ),
                      )
                    else ...[
                      _Toolbar(
                        period: _period,
                        label: _label,
                        isCurrent: _isCurrent,
                        lastUpdated: report.lastUpdated,
                        onPeriod: (p) => setState(() => _period = p),
                        vsLastYear: _vsLastYear,
                        onVsLastYear: (v) => setState(() => _vsLastYear = v),
                        onStep: _step,
                        onToday: () => setState(
                          () => _anchor = _lastWeekday(DateTime.now()),
                        ),
                        editWeekId:
                            isAdmin &&
                                (_period == ReportPeriod.day ||
                                    _period == ReportPeriod.week)
                            ? report.days.firstOrNull?.weekId
                            : null,
                        report: report,
                        previous: prior,
                      ),
                      const SizedBox(height: 14),
                      _Kpis(
                        target: ref.watch(dailyTargetProvider),
                        report: report,
                        previous: prior,
                        against: _previousLabel,
                        period: _period,
                        compact: compact,
                      ),
                      if (ranged) ...[
                        const SizedBox(height: 12),
                        _Panel(
                          title: yearly ? 'Clients by month' : 'Clients by day',
                          icon: Icons.bar_chart,
                          trailingWidget: const _Legend(),
                          child: yearly
                              ? _BucketBars(
                                  buckets: report.months,
                                  label: (m) => DateFormat('MMM').format(m),
                                  tooltip: (m) =>
                                      DateFormat('MMMM y').format(m),
                                )
                              : _DayBars(days: report.days),
                        ),
                      ],
                      const SizedBox(height: 12),
                      _Panel(
                        title: 'Clients by staff',
                        icon: Icons.groups_outlined,
                        trailing: report.days.isEmpty
                            ? null
                            : '${report.staffWithClients} of '
                                  '${report.staff.length} saw clients',
                        child: report.days.isEmpty
                            ? _Empty(period: _period)
                            : _StaffTable(
                                report: report,
                                previous: prior,
                                against: _previousLabel,
                                compact: compact,
                              ),
                      ),
                      if (ranged && yearly) ...[
                        const SizedBox(height: 12),
                        _Panel(
                          title: 'Month by month',
                          icon: Icons.calendar_month_outlined,
                          child: _BucketTable(
                            buckets: report.months,
                            label: (m) => DateFormat('MMMM').format(m),
                            compact: compact,
                          ),
                        ),
                      ] else if (ranged) ...[
                        const SizedBox(height: 12),
                        _Panel(
                          title: 'Staff by day',
                          icon: Icons.grid_on_outlined,
                          child: _StaffDayMatrix(report: report),
                        ),
                        const SizedBox(height: 12),
                        _Panel(
                          title: 'Day by day',
                          icon: Icons.calendar_view_day_outlined,
                          child: _DayTable(
                            report: report,
                            compact: compact,
                            onOpenWeek: isAdmin
                                ? (weekId) => ref
                                      .read(appActionsProvider)
                                      .selectTab(AppTab.week, weekId: weekId)
                                : null,
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 10),
                    Text(
                      'Numbers for staff marked off are excluded. The daily '
                      'average counts working days so far, skipping holidays.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: Dt.textFaint(theme),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ------------------------------------------------------------- toolbar ----

class _Toolbar extends ConsumerWidget {
  const _Toolbar({
    required this.period,
    required this.label,
    required this.isCurrent,
    required this.lastUpdated,
    required this.onPeriod,
    required this.vsLastYear,
    required this.onVsLastYear,
    required this.onStep,
    required this.onToday,
    required this.editWeekId,
    required this.report,
    this.previous,
  });

  /// The comparison period (for the downloads).
  final Report? previous;

  /// Comparing with a year earlier rather than the previous period.
  final bool vsLastYear;
  final ValueChanged<bool> onVsLastYear;

  /// The period on screen, for the Download menu.
  final Report report;

  final ReportPeriod period;
  final String label;
  final bool isCurrent;
  final DateTime? lastUpdated;
  final ValueChanged<ReportPeriod> onPeriod;
  final ValueChanged<int> onStep;
  final VoidCallback onToday;

  /// Set for the admin on a day/week view: opens that week in the tracker.
  final int? editWeekId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final unit = switch (period) {
      ReportPeriod.day => 'day',
      ReportPeriod.week => 'week',
      ReportPeriod.month => 'month',
      ReportPeriod.year => 'year',
    };
    final segments = SegmentedButton<ReportPeriod>(
      segments: const [
        ButtonSegment(value: ReportPeriod.day, label: Text('Day')),
        ButtonSegment(value: ReportPeriod.week, label: Text('Week')),
        ButtonSegment(value: ReportPeriod.month, label: Text('Month')),
        ButtonSegment(value: ReportPeriod.year, label: Text('Year')),
      ],
      selected: {period},
      showSelectedIcon: false,
      // Four segments must fit a phone: full width, equal segments.
      expandedInsets: MediaQuery.sizeOf(context).width < 600
          ? EdgeInsets.zero
          : null,
      style: MediaQuery.sizeOf(context).width < 600 ? Dt.phoneSegments : null,
      onSelectionChanged: (s) => onPeriod(s.first),
    );
    final navigator = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Previous $unit',
          visualDensity: VisualDensity.compact,
          onPressed: () => onStep(-1),
          icon: const Icon(Icons.chevron_left, size: 18),
        ),
        IconButton(
          tooltip: 'Next $unit',
          visualDensity: VisualDensity.compact,
          onPressed: () => onStep(1),
          icon: const Icon(Icons.chevron_right, size: 18),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (!isCurrent) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: onToday, child: const Text('Today')),
        ],
      ],
    );
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        segments,
        // On a phone the Wrap puts this on its own line, and the flexible
        // label ellipsizes instead of overflowing.
        navigator,
        Wrap(
          spacing: 0,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (lastUpdated != null)
              Text(
                'Last entry ${_relative(lastUpdated!)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Dt.textMuted(theme),
                ),
              ),
            if (period != ReportPeriod.year) ...[
              const SizedBox(width: 10),
              PopupMenuButton<bool>(
                tooltip: 'What to compare with',
                position: PopupMenuPosition.under,
                initialValue: vsLastYear,
                onSelected: onVsLastYear,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: false,
                    child: Text('Compare with the previous $unit'),
                  ),
                  PopupMenuItem(
                    value: true,
                    child: Text('Compare with the same $unit last year'),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.compare_arrows,
                        size: 15,
                        color: Dt.textMuted(theme),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        vsLastYear ? 'vs last year' : 'vs previous $unit',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Dt.textMuted(theme),
                        ),
                      ),
                      Icon(
                        Icons.arrow_drop_down,
                        size: 16,
                        color: Dt.textMuted(theme),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(width: 10),
            _DownloadMenu(report: report, title: label, previous: previous),
            if (editWeekId != null) ...[
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => ref
                    .read(appActionsProvider)
                    .selectTab(AppTab.week, weekId: editWeekId),
                icon: const Icon(Icons.edit_outlined, size: 14),
                label: const Text('Edit in tracker'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  static String _relative(DateTime t) {
    final now = DateTime.now();
    if (_sameDay(t, now)) return 'today at ${DateFormat('HH:mm').format(t)}';
    if (_sameDay(t, now.subtract(const Duration(days: 1)))) {
      return 'yesterday at ${DateFormat('HH:mm').format(t)}';
    }
    return DateFormat('d MMM, HH:mm').format(t);
  }
}

// ---------------------------------------------------------------- KPIs ----

class _Kpis extends StatelessWidget {
  const _Kpis({
    required this.target,
    required this.report,
    required this.previous,
    required this.against,
    required this.period,
    required this.compact,
  });

  final Report report;

  /// Daily client target from Settings (null: none set).
  final int? target;

  /// The previous period (null when it wasn't tracked): adds "vs" lines.
  final Report? previous;
  final String against;
  final ReportPeriod period;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final avg = report.dailyAverage;
    Widget? vs(int current, int Function(Report) of) => previous == null
        ? null
        : _Delta(current: current, previous: of(previous!), against: against);
    final tiles = <(String, String, String, Color?, Widget?)>[
      (
        'Total clients',
        '${report.total}',
        'New + existing',
        null,
        vs(report.total, (r) => r.total),
      ),
      (
        'New clients',
        '${report.newClients}',
        _share(report.newClients, report.total),
        Dt.newGreen(theme.brightness),
        vs(report.newClients, (r) => r.newClients),
      ),
      (
        'Existing clients',
        '${report.existingClients}',
        _share(report.existingClients, report.total),
        Dt.existingBlue(theme.brightness),
        vs(report.existingClients, (r) => r.existingClients),
      ),
      if (period != ReportPeriod.day)
        (
          'Average per day',
          avg == avg.roundToDouble()
              ? avg.toStringAsFixed(0)
              : avg.toStringAsFixed(1),
          target == null
              ? '${report.staffedDaysSoFar} working '
                    '${report.staffedDaysSoFar == 1 ? 'day' : 'days'} so far'
              : 'Target $target / day',
          null,
          target == null
              ? null
              : _TargetBar(value: avg, target: target!.toDouble()),
        ),
      (
        'Staff who saw clients',
        '${report.staffWithClients}',
        'of ${report.staff.length} on the rota',
        null,
        null,
      ),
    ];
    return _TileGrid(
      perRow: compact ? 2 : tiles.length,
      children: [
        for (final (label, value, caption, color, footer) in tiles)
          _Tile(
            label: label,
            value: value,
            caption: caption,
            color: color,
            footer: footer,
          ),
      ],
    );
  }

  static String _share(int part, int total) =>
      total == 0 ? '–' : '${(part * 100 / total).round()}% of all clients';
}

/// Tiles in rows of [perRow], every tile in a row the same height (one
/// with a comparison line doesn't stand taller than its neighbour). A short
/// last row keeps the same column widths.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.perRow, required this.children});
  final int perRow;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final n = perRow < 1 ? 1 : perRow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var start = 0; start < children.length; start += n) ...[
          if (start > 0) const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < n; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(
                    child: start + i < children.length
                        ? children[start + i]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.value,
    required this.caption,
    this.color,
    this.footer,
    this.unit,
  });

  final String label;
  final String value;
  final String caption;
  final Color? color;

  /// Optional extra line, e.g. a "vs last week" comparison.
  final Widget? footer;

  /// Shown small before the value (e.g. "KSh"), so a money figure reads at
  /// the same weight as the plain numbers beside it.
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    // The Clarity KPI card: label, the big number, then the caption.
    return FadeSlideIn(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(Dt.rMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: 10),
            // Shrinks a long value ("Wednesday") rather than cutting it off.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  if (unit != null) ...[
                    Text(
                      unit!,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: c.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  AnimatedValueText(
                    value,
                    maxLines: 1,
                    style: Dt.tab(theme.textTheme.displaySmall!)
                        .copyWith(color: color),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: c.textMuted),
            ),
            if (footer != null) ...[
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 18),
                child: footer,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- panels ----

class _Panel extends StatelessWidget {
  const _Panel({
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
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

class _Empty extends StatelessWidget {
  const _Empty({required this.period});
  final ReportPeriod period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final what = switch (period) {
      ReportPeriod.day => 'this day',
      ReportPeriod.week => 'this week',
      ReportPeriod.month => 'this month',
      ReportPeriod.year => 'this year',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      child: Text(
        'Nothing tracked for $what yet.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- tables ----

/// A simple aligned table: first column flexes, the rest are fixed width
/// and right-aligned numbers.
class _Row extends StatelessWidget {
  const _Row({
    required this.cells,
    required this.widths,
    this.header = false,
    this.last = false,
    this.onTap,
  });

  final List<Widget> cells;
  final List<double> widths;
  final bool header;
  final bool last;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final row = Container(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: header ? 8 : 9),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(
                bottom: BorderSide(
                  color: scheme.outline.withValues(alpha: header ? 1 : 0.6),
                ),
              ),
      ),
      child: Row(
        children: [
          Expanded(child: cells.first),
          for (var i = 1; i < cells.length; i++)
            SizedBox(
              width: widths[i - 1],
              child: Align(alignment: Alignment.centerRight, child: cells[i]),
            ),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

TextStyle _headStyle(ThemeData theme) =>
    (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
      fontSize: 10.5,
      color: Dt.textMuted(theme),
    );

TextStyle _num(ThemeData theme, {Color? color, bool bold = false}) => Dt.tab(
  theme.textTheme.bodyMedium!,
).copyWith(color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w500);

Widget _count(ThemeData theme, int v, {Color? color, bool bold = false}) =>
    Text(
      v == 0 ? '–' : '$v',
      style: _num(
        theme,
        color: v == 0 ? Dt.textFaint(theme) : color,
        bold: bold,
      ),
    );

class _StaffTable extends StatelessWidget {
  const _StaffTable({
    required this.report,
    required this.compact,
    this.previous,
    this.against = '',
  });

  final Report report;
  final bool compact;

  /// The period compared with: adds a per-person change column.
  final Report? previous;
  final String against;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = _headStyle(theme);
    final newC = Dt.newGreen(theme.brightness);
    final exC = Dt.existingBlue(theme.brightness);
    final top = report.staff.isEmpty ? 0 : report.staff.first.total;
    final before = previous == null
        ? null
        : {for (final s in previous!.staff) s.staffId: s.total};
    final widths = compact
        ? const [52.0, 64.0, 52.0]
        : [64.0, 72.0, 64.0, if (before != null) 76.0, 150.0, 84.0, 84.0, 64.0];

    return Column(
      children: [
        _Row(
          header: true,
          widths: widths,
          cells: [
            Text('Staff', style: head),
            Text('New', style: head),
            Text('Existing', style: head),
            Text('Total', style: head),
            if (!compact) ...[
              if (before != null)
                Tooltip(
                  message: 'Change vs $against',
                  child: Text('Change', style: head),
                ),
              Text('Share of clients', style: head),
              Text('Avg / day', style: head),
              Text('Days worked', style: head),
              Text('Days off', style: head),
            ],
          ],
        ),
        for (var i = 0; i < report.staff.length; i++)
          () {
            final s = report.staff[i];
            final share = report.total == 0 ? 0.0 : s.total / report.total;
            return _Row(
              last: i == report.staff.length - 1,
              widths: widths,
              onTap: () => showStaffProfile(context, s.staffId),
              cells: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        s.name,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: s.total == 0 ? Dt.textMuted(theme) : null,
                        ),
                      ),
                    ),
                    if (!s.active) ...[
                      const SizedBox(width: 6),
                      Text(
                        'inactive',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Dt.textFaint(theme),
                        ),
                      ),
                    ],
                  ],
                ),
                _count(theme, s.newClients, color: newC),
                _count(theme, s.existingClients, color: exC),
                _count(theme, s.total, bold: true),
                if (!compact) ...[
                  if (before != null)
                    _ChangeCell(current: s.total, previous: before[s.staffId]),
                  _ShareBar(
                    share: share,
                    relative: top == 0 ? 0 : s.total / top,
                  ),
                  Tooltip(
                    message: 'Clients per day worked so far',
                    child: Text(
                      s.daysWorked == 0 || s.total == 0
                          ? '–'
                          : _QuickView._avg(s.total / s.daysWorked),
                      style: _num(
                        theme,
                        color: s.daysWorked == 0 || s.total == 0
                            ? Dt.textFaint(theme)
                            : null,
                      ),
                    ),
                  ),
                  Text(
                    '${s.daysWorked}',
                    style: _num(theme, color: Dt.textMuted(theme)),
                  ),
                  Text(
                    s.daysOff == 0 ? '–' : '${s.daysOff}',
                    style: _num(
                      theme,
                      color: s.daysOff == 0
                          ? Dt.textFaint(theme)
                          : Dt.textMuted(theme),
                    ),
                  ),
                ],
              ],
            );
          }(),
      ],
    );
  }
}

/// Bar scaled to the top performer, with the % of all clients beside it.
class _ShareBar extends StatelessWidget {
  const _ShareBar({required this.share, required this.relative});

  /// Fraction of all clients in the period.
  final double share;

  /// Fraction of the top performer's total (bar length).
  final double relative;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 100,
          height: 6,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Stack(
              children: [
                Container(color: context.clarity.track),
                AnimatedFraction(
                  fraction: relative,
                  color: context.clarity.accent,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 34,
          child: Text(
            share == 0 ? '–' : '${(share * 100).round()}%',
            textAlign: TextAlign.right,
            style: _num(theme, color: Dt.textMuted(theme)),
          ),
        ),
      ],
    );
  }
}

class _DayTable extends StatelessWidget {
  const _DayTable({
    required this.report,
    required this.onOpenWeek,
    this.compact = false,
  });

  final Report report;

  /// Phone width: narrower columns, no "Staff off" column.
  final bool compact;

  /// Admin only: tapping a day opens its week in the tracker.
  final ValueChanged<int>? onOpenWeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = _headStyle(theme);
    final now = DateTime.now();
    final widths = compact
        ? const [40.0, 60.0, 44.0]
        : const [64.0, 72.0, 64.0, 96.0];

    return Column(
      children: [
        _Row(
          header: true,
          widths: widths,
          cells: [
            Text('Day', style: head),
            Text('New', style: head),
            Text('Existing', style: head),
            Text('Total', style: head),
            if (!compact) Text('Staff off', style: head),
          ],
        ),
        for (var i = 0; i < report.days.length; i++)
          () {
            final d = report.days[i];
            final note = d.isHoliday
                ? 'Holiday'
                : d.offCount == 0
                ? '–'
                : '${d.offCount}';
            return _Row(
              last: i == report.days.length - 1,
              widths: widths,
              onTap: onOpenWeek == null ? null : () => onOpenWeek!(d.weekId),
              cells: [
                Row(
                  children: [
                    if (d.note != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Tooltip(
                          message: d.note!,
                          child: Icon(
                            Icons.sticky_note_2_outlined,
                            size: 13,
                            color: Dt.textMuted(theme),
                          ),
                        ),
                      ),
                    Flexible(
                      child: Text(
                        DateFormat(compact ? 'EEE d' : 'EEE d MMM')
                            .format(d.date),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (_sameDay(d.date, now)) ...[
                      const SizedBox(width: 8),
                      Text(
                        'Today',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Dt.textMuted(theme),
                        ),
                      ),
                    ],
                  ],
                ),
                _count(
                  theme,
                  d.newClients,
                  color: Dt.newGreen(theme.brightness),
                ),
                _count(
                  theme,
                  d.existingClients,
                  color: Dt.existingBlue(theme.brightness),
                ),
                _count(theme, d.total, bold: true),
                if (!compact)
                  Text(
                    note,
                    style: _num(
                      theme,
                      color: note == '–'
                          ? Dt.textFaint(theme)
                          : Dt.textMuted(theme),
                    ),
                  ),
              ],
            );
          }(),
      ],
    );
  }
}

// -------------------------------------------------------------- helpers ----

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Today, or the previous Friday at the weekend (the day view's default).
DateTime _lastWeekday(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  if (day.weekday == DateTime.saturday) {
    return day.subtract(const Duration(days: 1));
  }
  if (day.weekday == DateTime.sunday) {
    return day.subtract(const Duration(days: 2));
  }
  return day;
}

/// Moves [delta] working days, skipping Saturdays and Sundays.
DateTime _stepWeekday(DateTime d, int delta) {
  var day = d;
  var left = delta.abs();
  while (left > 0) {
    day = day.add(Duration(days: delta.sign));
    if (day.weekday <= DateTime.friday) left--;
  }
  return day;
}

// ------------------------------------------------------------ downloads ----

/// "Download ▾": the period on screen as a full Excel workbook, or a
/// printable page (the browser's print dialog can save it as a PDF).
class _DownloadMenu extends ConsumerWidget {
  const _DownloadMenu({
    required this.report,
    required this.title,
    this.previous,
  });

  final Report report;
  final String title;

  /// The comparison period, summarised in the files when it was tracked.
  final Report? previous;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return PopupMenuButton<String>(
      tooltip: 'Download this report',
      position: PopupMenuPosition.under,
      onSelected: (kind) {
        final target = ref.read(dailyTargetProvider);
        // Revenue goes in only for the profiles allowed to see it.
        final revenue = ref.read(seesRevenueProvider)
            ? ref
                  .read(revenueRepositoryProvider)
                  .entriesBetween(report.from, report.to)
            : null;
        final currency = ref.read(currencyProvider);
        if (kind == 'xlsx') {
          deliverFile(
            context,
            dialogTitle: 'Save report as Excel',
            fileName: 'client_report_$slug.xlsx',
            extension: 'xlsx',
            bytes: reportToExcel(
              report,
              title: title,
              target: target,
              previous: previous?.days.isEmpty ?? true ? null : previous,
              revenue: revenue,
              currency: currency,
            ),
          );
        } else {
          deliverFile(
            context,
            dialogTitle: 'Save printable report',
            fileName: 'client_report_$slug.html',
            extension: 'html',
            bytes: reportToPrintableHtml(
              report,
              title: title,
              target: target,
              previous: previous?.days.isEmpty ?? true ? null : previous,
              revenue: revenue,
              currency: currency,
            ),
          );
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'xlsx',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.table_view_outlined, size: 18),
            title: Text('Excel workbook (.xlsx)'),
            subtitle: Text('Summary, staff, days and the full grid'),
          ),
        ),
        PopupMenuItem(
          value: 'print',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.print_outlined, size: 18),
            title: Text('Printable page / PDF'),
            subtitle: Text('Opens the print dialog — choose “Save as PDF”'),
          ),
        ),
      ],
      child: IgnorePointer(
        child: OutlinedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.download_outlined, size: 14),
          label: const Text('Download'),
        ),
      ),
    );
  }
}

/// Thin progress bar toward a target, with "62% of target" beside it.
class _TargetBar extends StatelessWidget {
  const _TargetBar({required this.value, required this.target});

  final double value;
  final double target;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fraction = target <= 0 ? 0.0 : value / target;
    final reached = fraction >= 1;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 5,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Stack(
                  children: [
                    Container(color: scheme.onSurface.withValues(alpha: 0.08)),
                    AnimatedFraction(
                      fraction: fraction,
                      color: reached
                          ? Dt.statusGreen(theme.brightness)
                          : scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            reached ? 'Target met' : '${(fraction * 100).round()}%',
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
