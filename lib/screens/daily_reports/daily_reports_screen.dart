import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/daily_report_export.dart';
import '../../services/daily_reports_service.dart';
import '../../services/export_actions.dart';
import '../../state/app_state.dart';
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

class _DailyReportsScreenState extends ConsumerState<DailyReportsScreen> {
  ReportsMeta? _meta;
  Object? _error;
  _Tab? _tab;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final meta = await ref.read(dailyReportsProvider).meta();
      if (!mounted) return;
      setState(() {
        _meta = meta;
        // People without a department (the Operations Manager, say) start
        // on the Overview; everyone else on their own day.
        _tab ??= meta.seesOthers && meta.myDepartmentId == null
            ? _Tab.overview
            : _Tab.mine;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
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
        final pad = phone ? 14.0 : 18.0;
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
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Daily reports',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            meta.myDepartment?.name ??
                                (meta.seesOthers
                                    ? 'Every department'
                                    : 'No department yet'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Dt.textMuted(theme),
                            ),
                          ),
                        ],
                      ),
                      if (meta.seesOthers)
                        SegmentedButton<_Tab>(
                          key: const ValueKey('reports-tab'),
                          segments: const [
                            ButtonSegment(
                              value: _Tab.mine,
                              icon: Icon(Icons.edit_note, size: 16),
                              label: Text('My reports'),
                            ),
                            ButtonSegment(
                              value: _Tab.overview,
                              icon: Icon(Icons.dashboard_outlined, size: 16),
                              label: Text('Overview'),
                            ),
                          ],
                          selected: {tab},
                          showSelectedIcon: false,
                          onSelectionChanged: (v) =>
                              setState(() => _tab = v.first),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (tab == _Tab.mine)
                    _MyReports(meta: meta, phone: phone)
                  else
                    _Overview(meta: meta, phone: phone),
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
  const _MyReports({required this.meta, required this.phone});

  final ReportsMeta meta;
  final bool phone;

  @override
  ConsumerState<_MyReports> createState() => _MyReportsState();
}

class _MyReportsState extends ConsumerState<_MyReports> {
  late DateTime _day = widget.meta.today;
  List<ActivityReport>? _entries;
  List<ActivityReport>? _open;
  Object? _error;

  ReportsMeta get meta => widget.meta;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ref.read(dailyReportsProvider);
    try {
      final results = await Future.wait([
        service.list(ReportFilter(from: _day, to: _day, userId: meta.myId)),
        service.list(ReportFilter(userId: meta.myId, openOnly: true)),
      ]);
      if (!mounted) return;
      setState(() {
        _entries = results[0];
        _open = results[1];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
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

  Future<void> _markDone(ActivityReport report) async {
    try {
      await ref
          .read(dailyReportsProvider)
          .save(
            ActivityReport(
              id: report.id,
              date: report.date,
              description: report.description,
              reference: report.reference,
              outputs: report.outputs,
              status: ReportStatus.completed,
              nextAction: report.nextAction,
              blocker: report.blocker,
              priority: report.priority,
              dueDate: report.dueDate,
            ),
          );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Marked completed')));
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
          padding: const EdgeInsets.all(14),
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
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(
                            isToday
                                ? 'Nothing recorded yet today. Add each '
                                      'piece of work you did, with numbers '
                                      'where you can (applications '
                                      'reviewed, calls made…).'
                                : 'Nothing recorded for this day.',
                            style: muted,
                          ),
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
                          action: TextButton(
                            onPressed: () => _markDone(e),
                            child: const Text('Mark done'),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- Overview ---

enum _Period {
  today('Today'),
  week('This week'),
  month('This month'),
  custom('Dates…');

  const _Period(this.label);
  final String label;
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
  const _Overview({required this.meta, required this.phone});

  final ReportsMeta meta;
  final bool phone;

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

  void _setPeriod(_Period p) async {
    final today = meta.today;
    DateTime from;
    var to = today;
    switch (p) {
      case _Period.today:
        from = today;
      case _Period.week:
        from = today.subtract(Duration(days: today.weekday - 1));
      case _Period.month:
        from = DateTime(today.year, today.month);
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

  Future<void> _load() async {
    setState(() => _loading = true);
    final service = ref.read(dailyReportsProvider);
    try {
      final results = await Future.wait<Object>([
        service.summary(_from, _to, departmentId: _departmentId),
        service.list(_listFilter),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = results[0] as ReportSummary;
        _entries = results[1] as List<ActivityReport>;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _reloadEntries() async {
    try {
      final entries = await ref.read(dailyReportsProvider).list(_listFilter);
      if (mounted) setState(() => _entries = entries);
    } catch (e) {
      if (mounted) setState(() => _error = e);
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
          rootBundle.load('assets/fonts/InstrumentSans-400.ttf'),
          rootBundle.load('assets/fonts/InstrumentSans-700.ttf'),
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
        SegmentedButton<_Period>(
          key: const ValueKey('report-period'),
          style: widget.phone ? Dt.phoneSegments : null,
          segments: [
            for (final p in _Period.values)
              ButtonSegment(value: p, label: Text(p.label)),
          ],
          selected: {_period},
          showSelectedIcon: false,
          onSelectionChanged: (v) => _setPeriod(v.first),
        ),
        if (meta.scope == ReportScope.all)
          _Dropdown<int?>(
            key: const ValueKey('report-department'),
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
          value: _userId,
          items: {null: 'Everyone', for (final p in people) p.id: p.fullName},
          onChanged: (v) {
            setState(() => _userId = v);
            _reloadEntries();
          },
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh, size: 18),
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
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _Stat('Activities', s.total, key: const ValueKey('stat-total')),
            _Stat('Completed', s.count(ReportStatus.completed)),
            _Stat(
              'In progress / pending',
              s.count(ReportStatus.inProgress) + s.count(ReportStatus.pending),
            ),
            _Stat(
              'Blocked / escalated',
              s.count(ReportStatus.blocked) + s.count(ReportStatus.escalated),
              alert: true,
            ),
            _Stat(
              'Overdue',
              s.overdue.length,
              alert: true,
              key: const ValueKey('stat-overdue'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        AppPanel(
          title: 'Submission compliance',
          icon: Icons.how_to_reg_outlined,
          trailing: todayOnly
              ? '${submittedToday.length} of ${s.compliance.length} today'
              : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
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
                      Text('Not yet', style: microLabel(theme)),
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
            padding: const EdgeInsets.all(12),
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
  });

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 260),
    child: DropdownButtonFormField<T>(
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
  const _Stat(this.label, this.value, {super.key, this.alert = false});

  final String label;
  final int value;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = alert && value > 0 ? scheme.error : scheme.onSurface;
    return Container(
      width: 170,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: microLabel(theme)),
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
