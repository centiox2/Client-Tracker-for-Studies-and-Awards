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
import '../../widgets/clarity.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/panels.dart';
import 'notifications_sheet.dart';
import 'report_editor.dart';
import 'task_composer.dart';
import 'wrap_up.dart';

/// Daily reports, as tasks.
///
/// - My tasks: your to-do list. Add what you're going to do or are doing,
///   with a status your manager sees; submit each when it's done.
/// - My submissions: what you've submitted, by day, and how it was reviewed.
/// - Review (heads, managers, admins, the director, and anyone who
///   assigned work): approve submitted work or return it with a comment.
/// - Team (the same people): everyone's tasks, who has reported, figures,
///   assigning tasks and exports.
class DailyReportsScreen extends ConsumerStatefulWidget {
  const DailyReportsScreen({super.key});

  @override
  ConsumerState<DailyReportsScreen> createState() => _DailyReportsScreenState();
}

enum _Tab { tasks, submissions, review, team }

class _DailyReportsScreenState extends ConsumerState<DailyReportsScreen> {
  _Tab? _tab;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'task search');
  Timer? _searchDebounce;
  String _query = '';

  /// The search box shows once the search button (or /) is pressed.
  bool _searchOpen = false;

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _search.clear();
    setState(() {
      _query = '';
      _searchOpen = false;
    });
  }

  /// While this page is open, checks for news more often than the badge
  /// does elsewhere, so a submission or a return shows within seconds.
  Timer? _live;
  static const liveEvery = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    _onFocusRequest(ref.read(reportFocusProvider));
    _live = Timer.periodic(
      liveEvery,
      (_) => ref.read(reportBadgeProvider.notifier).refresh(),
    );
  }

  @override
  void dispose() {
    _live?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  /// N or the 4 pm reminder: My tasks, cursor in the quick line. /: the
  /// search box.
  void _onFocusRequest(ReportFocus? f) {
    if (f == ReportFocus.quickLine) {
      _tab = _Tab.tasks;
      _query = '';
      _search.clear();
      _searchOpen = false;
    } else if (f == ReportFocus.search) {
      _searchOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _searchFocus.requestFocus();
        ref.read(reportFocusProvider.notifier).done();
      });
    }
  }

  static _Tab _firstTab(ReportsMeta meta) =>
      meta.seesOthers && meta.myDepartmentId == null ? _Tab.team : _Tab.tasks;

  void _onSearch(String text) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = text.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(reportFocusProvider, (_, f) {
      if (f != null) setState(() => _onFocusRequest(f));
    });
    // Something saved offline was refused when sent: say why, once.
    ref.listen(reportOutboxProvider, (_, _) {
      final outbox = ref.read(reportOutboxProvider.notifier);
      final why = outbox.refused;
      if (why != null) {
        outbox.refused = null;
        _snack(context, 'Something saved offline couldn’t be sent: $why');
      }
    });
    // Something changed elsewhere (work submitted for review, a task
    // returned or assigned): reload what's shown.
    ref.listen(reportBadgeProvider, (before, after) {
      if (before == null || after == null) return;
      if (before.toReview != after.toReview || after.unread > before.unread) {
        ref.read(reportsChangedProvider.notifier).bump();
      }
    });
    final start = ref.watch(reportViewProvider);
    final badge = ref.watch(reportBadgeProvider) ?? start?.badge;
    if (start == null) {
      final error = ref.read(reportStartProvider.notifier).error;
      if (error != null) {
        return EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Daily reports aren’t available right now',
          message: describeReportError(error),
          actionLabel: 'Try again',
          onAction: () => ref.read(reportStartProvider.notifier).refresh(),
        );
      }
      return const _Skeleton();
    }
    final meta = start.meta;
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final tabs = <(_Tab, String)>[
      (
        _Tab.tasks,
        'My tasks${start.tasks.isEmpty ? '' : ' (${start.tasks.length})'}',
      ),
      (_Tab.submissions, 'My submissions'),
      if (meta.reviews)
        (
          _Tab.review,
          'Review${(badge?.toReview ?? 0) == 0 ? '' : ' (${badge!.toReview})'}',
        ),
      if (meta.seesOthers) (_Tab.team, 'Team'),
    ];
    var tab = _tab ?? _firstTab(meta);
    if (!tabs.any((t) => t.$1 == tab)) tab = _Tab.tasks;

    return LayoutBuilder(
      builder: (context, viewport) {
        final phone = viewport.maxWidth < 600;
        final pad = clarityHPad(context);
        final searchField = TextField(
          key: const ValueKey('task-search'),
          controller: _search,
          focusNode: _searchFocus,
          onChanged: _onSearch,
          textInputAction: TextInputAction.search,
          onTapOutside: (_) {
            if (_search.text.isEmpty && _searchOpen) _closeSearch();
          },
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 18),
            hintText: 'Words, a name or #123',
            suffixIcon: IconButton(
              key: const ValueKey('search-close'),
              tooltip: 'Close search',
              onPressed: _closeSearch,
              icon: const Icon(Icons.close, size: 16),
            ),
          ),
        );
        final searchButton = IconButton(
          key: const ValueKey('search-open'),
          tooltip: 'Search tasks (/)',
          onPressed: _openSearch,
          icon: const Icon(Icons.search, size: 20),
        );
        final showSearch = _searchOpen || _query.isNotEmpty;
        return RefreshIndicator(
          onRefresh: () => ref.read(reportStartProvider.notifier).refresh(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(pad, 14, pad, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Dt.contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.apartment_outlined,
                          size: 16,
                          color: c.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            [
                              meta.myName,
                              meta.myDepartment?.name ??
                                  (meta.seesOthers
                                      ? 'Every department'
                                      : 'No department yet'),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: c.textMuted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (!phone && showSearch) ...[
                          SizedBox(width: 320, child: searchField),
                          const SizedBox(width: 4),
                        ] else if (!showSearch)
                          searchButton,
                        IconButton(
                          key: const ValueKey('reports-refresh'),
                          tooltip: 'Refresh',
                          onPressed: () =>
                              ref.read(reportStartProvider.notifier).refresh(),
                          icon: const Icon(Icons.refresh, size: 20),
                        ),
                        // Phones have the bell in the top bar.
                        if (!phone) const ReportBell(),
                      ],
                    ),
                    if (phone && showSearch) ...[
                      const SizedBox(height: 8),
                      searchField,
                    ],
                    const SizedBox(height: 6),
                    UnderlineTabs<_Tab>(
                      key: const ValueKey('reports-tab'),
                      tabs: tabs,
                      selected: tab,
                      onChanged: (v) => setState(() => _tab = v),
                    ),
                    const SizedBox(height: 14),
                    if (_query.isNotEmpty)
                      _SearchResults(meta: meta, query: _query)
                    else
                      switch (tab) {
                        _Tab.tasks => _MyTasks(start: start, phone: phone),
                        _Tab.submissions => _MySubmissions(start: start),
                        _Tab.review => _ReviewTab(meta: meta),
                        _Tab.team => _TeamTab(meta: meta, phone: phone),
                      },
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Grey shapes where the page will be, while the first copy loads.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final c = Clarity.of(Theme.of(context));
    Widget box(double h, {double? w}) => Container(
      height: h,
      width: w,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.track,
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
    );
    final pad = clarityHPad(context);
    return Padding(
      key: const ValueKey('reports-skeleton'),
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          box(18, w: 220),
          box(34, w: 380),
          const SizedBox(height: 8),
          box(44),
          box(84),
          box(84),
          box(84),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------- Shared bits ---

int _urgencyRank(TaskUrgency u) => TaskUrgency.values.length - u.index;

/// Most urgent first, then soonest due, then newest.
List<ActivityReport> _byUrgency(Iterable<ActivityReport> tasks) =>
    [...tasks]..sort((a, b) {
      final u = _urgencyRank(a.urgency).compareTo(_urgencyRank(b.urgency));
      if (u != 0) return u;
      final x = a.dueDate, y = b.dueDate;
      if (x != y) {
        if (x == null) return 1;
        if (y == null) return -1;
        return x.compareTo(y);
      }
      return (b.id ?? 0).compareTo(a.id ?? 0);
    });

void _snack(BuildContext context, String text) =>
    reportSnack(ScaffoldMessenger.of(context), text);

/// A titled group of task cards.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.color,
    this.icon,
    this.trailing,
    super.key,
  });

  final String title;
  final List<Widget> children;
  final Color? color;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 2),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: color ?? c.textSecondary),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// Opens a task; true when it changed.
