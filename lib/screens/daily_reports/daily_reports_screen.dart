import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/cloud/cloud_api.dart' show CloudException;
import '../../services/daily_report_export.dart';
import '../../services/daily_reports_service.dart';
import '../../services/export_actions.dart';
import '../../state/app_state.dart';
import '../../widgets/clarity.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/panels.dart';
import 'report_editor.dart';

/// Daily reports: everyone records the work they did each day ("My
/// reports"); department heads, the Operations Manager, admins and the
/// director also get the Overview — status totals, who has submitted,
/// department summaries, items needing attention, and exports.
class DailyReportsScreen extends ConsumerStatefulWidget {
  const DailyReportsScreen({super.key});

  @override
  ConsumerState<DailyReportsScreen> createState() => _DailyReportsScreenState();
}

enum _Tab { mine, overview }

/// The page as it was last opened on this device (for the account in
/// [ReportsStart.meta]): shown straight away next time while it reloads.
ReportsStart? _lastStart;

class _DailyReportsScreenState extends ConsumerState<DailyReportsScreen> {
  ReportsMeta? _meta;

  /// What the page opened with: your day's lists, so My reports needn't
  /// ask again. Null when only [_meta] could be read.
  ReportsStart? _start;
  Object? _error;
  _Tab? _tab;