Future<bool> _openTask(
  BuildContext context,
  ReportsMeta meta,
  ActivityReport task,
) => showReportDetails(context, meta: meta, report: task);

// --------------------------------------------------------------- Search ---

class _SearchResults extends ConsumerStatefulWidget {
  const _SearchResults({required this.meta, required this.query});
  final ReportsMeta meta;
  final String query;

  @override
  ConsumerState<_SearchResults> createState() => _SearchResultsState();
}

class _SearchResultsState extends ConsumerState<_SearchResults> {
  List<ActivityReport>? _results;
  Object? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_SearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _error = null);
    try {
      final r = await ref
          .read(dailyReportsProvider)
          .list(ReportFilter(search: widget.query, limit: 200));
      if (mounted && seq == _seq) setState(() => _results = r);
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(reportsChangedProvider, (_, _) => _load());
    final muted = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Dt.textMuted(Theme.of(context)));
    final results = _results;
    if (_error != null) return Text(describeReportError(_error!), style: muted);
    if (results == null) return const LinearProgressIndicator();
    return _Section(
      key: const ValueKey('search-results'),
      title:
          '${results.length} task${results.length == 1 ? '' : 's'} '
          'matching “${widget.query}”',
      icon: Icons.search,
      children: [
        if (results.isEmpty)
          Text(
            'Nothing matches. Try fewer words, a person’s name, or a task '
            'number like #12.',
            style: muted,
          ),
        for (final t in results)
          TaskCard(
            task: t,
            meta: widget.meta,
            showPerson: t.userId != widget.meta.myId,
            onTap: () => _openTask(context, widget.meta, t),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------- My tasks ---

class _MyTasks extends ConsumerStatefulWidget {
  const _MyTasks({required this.start, required this.phone});
  final ReportsStart start;
  final bool phone;

  @override
  ConsumerState<_MyTasks> createState() => _MyTasksState();
}

class _MyTasksState extends ConsumerState<_MyTasks> {
  final _quickFocus = FocusNode(debugLabel: 'quick line');

  /// The list itself: Esc in the quick line comes here, so N, / and the
  /// arrow keys work.
  final _pageFocus = FocusNode(debugLabel: 'my tasks', skipTraversal: true);

  /// One per card, for moving between them with the arrow keys.
  final Map<int, FocusNode> _cardFocus = {};

  ReportsMeta get meta => widget.start.meta;

  @override
  void initState() {
    super.initState();
    if (ref.read(reportFocusProvider) == ReportFocus.quickLine) {
      _focusQuickLine();
    }
  }

  @override
  void dispose() {
    _quickFocus.dispose();
    _pageFocus.dispose();
    for (final f in _cardFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _add(TaskMode? mode) async {
    final actions = TaskActions(context, ref);
    final saved = await showReportEditor(context, meta: meta, mode: mode);
    if (saved != null && mounted) {
      final o = (task: saved, queued: saved.pending);
      saved.isSubmitted
          ? actions.submitted(o, created: true)
          : actions.added(o);
    }
  }

  Future<void> _setStatus(ActivityReport t, ReportStatus s) async {
    if (s == ReportStatus.blocked) {
      // Needs to say what's blocking it.
      await showReportEditor(
        context,
        meta: meta,
        existing: t.withStatus(ReportStatus.blocked),
      );
      return;
    }
    await TaskActions(context, ref).setStatus(t, s);
  }

  Future<void> _tick(ActivityReport t) =>
      finishTask(context, ref, meta: meta, task: t);

  Future<void> _details(ActivityReport t) =>
      finishTask(context, ref, meta: meta, task: t, details: true);

  void _open(ActivityReport t) {
    if (t.pending) {
      _snack(
        context,
        'This one is waiting to be sent. It opens once you’re back online.',
      );
      return;
    }
    _openTask(context, meta, t);
  }

  List<Widget> _actions(ActivityReport t) => [
    if (t.status == ReportStatus.blocked)
      OutlinedButton(
        key: ValueKey('unblock-${t.id}'),
        onPressed: () => _setStatus(t, ReportStatus.inProgress),
        child: const Text('Unblocked'),
      ),
    if (t.review == ReviewState.returned)
      // What was sent is filled in already; change what was asked for.
      FilledButton.tonalIcon(
        key: ValueKey('submit-${t.id}'),
        style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: () => _details(t),
        icon: const Icon(Icons.send, size: 16),
        label: const Text('Resubmit'),
      )
    else
      TextButton.icon(
        key: ValueKey('submit-${t.id}'),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: Theme.of(context).textTheme.labelMedium,
        ),
        onPressed: () => _details(t),
        icon: const Icon(Icons.edit_note, size: 16),
        label: const Text('Submit with details'),
      ),
  ];

  FocusNode _focusFor(ActivityReport t) => _cardFocus.putIfAbsent(
    t.id!,
    () => FocusNode(debugLabel: 'task ${t.id}'),
  );

  /// Up / Down move between cards, Space ticks one, Enter opens it.
  Widget _card(ActivityReport t, List<ActivityReport> order) {
    final node = _focusFor(t);
    return Focus(
      skipTraversal: true,
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final i = order.indexOf(t);
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowDown && i + 1 < order.length) {
          _focusFor(order[i + 1]).requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          i > 0
              ? _focusFor(order[i - 1]).requestFocus()
              : _quickFocus.requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.space && event is KeyDownEvent) {
          if (!t.pending) _tick(t);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TaskCard(
        task: t,
        meta: meta,
        focusNode: node,
        onTap: () => _open(t),
        // Its section says its state; ticking it finishes it.
        inSection: true,
        onTick: t.pending && t.isSubmitted ? null : () => _tick(t),
        actions: t.pending ? const [] : _actions(t),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    ref.listen(reportFocusProvider, (_, f) {
      if (f == ReportFocus.quickLine) _focusQuickLine();
    });
    final tasks = widget.start.tasks;
    final returned = _byUrgency(
      tasks.where((t) => t.review == ReviewState.returned),
    );
    final rest = tasks.where((t) => t.review != ReviewState.returned);
    final blocked = _byUrgency(
      rest.where((t) => t.status == ReportStatus.blocked),
    );
    final doing = _byUrgency(
      rest.where((t) => t.status == ReportStatus.inProgress),
    );
    final todo = _byUrgency(rest.where((t) => t.status == ReportStatus.toDo));
    final order = [...returned, ...blocked, ...doing, ...todo];
    final today = meta.today;
    final doneToday = widget.start.submissions
        .where((s) => s.date == today)
        .toList();
    final needsReport = meta.myDepartmentId != null;
    // Finished work saved offline, not sent yet.
    final waiting = widget.start.submissions.where((s) => s.pending).toList();
    final submittedToday = doneToday.where((s) => !s.pending).toList();
    final quickAdd = TaskComposer(
      meta: meta,
      inputFocus: _quickFocus,
      onDown: order.isEmpty
          ? null
          : () => _focusFor(order.first).requestFocus(),
      onEscape: _pageFocus.requestFocus,
    );

    final buttons = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('add-activity'),
          onPressed: () => _add(null),
          icon: const Icon(Icons.edit_note, size: 16),
          label: const Text('Add with details'),
        ),
        if (order.any((t) => !t.pending))
          OutlinedButton.icon(
            key: const ValueKey('wrap-up'),
            onPressed: () => _wrapUp(order),
            icon: const Icon(Icons.done_all, size: 16),
            label: const Text('Wrap up my day'),
          ),
      ],
    );

    final todayBar = Container(
      key: const ValueKey('my-today'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: doneToday.isEmpty && needsReport ? c.warningBg : c.positiveBg,
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Row(
        children: [
          Icon(
            doneToday.isEmpty ? Icons.edit_note : Icons.task_alt,
            size: 18,
            color: doneToday.isEmpty && needsReport
                ? c.warningFg
                : c.positiveFg,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              doneToday.isEmpty
                  ? 'Today, ${taskDay(today, today: today)} · nothing submitted yet'
                  : 'Today, ${taskDay(today, today: today)} · '
                        '${doneToday.length} submitted · '
                        '${doneToday.where((s) => s.review == ReviewState.approved).length} approved',
              style: theme.textTheme.bodySmall?.copyWith(
                color: doneToday.isEmpty && needsReport
                    ? c.warningFg
                    : c.positiveFg,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );

    return Focus(
      focusNode: _pageFocus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!needsReport)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'You aren’t in a department, so you aren’t expected to report '
                'daily — but you can still keep your own tasks here.',
                style: muted,
              ),
            ),
          todayBar,
          const SizedBox(height: 12),
          quickAdd,
          const SizedBox(height: 10),
          buttons,
          const SizedBox(height: 18),
          if (waiting.isNotEmpty)
            _Section(
              key: const ValueKey('section-waiting'),
              title: 'Waiting to send (${waiting.length})',
              icon: Icons.cloud_upload_outlined,
              trailing: Text('Sent when you’re back online', style: muted),
              children: [
                for (final t in waiting)
                  TaskCard(task: t, meta: meta, onTap: () => _open(t)),
              ],
            ),
          if (tasks.isEmpty && waiting.isEmpty)
            const PanelEmpty(
              icon: Icons.checklist_outlined,
              title: 'Your list is clear',
              message:
                  'Add what you’re going to do today above. Tasks your '
                  'manager assigns you show here too, with their urgency.',
            ),
          if (returned.isNotEmpty)
            _Section(
              key: const ValueKey('section-returned'),
              title: 'Returned to you (${returned.length})',
              icon: Icons.undo,
              color: theme.colorScheme.error,
              children: [for (final t in returned) _card(t, order)],
            ),
          if (blocked.isNotEmpty)
            _Section(
              key: const ValueKey('section-blocked'),
              title: 'Blocked (${blocked.length})',
              icon: Icons.block,
              color: theme.colorScheme.error,
              children: [for (final t in blocked) _card(t, order)],
            ),
          if (doing.isNotEmpty)
            _Section(
              key: const ValueKey('section-doing'),
              title: 'Doing (${doing.length})',
              icon: Icons.timelapse,
              color: Dt.existingBlue(theme.brightness),
              children: [for (final t in doing) _card(t, order)],
            ),
          if (todo.isNotEmpty)
            _Section(
              key: const ValueKey('section-todo'),
              title: 'To do (${todo.length})',
              icon: Icons.radio_button_unchecked,
              children: [for (final t in todo) _card(t, order)],
            ),
          if (submittedToday.isNotEmpty)
            _Section(
              key: const ValueKey('section-today'),
              title: 'Submitted today (${submittedToday.length})',
              icon: Icons.task_alt,
              color: Dt.statusGreen(theme.brightness),
              children: [
                for (final t in submittedToday)
                  TaskCard(task: t, meta: meta, onTap: () => _open(t)),
              ],
            ),
        ],
      ),
    );
  }

  void _focusQuickLine() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _quickFocus.requestFocus();
      ref.read(reportFocusProvider.notifier).done();
    });
  }

  Future<void> _wrapUp(List<ActivityReport> order) async {
    final actions = TaskActions(context, ref);
    final all = await showWrapUp(
      context,
      meta: meta,
      tasks: [
        for (final t in order)
          if (!t.pending) t,
      ],
    );
    if (all == null || all.isEmpty || !mounted) return;
    final queued = all.where((o) => o.queued).length;
    actions.snack(
      'Submitted ${all.length} task${all.length == 1 ? '' : 's'}'
      '${queued == 0 ? '' : ' ($queued waiting to send)'}',
      onUndo: () => actions.undoAll(all),
    );
  }
}

// ------------------------------------------------------ My submissions ---

enum _SubFilter {
  all('All'),
  waiting('Awaiting review'),
  approved('Approved'),
  returned('Returned');

  const _SubFilter(this.label);
  final String label;
}

class _MySubmissions extends StatefulWidget {
  const _MySubmissions({required this.start});
  final ReportsStart start;

  @override
  State<_MySubmissions> createState() => _MySubmissionsState();
}

class _MySubmissionsState extends State<_MySubmissions> {
  var _filter = _SubFilter.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final meta = widget.start.meta;
    final all = [
      ...widget.start.submissions,
      for (final t in widget.start.tasks)
        if (t.review == ReviewState.returned) t,
    ];
    final shown =
        [
          for (final s in all)
            if (switch (_filter) {
              _SubFilter.all => true,
              _SubFilter.waiting => s.review == ReviewState.submitted,
              _SubFilter.approved => s.review == ReviewState.approved,
              _SubFilter.returned => s.review == ReviewState.returned,
            })
              s,
        ]..sort((a, b) {
          final x = a.submittedAt, y = b.submittedAt;
          if (x == null || y == null) return (b.id ?? 0).compareTo(a.id ?? 0);
          return y.compareTo(x);
        });
    // By the day each was submitted for.
    final days = <DateTime, List<ActivityReport>>{};
    for (final s in shown) {
      final at = s.submittedAt;
      final d =
          s.date ??
          (at == null ? meta.today : DateTime(at.year, at.month, at.day));
      days.putIfAbsent(d, () => []).add(s);
    }
    final dept = meta.myDepartment;
    int count(ReviewState r) => all.where((s) => s.review == r).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final f in _SubFilter.values)
              ChoiceChip(
                key: ValueKey('subs-${f.name}'),
                label: Text(switch (f) {
                  _SubFilter.all => 'All (${all.length})',
                  _SubFilter.waiting =>
                    '${f.label} (${count(ReviewState.submitted)})',
                  _SubFilter.approved =>
                    '${f.label} (${count(ReviewState.approved)})',
                  _SubFilter.returned =>
                    '${f.label} (${count(ReviewState.returned)})',
                }),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (shown.isEmpty)
          PanelEmpty(
            icon: Icons.outbox_outlined,
            title: all.isEmpty ? 'Nothing submitted yet' : 'None here',
            message: all.isEmpty
                ? 'When you submit a task it shows here with the day it was '
                      'submitted, and whether it was approved.'
                : null,
          ),
        for (final entry in days.entries)
          _Section(
            key: ValueKey('day-${dateKey(entry.key)}'),
            title: entry.key == meta.today
                ? 'Today · ${taskDay(entry.key, today: meta.today)}'
                : entry.key == meta.today.subtract(const Duration(days: 1))
                ? 'Yesterday · ${taskDay(entry.key, today: meta.today)}'
                : DateFormat('EEEE d MMMM').format(entry.key),
            icon: Icons.event_note_outlined,
            trailing: Text(
              [
                '${entry.value.length} task${entry.value.length == 1 ? '' : 's'}',
                ..._outputTotals(entry.value, dept),
              ].join(' · '),
              style: muted,
            ),
            children: [
              for (final t in entry.value)
                TaskCard(
                  task: t,
                  meta: meta,
                  onTap: () => _openTask(context, meta, t),
                ),
            ],
          ),
      ],
    );
  }
}