  /// Goes up each time the page reloads (Refresh, a new day), so the views
  /// below reload too.
  int _refresh = 0;
  Timer? _refreshDebounce;

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final cached = _lastStart;
    final me = ref.read(currentUserProvider)?.id;
    if (cached != null && me != null && cached.meta.myId == me) {
      _start = cached;
      _meta = cached.meta;
      _tab = _firstTab(cached.meta);
    }
    _load();
  }

  /// People without a department (the Operations Manager, say) start on
  /// the Overview; everyone else on their own day.
  static _Tab _firstTab(ReportsMeta meta) =>
      meta.seesOthers && meta.myDepartmentId == null
      ? _Tab.overview
      : _Tab.mine;

  Future<void> _load() async {
    setState(() => _error = null);
    final service = ref.read(dailyReportsProvider);
    try {
      ReportsStart? start;
      ReportsMeta meta;
      try {
        // One round trip for the page and your day.
        start = await service.start();
        meta = start.meta;
      } on CloudException catch (e) {
        // An older online database without it: the page, then the lists.
        if (e.code != 'needs_update') rethrow;
        meta = await service.meta();
      }
      if (!mounted) return;
      if (start != null) _lastStart = start;
      setState(() {
        _meta = meta;
        _start = start;
        _refresh++;
        _tab ??= _firstTab(meta);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Refresh in the top bar, and the app noticing a new day, bump the data
    // version: read everything again (including what "today" is).
    ref.listen(dataVersionProvider, (_, _) {
      _refreshDebounce?.cancel();
      _refreshDebounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) _load();
      });
    });
    final meta = _meta;
    if (meta == null) {
      if (_error == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return EmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Daily reports aren’t available right now',
        message: describeReportError(_error!),
        actionLabel: 'Try again',
        onAction: _load,
      );
    }
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, viewport) {
        final phone = viewport.maxWidth < 600;
        final pad = clarityHPad(context);
        final tab = _tab ?? _Tab.mine;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(pad, 16, pad, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Dt.contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      // The page header already says "Daily reports": this
                      // line only says whose reports these are.
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.apartment_outlined,
                            size: 16,
                            color: Dt.textMuted(theme),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              meta.myDepartment?.name ??
                                  (meta.seesOthers
                                      ? 'Every department'
                                      : 'No department yet'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Dt.textMuted(theme),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (meta.seesOthers)
                        UnderlineTabs<_Tab>(
                          key: const ValueKey('reports-tab'),
                          tabs: const [
                            (_Tab.mine, 'My reports'),
                            (_Tab.overview, 'Overview'),
                          ],
                          selected: tab,
                          onChanged: (v) => setState(() => _tab = v),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (tab == _Tab.mine)
                    _MyReports(
                      meta: meta,
                      phone: phone,
                      refresh: _refresh,
                      start: _start,
                    )
                  else
                    _Overview(meta: meta, phone: phone, refresh: _refresh),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- My day ---

class _MyReports extends ConsumerStatefulWidget {
  const _MyReports({
    required this.meta,
    required this.phone,
    required this.refresh,
    this.start,
  });

  final ReportsMeta meta;
  final bool phone;
  final int refresh;

  /// Today's lists, already read with the page (null: read them here).
  final ReportsStart? start;

  @override
  ConsumerState<_MyReports> createState() => _MyReportsState();
}

class _MyReportsState extends ConsumerState<_MyReports> {
  late DateTime _day = widget.meta.today;
  List<ActivityReport>? _entries;
  List<ActivityReport>? _open;

  /// This week's reports (Monday to today), for "My week".
  List<ActivityReport>? _week;
  Object? _error;

  ReportsMeta get meta => widget.meta;

  DateTime get _monday =>
      meta.today.subtract(Duration(days: meta.today.weekday - 1));

  /// The newest load; an older one finishing late is ignored.
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    if (!_takeStart()) _load();
  }

  /// Uses the lists the page opened with, when they are for the day shown.
  bool _takeStart() {
    final start = widget.start;
    if (start == null || _day != start.meta.today) return false;
    _loadSeq++; // anything still loading is older
    _entries = start.day;
    _open = _soonestFirst(start.open);
    _week = start.week;
    _error = null;
    return true;
  }

  static List<ActivityReport> _soonestFirst(List<ActivityReport> open) =>
      [...open]..sort((a, b) {
        // Soonest due first; anything without a date last.
        final x = a.dueDate, y = b.dueDate;
        if (x == null || y == null) return x == null ? 1 : -1;
        return x.compareTo(y);
      });

  @override
  void didUpdateWidget(_MyReports old) {
    super.didUpdateWidget(old);
    if (old.refresh == widget.refresh) return;
    // A new day while the app was open: "today" moves on with it.
    if (old.meta.today != widget.meta.today && _day == old.meta.today) {
      _day = widget.meta.today;
    }
    if (!identical(old.start, widget.start) && _takeStart()) {
      setState(() {});
      return;
    }
    _load();
  }

  Future<void> _load() async {
    final seq = ++_loadSeq;
    final service = ref.read(dailyReportsProvider);
    try {
      final results = await Future.wait([
        service.list(ReportFilter(from: _day, to: _day, userId: meta.myId)),
        service.list(ReportFilter(userId: meta.myId, openOnly: true)),
        service.list(
          ReportFilter(from: _monday, to: meta.today, userId: meta.myId),
        ),
      ]);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _entries = results[0];
        _open = _soonestFirst(results[1]);
        _week = results[2];
        _error = null;
      });
    } catch (e) {
      if (mounted && seq == _loadSeq) setState(() => _error = e);
    }
  }

  void _moveDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(meta.today)) return;
    setState(() {
      _day = next;
      _entries = null;
    });
    _load();
  }

  Future<void> _add() async {
    final saved = await showReportEditor(context, meta: meta, day: _day);
    if (saved != null) await _load();
  }

  Future<void> _markDone(ActivityReport report) =>
      _setStatus(report, ReportStatus.completed);

  /// One tap: a new status, everything else as it was.
  Future<void> _setStatus(ActivityReport report, ReportStatus status) async {
    try {
      await ref.read(dailyReportsProvider).save(report.withStatus(status));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              status == ReportStatus.completed
                  ? 'Marked completed'
                  : 'Now ${status.label.toLowerCase()}',
            ),
          ),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeReportError(e))));
      }
    }
  }

  Future<void> _show(ActivityReport report) async {
    final changed = await showReportDetails(
      context,
      meta: meta,
      report: report,
    );
    if (changed) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    final dept = meta.myDepartment;
    if (dept == null) {
      return AppPanel(
        title: 'Not in a department yet',
        icon: Icons.info_outline,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Text(
            meta.seesOthers
                ? 'You can see the Overview. To record your own daily '
                      'reports, ask an admin to set your department in '
                      'Settings › Users.'
                : 'Ask an admin to set your department in Settings › Users. '
                      'Then you can record your daily reports here.',
            style: muted,
          ),
        ),
      );
    }
    final isToday = _day == meta.today;
    final entries = _entries;
    final open = _open;
    final dayTotals = <String, int>{};
    for (final e in entries ?? const <ActivityReport>[]) {
      e.outputs.forEach((k, v) => dayTotals[k] = (dayTotals[k] ?? 0) + v);
    }
    final dayLabel = DateFormat('EEEE, d MMMM y').format(_day);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              tooltip: 'Previous day',
              onPressed: () => _moveDay(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              isToday ? 'Today · $dayLabel' : dayLabel,
              key: const ValueKey('my-day'),
              style: theme.textTheme.titleSmall,
            ),
            IconButton(
              tooltip: 'Next day',
              onPressed: isToday ? null : () => _moveDay(1),
              icon: const Icon(Icons.chevron_right),
            ),
            if (!isToday)
              TextButton(
                onPressed: () => _moveDay(meta.today.difference(_day).inDays),
                child: const Text('Back to today'),
              ),
            FilledButton.icon(
              key: const ValueKey('add-activity'),
              onPressed: _add,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add activity'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(describeReportError(_error!), style: muted),
          ),
        AppPanel(
          title: isToday ? 'What I did today' : 'What I did',
          icon: Icons.checklist_outlined,
          trailing: entries == null ? null : '${entries.length}',
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: entries == null
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (entries.isEmpty)
                        PanelEmpty(
                          icon: Icons.edit_note_outlined,
                          title: isToday
                              ? 'Nothing recorded yet today'
                              : 'Nothing recorded for this day',
                          message: isToday
                              ? 'Add each piece of work you did, with '
                                    'numbers where you can (applications '
                                    'reviewed, calls made…).'
                              : null,
                        ),
                      for (final e in entries)
                        ReportTile(
                          report: e,
                          meta: meta,
                          today: meta.today,
                          onTap: () => _show(e),
                        ),
                      if (dayTotals.isNotEmpty) ...[
                        const Divider(height: 18),
                        Text(
                          'Outputs: ${[for (final t in dayTotals.entries) '${dept.outputLabel(t.key)} ${t.value}'].join(' · ')}',
                          style: muted,
                        ),
                      ],
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),
        AppPanel(
          title: 'My open items',
          icon: Icons.pending_actions_outlined,
          trailing: open == null ? null : '${open.length}',
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: open == null
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (open.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            'Nothing open. Anything not completed stays '
                            'here until it is.',
                            style: muted,
                          ),
                        ),
                      for (final e in open)
                        ReportTile(
                          report: e,
                          meta: meta,
                          today: meta.today,
                          showDate: true,
                          onTap: () => _show(e),
                          onStatus: (s) => _setStatus(e, s),
                          action: TextButton(
                            onPressed: () => _markDone(e),
                            child: const Text('Mark done'),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        if (_week case final week?) ...[
          const SizedBox(height: 12),
          _MyWeek(
            week: week,
            from: _monday,
            today: meta.today,
            department: dept,
          ),
        ],
      ],
    );
  }
}