List<String> _outputTotals(List<ActivityReport> tasks, Department? dept) {
  final totals = <String, int>{};
  for (final t in tasks) {
    t.outputs.forEach((k, v) => totals[k] = (totals[k] ?? 0) + v);
  }
  return [
    for (final e in totals.entries)
      '${dept?.outputLabel(e.key) ?? e.key.replaceAll('_', ' ')} ${e.value}',
  ];
}

// --------------------------------------------------------------- Review ---

class _ReviewTab extends ConsumerStatefulWidget {
  const _ReviewTab({required this.meta});
  final ReportsMeta meta;

  @override
  ConsumerState<_ReviewTab> createState() => _ReviewTabState();
}

class _ReviewTabState extends ConsumerState<_ReviewTab> {
  List<ActivityReport>? _waiting;
  List<ActivityReport>? _reviewed;
  Object? _error;
  int? _person;
  int _seq = 0;

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Picks up new submissions even when the count stays the same.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    final service = ref.read(dailyReportsProvider);
    try {
      final r = await Future.wait([
        service.list(const ReportFilter(toReview: true, limit: 300)),
        service.list(
          ReportFilter(
            reviewedByMe: true,
            reviews: const [ReviewState.approved, ReviewState.returned],
            from: widget.meta.today.subtract(const Duration(days: 14)),
            limit: 60,
          ),
        ),
      ]);
      if (!mounted || seq != _seq) return;
      setState(() {
        _waiting = r[0];
        _reviewed = r[1];
        _error = null;
      });
    } catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    }
  }

  Future<void> _review(ActivityReport t, bool approve) async {
    final saved = await reviewTask(context, ref, task: t, approve: approve);
    if (saved != null && mounted) {
      _snack(context, approve ? '${t.ref} approved' : '${t.ref} returned');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(reportsChangedProvider, (_, _) => _load());
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final meta = widget.meta;
    final waiting = _waiting;
    if (waiting == null) {
      return _error != null
          ? Text(describeReportError(_error!), style: muted)
          : const LinearProgressIndicator();
    }
    final people = {
      for (final t in waiting)
        if (t.userId != null) t.userId!: t.userName,
    };
    final shown =
        _byUrgency(waiting.where((t) => _person == null || t.userId == _person))
          ..sort((a, b) {
            // Oldest submission first within the same urgency.
            final u = _urgencyRank(a.urgency)
                .compareTo(_urgencyRank(b.urgency));
            if (u != 0) return u;
            return (a.submittedAt ?? DateTime(0)).compareTo(
              b.submittedAt ?? DateTime(0),
            );
          });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (people.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: Text('Everyone (${waiting.length})'),
                  selected: _person == null,
                  onSelected: (_) => setState(() => _person = null),
                ),
                for (final p in people.entries)
                  ChoiceChip(
                    label: Text(
                      '${p.value} (${waiting.where((t) => t.userId == p.key).length})',
                    ),
                    selected: _person == p.key,
                    onSelected: (_) => setState(() => _person = p.key),
                  ),
              ],
            ),
          ),
        _Section(
          key: const ValueKey('review-waiting'),
          title: 'Waiting for your review (${shown.length})',
          icon: Icons.hourglass_top,
          color: shown.isEmpty ? null : c.warningFg,
          children: [
            if (shown.isEmpty)
              const PanelEmpty(
                icon: Icons.inbox_outlined,
                title: 'Nothing waiting',
                message:
                    'Work your team submits shows here to approve or return.',
              ),
            for (final t in shown)
              TaskCard(
                task: t,
                meta: meta,
                showPerson: true,
                onTap: () => _openTask(context, meta, t),
                actions: [
                  OutlinedButton.icon(
                    key: ValueKey('return-${t.id}'),
                    onPressed: () => _review(t, false),
                    icon: const Icon(Icons.undo, size: 16),
                    label: const Text('Return'),
                  ),
                  FilledButton.icon(
                    key: ValueKey('approve-${t.id}'),
                    onPressed: () => _review(t, true),
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Approve'),
                  ),
                ],
              ),
          ],
        ),
        if ((_reviewed ?? const []).isNotEmpty)
          _Section(
            title: 'Reviewed by you, last 2 weeks',
            icon: Icons.history,
            children: [
              for (final t in _reviewed!)
                TaskCard(
                  task: t,
                  meta: meta,
                  showPerson: true,
                  onTap: () => _openTask(context, meta, t),
                ),
            ],
          ),
      ],
    );
  }
}