/// "My week": the person's own figures, Monday to today.
class _MyWeek extends StatelessWidget {
  const _MyWeek({
    required this.week,
    required this.from,
    required this.today,
    required this.department,
  });

  final List<ActivityReport> week;
  final DateTime from;
  final DateTime today;
  final Department department;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    var workingDays = 0;
    for (var d = from; !d.isAfter(today); d = d.add(const Duration(days: 1))) {
      if (d.weekday <= DateTime.friday) workingDays++;
    }
    // Working days with a report, to compare with the working days so far
    // (a Saturday entry still counts as an entry, not as a working day).
    final days = {
      for (final r in week)
        if (r.date.weekday <= DateTime.friday) r.date,
    }.length;
    final completed = week
        .where((r) => r.status == ReportStatus.completed)
        .length;
    final totals = <String, int>{};
    for (final r in week) {
      r.outputs.forEach((k, v) => totals[k] = (totals[k] ?? 0) + v);
    }
    Widget figure(String label, String value) => Padding(
      padding: const EdgeInsets.only(right: 24, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: microLabel(theme)),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    return AppPanel(
      key: const ValueKey('my-week'),
      title: 'My week',
      icon: Icons.insights_outlined,
      trailing: DateFormat('d MMM').format(from),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              children: [
                figure('Days reported', '$days of $workingDays'),
                figure('Entries', '${week.length}'),
                figure('Completed', '$completed'),
              ],
            ),
            if (totals.isNotEmpty)
              Text(
                [
                  for (final e in totals.entries)
                    '${department.outputLabel(e.key)} ${e.value}',
                ].join(' · '),
                style: theme.textTheme.bodySmall,
              )
            else
              Text('No counts recorded yet this week.', style: muted),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- Overview ---

enum _Period {
  today('Today', 'Today'),
  week('This week', 'Week'),
  month('This month', 'Month'),
  custom('Dates…', 'Dates…');

  const _Period(this.label, this.short);
  final String label;

  /// On a phone, where four long labels don't fit one line.
  final String short;
}

enum _EntryFilter {
  all('All'),
  open('Open'),
  completed('Completed'),
  problems('Blocked / escalated'),
  overdue('Overdue');

  const _EntryFilter(this.label);
  final String label;
}

class _Overview extends ConsumerStatefulWidget {
  const _Overview({
    required this.meta,
    required this.phone,
    required this.refresh,
  });

  final ReportsMeta meta;
  final bool phone;
  final int refresh;

  @override
  ConsumerState<_Overview> createState() => _OverviewState();
}

class _OverviewState extends ConsumerState<_Overview> {
  var _period = _Period.today;
  late DateTime _from = widget.meta.today;
  late DateTime _to = widget.meta.today;
  int? _departmentId;
  int? _userId;
  var _filter = _EntryFilter.all;
  final _search = TextEditingController();
  Timer? _searchDebounce;

  ReportSummary? _summary;
  List<ActivityReport>? _entries;
  Object? _error;
  bool _loading = false;
  bool _exporting = false;

  ReportsMeta get meta => widget.meta;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_Overview old) {
    super.didUpdateWidget(old);
    if (old.refresh == widget.refresh) return;
    // A new day while the app was open: Today / This week / This month
    // move on with it.
    if (old.meta.today != widget.meta.today && _period != _Period.custom) {
      final range = _rangeFor(_period, widget.meta.today);
      _from = range.$1;
      _to = range.$2;
    }
    _load();
  }

  static (DateTime, DateTime) _rangeFor(_Period p, DateTime today) =>
      switch (p) {
        _Period.week => (
          today.subtract(Duration(days: today.weekday - 1)),
          today,
        ),
        _Period.month => (DateTime(today.year, today.month), today),
        _ => (today, today),
      };

  void _setPeriod(_Period p) async {
    final today = meta.today;
    DateTime from;
    var to = today;
    switch (p) {
      case _Period.today || _Period.week || _Period.month:
        (from, to) = _rangeFor(p, today);
      case _Period.custom:
        final range = await showDateRangePicker(
          context: context,
          firstDate: DateTime(today.year - 3),
          lastDate: today,
          initialDateRange: DateTimeRange(start: _from, end: _to),
        );
        if (range == null) return;
        from = range.start;
        to = range.end;
    }
    setState(() {
      _period = p;
      _from = from;
      _to = to;
    });
    _load();
  }

  ReportFilter get _listFilter => ReportFilter(
    from: _filter == _EntryFilter.overdue ? null : _from,
    to: _filter == _EntryFilter.overdue ? null : _to,
    departmentId: _departmentId,
    userId: _userId,
    statuses: switch (_filter) {
      _EntryFilter.completed => const [ReportStatus.completed],
      _EntryFilter.problems => const [
        ReportStatus.blocked,
        ReportStatus.escalated,
      ],
      _ => null,
    },
    openOnly: _filter == _EntryFilter.open,
    overdueOnly: _filter == _EntryFilter.overdue,
    search: _search.text,
  );

  /// The newest loads; older ones finishing late are ignored, so quick
  /// filter changes never leave stale figures on screen.
  int _loadSeq = 0;
  int _entriesSeq = 0;

  Future<void> _load() async {
    final seq = ++_loadSeq;
    final entriesSeq = ++_entriesSeq;
    setState(() => _loading = true);
    final service = ref.read(dailyReportsProvider);
    try {
      final results = await Future.wait<Object>([
        service.summary(
          _from,
          _to,
          departmentId: _departmentId,
          userId: _userId,
        ),
        service.list(_listFilter),
      ]);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _summary = results[0] as ReportSummary;
        if (entriesSeq == _entriesSeq) {
          _entries = results[1] as List<ActivityReport>;
        }
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted && seq == _loadSeq) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _reloadEntries() async {
    final seq = ++_entriesSeq;
    try {
      final entries = await ref.read(dailyReportsProvider).list(_listFilter);
      if (mounted && seq == _entriesSeq) setState(() => _entries = entries);
    } catch (e) {
      if (mounted && seq == _entriesSeq) setState(() => _error = e);
    }
  }

  String get _periodLabel {
    final f = DateFormat('d MMM y');
    if (_from == _to) return DateFormat('EEEE, d MMMM y').format(_from);
    return '${f.format(_from)} – ${f.format(_to)}';
  }

  String get _filtersLabel => [
    meta.department(_departmentId)?.name ??
        (meta.scope == ReportScope.department
            ? (meta.myDepartment?.name ?? 'My department')
            : 'All departments'),
    meta.people.where((p) => p.id == _userId).firstOrNull?.fullName ??
        'Everyone',
    if (_filter != _EntryFilter.all) 'Entries: ${_filter.label}',
    if (_search.text.trim().isNotEmpty) 'Search: “${_search.text.trim()}”',
  ].join(' · ');

  String get _reportTitle {
    if (_userId != null) return 'Staff Activity Report';
    if (_filter == _EntryFilter.open || _filter == _EntryFilter.overdue) {
      return 'Pending Tasks Report';
    }
    if (_filter == _EntryFilter.problems) {
      return 'Exception / Escalation Report';
    }
    return switch (_period) {
      _Period.today => 'Daily Operations Report',
      _Period.week => 'Weekly Performance Report',
      _Period.month => 'Monthly Operations Report',
      _Period.custom => 'Operations Report',
    };
  }

  Future<void> _export(bool pdf) async {
    final summary = _summary;
    final entries = _entries;
    if (summary == null || entries == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final report = OperationsReport(
        title: _reportTitle,
        periodLabel: _periodLabel,
        filtersLabel: _filtersLabel,
        generatedBy: meta.myName,
        generatedAt: DateTime.now(),
        summary: summary,
        entries: entries,
        departments: meta.departments,
      );
      final Uint8List bytes;
      if (pdf) {
        final fonts = await Future.wait([
          rootBundle.load('assets/fonts/Inter-400.ttf'),
          rootBundle.load('assets/fonts/Inter-700.ttf'),
        ]);
        bytes = await operationsReportToPdf(
          report,
          regular: fonts[0],
          bold: fonts[1],
        );
      } else {
        bytes = operationsReportToExcel(report);
      }
      if (!mounted) return;
      await deliverFile(
        context,
        dialogTitle: 'Save ${report.title}',
        fileName: '${report.fileStem}.${pdf ? 'pdf' : 'xlsx'}',
        extension: pdf ? 'pdf' : 'xlsx',
        bytes: bytes,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Couldn’t make the report: $e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// A head or manager gives someone a task (the person filter, if set,
  /// is chosen already).
  Future<void> _assign() async {
    final saved = await showReportEditor(
      context,
      meta: meta,
      day: meta.today,
      assign: true,
      assignTo: _userId,
    );
    if (saved == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Task assigned to ${saved.userName}')),
    );
    await _load();
  }

  Future<void> _openReport(ActivityReport report) async {
    final changed = await showReportDetails(
      context,
      meta: meta,
      report: report,
    );
    if (changed) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
      height: 1.4,
    );
    final summary = _summary;
    final entries = _entries;
    final people = [
      for (final p in meta.people)
        if (_departmentId == null || p.departmentId == _departmentId) p,
    ];

    final filters = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: widget.phone ? double.infinity : null,
          child: SegmentedButton<_Period>(
            key: const ValueKey('report-period'),
            style: widget.phone ? Dt.phoneSegments : null,
            segments: [
              for (final p in _Period.values)
                ButtonSegment(
                  value: p,
                  label: Text(widget.phone ? p.short : p.label),
                ),
            ],
            selected: {_period},
            showSelectedIcon: false,
            onSelectionChanged: (v) => _setPeriod(v.first),
          ),
        ),
        if (meta.scope == ReportScope.all)
          _Dropdown<int?>(
            key: const ValueKey('report-department'),
            fill: widget.phone,
            value: _departmentId,
            items: {
              null: 'All departments',
              for (final d in meta.departments) d.id: d.name,
            },
            onChanged: (v) {
              setState(() {
                _departmentId = v;
                if (_userId != null &&
                    !people.any(
                      (p) => p.id == _userId && p.departmentId == v,
                    )) {
                  _userId = null;
                }
              });
              _load();
            },
          ),
        _Dropdown<int?>(
          key: const ValueKey('report-person'),
          fill: widget.phone,
          value: _userId,
          items: {null: 'Everyone', for (final p in people) p.id: p.fullName},
          onChanged: (v) {
            setState(() => _userId = v);
            _load();
          },
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh, size: 18),
        ),
        FilledButton.icon(
          key: const ValueKey('assign-task'),
          onPressed: _assign,
          icon: const Icon(Icons.assignment_ind_outlined, size: 16),
          label: const Text('Assign task'),
        ),
        MenuAnchor(
          menuChildren: [
            MenuItemButton(
              key: const ValueKey('export-pdf'),
              leadingIcon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              onPressed: () => _export(true),
              child: const Text('PDF'),
            ),
            MenuItemButton(
              key: const ValueKey('export-excel'),
              leadingIcon: const Icon(Icons.table_view_outlined, size: 18),
              onPressed: () => _export(false),
              child: const Text('Excel (.xlsx)'),
            ),
          ],
          builder: (context, controller, _) => OutlinedButton.icon(
            key: const ValueKey('export-report'),
            onPressed: summary == null || _exporting
                ? null
                : () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
            icon: _exporting
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 16),
            label: const Text('Export'),
          ),
        ),
      ],
    );