// ----------------------------------------------------------------- Team ---

enum _Period {
  today('Today', 'Today'),
  week('This week', 'Week'),
  month('This month', 'Month'),
  custom('Dates…', 'Dates…');

  const _Period(this.label, this.short);
  final String label;
  final String short;
}

enum _TaskFilter {
  open('Open'),
  submitted('Submitted'),
  waiting('Awaiting review'),
  approved('Approved'),
  blocked('Blocked'),
  overdue('Overdue'),
  mine('Assigned by me');

  const _TaskFilter(this.label);
  final String label;
}

class _TeamTab extends ConsumerStatefulWidget {
  const _TeamTab({required this.meta, required this.phone});

  final ReportsMeta meta;
  final bool phone;

  @override
  ConsumerState<_TeamTab> createState() => _TeamTabState();
}

class _TeamTabState extends ConsumerState<_TeamTab> {
  var _period = _Period.today;
  late DateTime _from = widget.meta.today;
  late DateTime _to = widget.meta.today;
  int? _departmentId;
  int? _userId;
  var _filter = _TaskFilter.open;
  TaskUrgency? _urgency;

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
  void didUpdateWidget(_TeamTab old) {
    super.didUpdateWidget(old);
    if (old.meta.today != widget.meta.today && _period != _Period.custom) {
      final range = _rangeFor(_period, widget.meta.today);
      _from = range.$1;
      _to = range.$2;
      _load();
    }
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

  Future<void> _setPeriod(_Period p) async {
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

  /// Open, blocked, overdue and "assigned by me" are about now; the
  /// others are about what was submitted in the period.
  ReportFilter get _listFilter {
    final dated =
        _filter == _TaskFilter.submitted ||
        _filter == _TaskFilter.waiting ||
        _filter == _TaskFilter.approved;
    return ReportFilter(
      from: dated ? _from : null,
      to: dated ? _to : null,
      departmentId: _departmentId,
      userId: _userId,
      urgency: _urgency,
      statuses: _filter == _TaskFilter.blocked
          ? const [ReportStatus.blocked]
          : null,
      reviews: switch (_filter) {
        _TaskFilter.submitted => const [
          ReviewState.submitted,
          ReviewState.approved,
          ReviewState.returned,
        ],
        _TaskFilter.waiting => const [ReviewState.submitted],
        _TaskFilter.approved => const [ReviewState.approved],
        _ => null,
      },
      openOnly: _filter == _TaskFilter.open || _filter == _TaskFilter.mine,
      overdueOnly: _filter == _TaskFilter.overdue,
      assignedByMe: _filter == _TaskFilter.mine,
      limit: 500,
    );
  }

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
    meta.person(_userId)?.fullName ?? 'Everyone',
    'Tasks: ${_filter.label}',
    if (_urgency != null) 'Urgency: ${_urgency!.label}',
  ].join(' · ');

  String get _reportTitle {
    if (_userId != null) return 'Staff Activity Report';
    if (_filter == _TaskFilter.open || _filter == _TaskFilter.overdue) {
      return 'Pending Tasks Report';
    }
    if (_filter == _TaskFilter.blocked) return 'Exception Report';
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
      if (mounted) _snack(context, 'Couldn’t make the report: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _assign() async {
    final saved = await showReportEditor(
      context,
      meta: meta,
      assign: true,
      assignTo: _userId,
    );
    if (saved == null || !mounted) return;
    _snack(context, 'Task assigned to ${saved.userName}');
  }

  Future<void> _copyReminder(List<ComplianceRow> notYet) async {
    final names = [for (final c in notYet) c.fullName];
    final list = names.length == 1
        ? names.first
        : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
    final text =
        'Hi $list, a reminder to submit today’s work in ${Dt.appName} '
        '(Daily reports › My tasks). Thank you!';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _snack(
      context,
      'Reminder for ${names.length} '
      '${names.length == 1 ? 'person' : 'people'} copied — paste it in '
      'WhatsApp or email.',
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(reportsChangedProvider, (_, _) => _load());
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: c.textMuted,
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
                    !meta.people.any(
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
        if (_loading)
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        if (meta.canAssign)
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
            const LinearProgressIndicator(),
        ],
      );
    }

    final s = summary;
    final submittedToday = [
      for (final r in s.compliance)
        if (r.submittedToday) r,
    ];
    final notYet = [
      for (final r in s.compliance)
        if (!r.submittedToday) r,
    ];
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
        LayoutBuilder(
          builder: (context, box) {
            void show(_TaskFilter f) {
              setState(() => _filter = f);
              _reloadEntries();
            }

            final stats = [
              _Stat(
                'Submitted',
                s.submitted,
                key: const ValueKey('stat-total'),
                hint: 'Tasks submitted in the period',
                onTap: () => show(_TaskFilter.submitted),
              ),
              _Stat(
                'Approved',
                s.reviewed(ReviewState.approved),
                good: true,
                onTap: () => show(_TaskFilter.approved),
              ),
              _Stat(
                'To review',
                s.reviewed(ReviewState.submitted),
                warn: true,
                hint: 'Submitted, waiting for review',
                onTap: () => show(_TaskFilter.waiting),
              ),
              _Stat(
                'Open now',
                s.open,
                hint: 'Not finished yet, any date',
                onTap: () => show(_TaskFilter.open),
              ),
              // Older tasks only: work can't be marked Blocked any more.
              if (s.count(ReportStatus.blocked) > 0)
                _Stat(
                  'Blocked',
                  s.count(ReportStatus.blocked),
                  alert: true,
                  onTap: () => show(_TaskFilter.blocked),
                ),
              _Stat(
                'Overdue',
                s.overdue.length,
                alert: true,
                key: const ValueKey('stat-overdue'),
                onTap: () => show(_TaskFilter.overdue),
              ),
            ];
            const gap = 10.0;
            final cols = box.maxWidth >= 860
                ? 6
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
          title: 'Who has reported',
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
                      for (final r in s.compliance)
                        _ComplianceRow(row: r, workingDays: s.workingDays),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),
        AppPanel(
          title: 'Departments',
          icon: Icons.apartment_outlined,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (s.departments.isEmpty)
                  Text('No departments.', style: muted),
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
        const SizedBox(height: 16),
        _Section(
          key: const ValueKey('team-tasks'),
          title:
              'Tasks · ${_filter.label}${entries == null ? '' : ' (${entries.length})'}',
          icon: Icons.list_alt_outlined,
          trailing: PopupMenuButton<TaskUrgency?>(
            key: const ValueKey('team-urgency'),
            tooltip: 'Urgency',
            onSelected: (u) {
              setState(() => _urgency = u);
              _reloadEntries();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('Any urgency')),
              for (final u in TaskUrgency.values)
                PopupMenuItem(
                  value: u,
                  child: Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 12,
                        color: u.color(theme.brightness),
                      ),
                      const SizedBox(width: 10),
                      Text(u.label),
                    ],
                  ),
                ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_urgency == null)
                  Text('Any urgency', style: muted)
                else
                  UrgencyPill(_urgency!),
                Icon(Icons.arrow_drop_down, size: 18, color: c.textMuted),
              ],
            ),
          ),
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in _TaskFilter.values)
                  if (f != _TaskFilter.mine || meta.canAssign)
                    ChoiceChip(
                      key: ValueKey('entries-${f.name}'),
                      label: Text(f.label),
                      selected: _filter == f,
                      onSelected: (_) {
                        setState(() => _filter = f);
                        _reloadEntries();
                      },
                    ),
              ],
            ),
            const SizedBox(height: 6),
            Text(switch (_filter) {
              _TaskFilter.open =>
                'Everything on people’s lists now, most urgent first.',
              _TaskFilter.mine => 'Tasks you assigned that aren’t done yet.',
              _TaskFilter.overdue ||
              _TaskFilter.blocked => 'From any date, not only this period.',
              _ => 'Submitted in this period.',
            }, style: muted),
            const SizedBox(height: 10),
            if (entries == null)
              const LinearProgressIndicator()
            else if (entries.isEmpty)
              Text('No tasks match.', style: muted)
            else
              for (final t
                  in _filter == _TaskFilter.open || _filter == _TaskFilter.mine
                      ? _byUrgency(entries)
                      : entries)
                TaskCard(
                  task: t,
                  meta: meta,
                  showPerson: true,
                  onTap: () => _openTask(context, meta, t),
                ),
          ],
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
        for (final r in rows)
          ActionChip(
            avatar: Icon(
              done ? Icons.check_circle : Icons.schedule,
              size: 16,
              color: done
                  ? Dt.statusGreen(theme.brightness)
                  : theme.colorScheme.error,
            ),
            label: Text(
              [
                r.fullName,
                if (r.departmentName.isNotEmpty) r.departmentName,
                if (r.open > 0) '${r.open} open',
              ].join(' · '),
            ),
            visualDensity: VisualDensity.compact,
            onPressed: () {
              setState(() {
                _userId = r.id;
                _filter = _TaskFilter.open;
              });
              _load();
            },
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
  final bool fill;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: fill
        ? const BoxConstraints(minWidth: double.infinity)
        : const BoxConstraints(maxWidth: 260),
    child: DropdownButtonFormField<T>(
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
    this.warn = false,
    this.good = false,
    this.hint,
    this.onTap,
  });

  final String label;
  final int value;
  final bool alert;
  final bool warn;
  final bool good;
  final String? hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = Clarity.of(theme);
    final color = value == 0
        ? scheme.onSurface
        : alert
        ? scheme.error
        : warn
        ? c.warningFg
        : good
        ? Dt.statusGreen(theme.brightness)
        : scheme.onSurface;
    final tile = Material(
      color: c.surface,
      borderRadius: BorderRadius.circular(Dt.rMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(Dt.rMd),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          decoration: BoxDecoration(
            border: Border.all(color: c.border),
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
        ),
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
            '${row.entries} task${row.entries == 1 ? '' : 's'}'
            '${row.open > 0 ? ' · ${row.open} open' : ''}',
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
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
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
                  '${d.activities} submitted',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                '${d.completed} approved',
                if (d.awaiting > 0) '${d.awaiting} to review',
                '${d.open} open',
                if (d.blocked > 0) '${d.blocked} blocked',
                '${d.people} reporting',
              ].join(' · '),
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