    if (summary == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          filters,
          const SizedBox(height: 24),
          if (_error != null)
            Text(describeReportError(_error!), style: muted)
          else
            const Center(child: CircularProgressIndicator()),
        ],
      );
    }

    final s = summary;
    final submittedToday = [
      for (final c in s.compliance)
        if (c.submittedToday) c,
    ];
    final notYet = [
      for (final c in s.compliance)
        if (!c.submittedToday) c,
    ];
    final attention = {
      for (final e in [...s.overdue, ...s.attention]) e.id: e,
    }.values.toList();
    final todayOnly = _from == _to && _to == meta.today;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        filters,
        const SizedBox(height: 6),
        Text(
          '$_periodLabel · ${s.workingDays} working '
          'day${s.workingDays == 1 ? '' : 's'}',
          style: muted,
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(describeReportError(_error!), style: muted),
        ],
        const SizedBox(height: 12),
        // The five figures share the row evenly (two or three a row on
        // smaller screens), so no tile is wider or narrower than another.
        LayoutBuilder(
          builder: (context, box) {
            final stats = [
              _Stat('Activities', s.total, key: const ValueKey('stat-total')),
              _Stat('Completed', s.count(ReportStatus.completed)),
              _Stat(
                'In progress',
                s.count(ReportStatus.inProgress) +
                    s.count(ReportStatus.pending),
                hint: 'In progress or pending',
              ),
              _Stat(
                'Blocked',
                s.count(ReportStatus.blocked) + s.count(ReportStatus.escalated),
                alert: true,
                hint: 'Blocked or escalated',
              ),
              _Stat(
                'Overdue',
                s.overdue.length,
                alert: true,
                key: const ValueKey('stat-overdue'),
              ),
            ];
            const gap = 10.0;
            final cols = box.maxWidth >= 760
                ? 5
                : box.maxWidth >= 460
                ? 3
                : 2;
            final w = (box.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final st in stats) SizedBox(width: w, child: st)],
            );
          },
        ),
        const SizedBox(height: 12),
        AppPanel(
          title: 'Submission compliance',
          icon: Icons.how_to_reg_outlined,
          trailing: todayOnly
              ? '${submittedToday.length} of ${s.compliance.length} today'
              : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
            child: s.compliance.isEmpty
                ? Text(
                    'Nobody is in a department yet. Set each person’s '
                    'department in Settings › Users.',
                    style: muted,
                  )
                : todayOnly
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Submitted today', style: microLabel(theme)),
                      const SizedBox(height: 6),
                      _names(submittedToday, theme, done: true),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text('Not yet', style: microLabel(theme)),
                          // Right-aligned at its own width; it shortens
                          // only when the line is too narrow for it.
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: notYet.isEmpty
                                  ? null
                                  : TextButton.icon(
                                      key: const ValueKey('copy-reminder'),
                                      onPressed: () => _copyReminder(notYet),
                                      icon: const Icon(Icons.copy, size: 14),
                                      label: const Text(
                                        'Copy reminder',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _names(notYet, theme, done: false),
                    ],
                  )
                : Column(
                    children: [
                      for (final c in s.compliance)
                        _ComplianceRow(row: c, workingDays: s.workingDays),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),
        AppPanel(
          title: 'Departments',
          icon: Icons.apartment_outlined,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final d in s.departments)
                  _DepartmentRow(
                    summary: d,
                    department: meta.department(d.id),
                    onTap: meta.scope == ReportScope.all
                        ? () {
                            setState(() {
                              _departmentId = d.id;
                              _userId = null;
                            });
                            _load();
                          }
                        : null,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        AppPanel(
          title: 'Needs attention',
          icon: Icons.priority_high,
          trailing: '${attention.length}',
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: attention.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      'Nothing overdue, blocked or escalated.',
                      style: muted,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final e in attention)
                        ReportTile(
                          report: e,
                          meta: meta,
                          today: meta.today,
                          showPerson: true,
                          showDate: true,
                          onTap: () => _openReport(e),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),
        AppPanel(
          title: 'Entries',
          icon: Icons.list_alt_outlined,
          trailing: entries == null ? null : '${entries.length}',
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final f in _EntryFilter.values)
                      ChoiceChip(
                        key: ValueKey('entries-${f.name}'),
                        label: Text(f.label),
                        selected: _filter == f,
                        onSelected: (_) {
                          setState(() => _filter = f);
                          _reloadEntries();
                        },
                      ),
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _search,
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: 'Search entries',
                        ),
                        onChanged: (_) {
                          _searchDebounce?.cancel();
                          _searchDebounce = Timer(
                            const Duration(milliseconds: 400),
                            _reloadEntries,
                          );
                        },
                      ),
                    ),
                  ],
                ),
                if (_filter == _EntryFilter.overdue)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Overdue items from any date, not only this period.',
                      style: muted,
                    ),
                  ),
                const SizedBox(height: 8),
                if (entries == null)
                  const Center(child: CircularProgressIndicator())
                else if (entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text('No entries match.', style: muted),
                  )
                else
                  for (final e in entries)
                    ReportTile(
                      report: e,
                      meta: meta,
                      today: meta.today,
                      showPerson: true,
                      showDate: _from != _to || _filter == _EntryFilter.overdue,
                      onTap: () => _openReport(e),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// A message to paste into WhatsApp or email for those who haven't
  /// submitted today.
  Future<void> _copyReminder(List<ComplianceRow> notYet) async {
    final names = [for (final c in notYet) c.fullName];
    final list = names.length == 1
        ? names.first
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    final text =
        'Hi $list, a reminder to add today’s daily report in ${Dt.appName} '
        '(Daily reports › Add activity). Thank you!';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Reminder for ${names.length} '
          '${names.length == 1 ? 'person' : 'people'} copied — paste it in '
          'WhatsApp or email.',
        ),
      ),
    );
  }

  Widget _names(
    List<ComplianceRow> rows,
    ThemeData theme, {
    required bool done,
  }) {
    if (rows.isEmpty) {
      return Text(
        done ? 'Nobody yet.' : 'Everyone has submitted.',
        style: theme.textTheme.bodySmall?.copyWith(color: Dt.textMuted(theme)),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final c in rows)
          Chip(
            avatar: Icon(
              done ? Icons.check_circle : Icons.schedule,
              size: 16,
              color: done
                  ? Dt.statusGreen(theme.brightness)
                  : theme.colorScheme.error,
            ),
            label: Text(
              c.departmentName.isEmpty
                  ? c.fullName
                  : '${c.fullName} · ${c.departmentName}',
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.fill = false,
  });

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  /// Takes the whole line (on a phone).
  final bool fill;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: fill
        ? const BoxConstraints(minWidth: double.infinity)
        : const BoxConstraints(maxWidth: 260),
    child: DropdownButtonFormField<T>(
      // A form field reads its initial value once: keyed by the value, it
      // follows changes made in code (a department row tapped, the person
      // reset when the department changes).
      key: ValueKey(value),
      initialValue: items.containsKey(value) ? value : items.keys.first,
      isExpanded: true,
      isDense: true,
      decoration: const InputDecoration(isDense: true),
      items: [
        for (final e in items.entries)
          DropdownMenuItem<T>(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) => onChanged(v as T),
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat(
    this.label,
    this.value, {
    super.key,
    this.alert = false,
    this.hint,
  });

  final String label;
  final int value;
  final bool alert;

  /// What the figure counts, when the short label leaves it out.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = alert && value > 0 ? scheme.error : scheme.onSurface;
    final tile = Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: microLabel(theme),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            '$value',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    return hint == null ? tile : Tooltip(message: hint, child: tile);
  }
}

class _ComplianceRow extends StatelessWidget {
  const _ComplianceRow({required this.row, required this.workingDays});

  final ComplianceRow row;
  final int workingDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    final full = workingDays > 0 && row.daysSubmitted >= workingDays;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            full ? Icons.check_circle : Icons.timelapse,
            size: 16,
            color: full
                ? Dt.statusGreen(theme.brightness)
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              row.departmentName.isEmpty
                  ? row.fullName
                  : '${row.fullName} · ${row.departmentName}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${row.daysSubmitted} of $workingDays days · '
            '${row.entries} entr${row.entries == 1 ? 'y' : 'ies'}',
            style: muted,
          ),
        ],
      ),
    );
  }
}

class _DepartmentRow extends StatelessWidget {
  const _DepartmentRow({
    required this.summary,
    required this.department,
    this.onTap,
  });

  final DepartmentSummary summary;
  final Department? department;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    final d = summary;
    final outputs = [
      for (final e in d.outputs.entries)
        '${department?.outputLabel(e.key) ?? e.key} ${e.value}',
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Dt.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    d.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${d.activities} activit${d.activities == 1 ? 'y' : 'ies'}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              d.activities == 0
                  ? 'No reports in this period.'
                  : '${d.completed} completed · ${d.open} open'
                        '${d.blocked + d.escalated > 0 ? ' · ${d.blocked} blocked · ${d.escalated} escalated' : ''}'
                        ' · ${d.people} reporting',
              style: muted,
            ),
            if (outputs.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(outputs, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
