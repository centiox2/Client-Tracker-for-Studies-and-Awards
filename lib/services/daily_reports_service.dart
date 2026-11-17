import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import '../state/cloud_sync.dart';
import 'cloud/cloud_api.dart';
import 'cloud/connection_error.dart';

/// What Daily reports opens with (see [DailyReportsService.start]).
class ReportsStart {
  const ReportsStart({
    required this.meta,
    required this.badge,
    required this.tasks,
    required this.submissions,
  });

  final ReportsMeta meta;
  final ReportBadge badge;

  /// Your to-do list: everything not done, and anything returned to you.
  final List<ActivityReport> tasks;

  /// What you submitted in the last 60 days (waiting or approved).
  final List<ActivityReport> submissions;

  factory ReportsStart.fromJson(Map<String, Object?> json) {
    List<ActivityReport> reports(Object? rows) => [
      for (final r in (rows as List? ?? const []))
        ActivityReport.fromJson((r as Map).cast<String, Object?>()),
    ];
    return ReportsStart(
      meta: ReportsMeta.fromJson((json['meta'] as Map).cast<String, Object?>()),
      badge: json['badge'] == null
          ? const ReportBadge()
          : ReportBadge.fromJson(
              (json['badge'] as Map).cast<String, Object?>(),
            ),
      tasks: reports(json['tasks']),
      submissions: reports(json['submissions']),
    );
  }

  Map<String, Object?> toJson() => {
    'meta': meta.toJson(),
    'badge': badge.toJson(),
    'tasks': [for (final t in tasks) t.toJson()],
    'submissions': [for (final s in submissions) s.toJson()],
  };
}

/// Daily reports, read and written online as the signed-in person. The
/// online database decides what each person may see and change.
class DailyReportsService {
  DailyReportsService(this._call, {this.onChanged});

  final Future<Object?> Function(String name, [Map<String, Object?>? params])
  _call;

  /// Called after a task is added, changed, reviewed or deleted.
  final void Function()? onChanged;

  static Map<String, Object?> _map(Object? v) =>
      (v as Map).cast<String, Object?>();

  static List<ActivityReport> _reports(Object? rows) => [
    for (final r in (rows as List? ?? const []))
      ActivityReport.fromJson(_map(r)),
  ];

  Future<ReportsMeta> meta() async =>
      ReportsMeta.fromJson(_map(await _call('reports_meta')));

  /// Everything the page opens with, in one call.
  Future<ReportsStart> start() async =>
      ReportsStart.fromJson(_map(await _call('report_start')));

  Future<List<ActivityReport>> list(ReportFilter filter) async =>
      _reports(await _call('report_list', {'p_filter': filter.toJson()}));

  /// Every task matching [filter], fetched [page] at a time (for exports,
  /// which must not stop at the screen's limit). A task that moves between
  /// pages while they are read is kept once.
  Future<List<ActivityReport>> listAll(
    ReportFilter filter, {
    int page = 1000,
    int maxPages = 100,
  }) async {
    final seen = <int>{};
    final out = <ActivityReport>[];
    for (var i = 0; i < maxPages; i++) {
      final rows = _reports(
        await _call('report_list', {
          'p_filter': {...filter.toJson(), 'limit': page, 'offset': i * page},
        }),
      );
      for (final r in rows) {
        final id = r.id;
        if (id == null || seen.add(id)) out.add(r);
      }
      if (rows.length < page) break;
    }
    return out;
  }

  Future<ReportSummary> summary(
    DateTime from,
    DateTime to, {
    int? departmentId,
    int? userId,
  }) async => ReportSummary.fromJson(
    _map(
      await _call('report_summary', {
        'p_from': dateKey(from),
        'p_to': dateKey(to),
        'p_department': departmentId,
        'p_user': ?userId,
      }),
    ),
  );

  /// Adds or changes a task (no [ActivityReport.id]: a new one).
  Future<ActivityReport> save(ActivityReport report) async {
    final saved = ActivityReport.fromJson(
      _map(await _call('report_save', {'p_report': report.toSaveJson()})),
    );
    onChanged?.call();
    return saved;
  }

  /// Marks it done and sends it for review, dated today. [note] goes on
  /// the timeline for the reviewer.
  Future<ActivityReport> submit(
    ActivityReport report, {
    String note = '',
  }) async {
    final saved = ActivityReport.fromJson(
      _map(
        await _call('report_save', {
          'p_report': report.toSaveJson(submit: true, note: note),
        }),
      ),
    );
    onChanged?.call();
    return saved;
  }

  /// Sends what was saved on this device while offline, as it was.
  Future<ActivityReport> saveQueued(Map<String, Object?> payload) async =>
      ActivityReport.fromJson(
        _map(await _call('report_save', {'p_report': payload})),
      );

  /// Takes back a submission that hasn't been reviewed yet (Undo): it goes
  /// back on the person's list as Doing.
  Future<ActivityReport> withdraw(int id) async {
    final saved = ActivityReport.fromJson(
      _map(await _call('report_withdraw', {'p_report': id})),
    );
    onChanged?.call();
    return saved;
  }

  /// Approves submitted work, or returns it ([approve] false; [comment]
  /// needed) to the person to do again.
  Future<ActivityReport> review(
    int id, {
    required bool approve,
    String comment = '',
  }) async {
    final saved = ActivityReport.fromJson(
      _map(
        await _call('report_review', {
          'p_report': id,
          'p_decision': approve ? 'approved' : 'returned',
          'p_comment': comment.trim(),
        }),
      ),
    );
    onChanged?.call();
    return saved;
  }

  Future<void> delete(int id) async {
    await _call('report_delete', {'p_report': id});
    onChanged?.call();
  }

  Future<List<ReportChange>> history(int id) async {
    final rows = await _call('report_history', {'p_report': id});
    return [
      for (final r in (rows as List? ?? const []))
        ReportChange.fromJson(_map(r)),
    ];
  }

  Future<List<ReportComment>> comments(int reportId) async =>
      _comments(await _call('report_comments', {'p_report': reportId}));

  /// Adds a comment; returns the task's whole timeline.
  Future<List<ReportComment>> addComment(int reportId, String body) async {
    final all = _comments(
      await _call('report_comment_add', {
        'p_report': reportId,
        'p_body': body.trim(),
      }),
    );
    onChanged?.call();
    return all;
  }

  Future<void> deleteComment(int commentId) async {
    await _call('report_comment_delete', {'p_comment': commentId});
    onChanged?.call();
  }

  static List<ReportComment> _comments(Object? rows) => [
    for (final r in (rows as List? ?? const []))
      ReportComment.fromJson(_map(r)),
  ];

  /// The badge counts; also makes the day's due / overdue reminders.
  Future<ReportBadge> badge() async =>
      ReportBadge.fromJson(_map(await _call('report_badge')));

  /// The newest 60 notifications.
  Future<List<ReportNotification>> notifications() async {
    final rows = await _call('report_notifications');
    return [
      for (final r in (rows as List? ?? const []))
        ReportNotification.fromJson(_map(r)),
    ];
  }

  /// Marks [ids] read (null: all of them).
  Future<void> markRead([List<int>? ids]) async {
    await _call('report_notifications_read', {'p_ids': ids});
  }

  /// Admin: creates (no [id]) or changes a department.
  Future<Department> saveDepartment({
    int? id,
    required String name,
    required List<OutputField> outputs,
    bool active = true,
  }) async => Department.fromJson(
    _map(
      await _call('admin_save_department', {
        'p_department': {
          'id': ?id,
          'name': name.trim(),
          'outputs': [for (final o in outputs) o.toJson()],
          'active': active,
        },
      }),
    ),
  );
}

final dailyReportsProvider = Provider<DailyReportsService>(
  (ref) => DailyReportsService(
    ref.read(cloudSyncProvider.notifier).callAsUser,
    onChanged: () => ref.read(reportsChangedProvider.notifier).bump(),
  ),
);

/// Goes up when tasks change, so the badge and lists check again.
final reportsChangedProvider = NotifierProvider<ReportsChangedNotifier, int>(
  ReportsChangedNotifier.new,
);

class ReportsChangedNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// Whether daily reports can be asked for now: accounts on, someone signed
/// in, and the connection up. The signed-in id, else null.
int? _reportsUser(Ref ref) {
  if (!ref.watch(accountsEnabledProvider)) return null;
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  if (!ref.watch(cloudSyncProvider.select((s) => s.phase == SyncPhase.live))) {
    return null;
  }
  return user.id;
}

/// What the Daily reports page opens with, kept up to date in the
/// background and saved on this device, so the page shows at once — even
/// before the connection is up — and refreshes quietly.
final reportStartProvider =
    NotifierProvider<ReportStartNotifier, ReportsStart?>(
      ReportStartNotifier.new,
    );

class ReportStartNotifier extends Notifier<ReportsStart?> {
  static String _key(int user) => 'daily_reports_start_v2_$user';

  Object? _error;

  /// Why the last refresh failed (null when it worked).
  Object? get error => _error;

  int _seq = 0;

  @override
  ReportsStart? build() {
    ref.watch(reportsChangedProvider);
    ref.watch(dataVersionProvider);
    final me = ref.watch(currentUserProvider)?.id;
    final online = _reportsUser(ref);
    // The copy saved on this device first, then the latest.
    if (me != null) {
      final current = stateOrNull;
      if (current == null || current.meta.myId != me) {
        unawaited(_fromDisk(me));
      }
    }
    if (online != null) unawaited(refresh());
    final now = stateOrNull;
    return now != null && now.meta.myId == me ? now : null;
  }

  Future<void> _fromDisk(int me) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key(me));
      if (raw == null || stateOrNull != null) return;
      final start = ReportsStart.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
      if (stateOrNull == null && start.meta.myId == me) state = start;
    } catch (_) {
      // A copy from an older version: ignored, the latest replaces it.
    }
  }

  /// Reads the latest; keeps what's shown if it can't. Anything saved on
  /// this device while offline is sent first.
  Future<void> refresh() async {
    final seq = ++_seq;
    try {
      await ref.read(reportOutboxProvider.notifier).flush();
      final start = await ref.read(dailyReportsProvider).start();
      if (seq != _seq) return;
      _error = null;
      state = start;
      ref.read(reportBadgeProvider.notifier).set(start.badge);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(start.meta.myId), jsonEncode(start.toJson()));
    } catch (e) {
      if (seq != _seq) return;
      _error = e;
      // Tell the page (it shows the error when there's nothing to show).
      ref.notifyListeners();
    }
  }
}

/// The counts on the Daily reports menu item and the bell: unread
/// notifications and work waiting for review. Checked about once a minute
/// while online, and whenever tasks change.
final reportBadgeProvider = NotifierProvider<ReportBadgeNotifier, ReportBadge?>(
  ReportBadgeNotifier.new,
);

class ReportBadgeNotifier extends Notifier<ReportBadge?> {
  Timer? _timer;

  /// How often the badge is checked while online.
  static const every = Duration(seconds: 60);

  @override
  ReportBadge? build() {
    ref.watch(reportsChangedProvider);
    final me = _reportsUser(ref);
    _timer?.cancel();
    ref.onDispose(() => _timer?.cancel());
    if (me == null) return null;
    _timer = Timer.periodic(every, (_) => refresh());
    unawaited(refresh());
    return stateOrNull;
  }

  void set(ReportBadge badge) => state = badge;

  Future<void> refresh() async {
    try {
      state = await ref.read(dailyReportsProvider).badge();
    } catch (_) {
      // Offline for a moment: keep the last counts.
    }
  }
}

/// A short, plain message for a report action that didn't work.
String describeReportError(Object e) {
  if (e is! CloudException) {
    return 'Couldn’t reach the online database. Daily reports need an '
        'internet connection — check it and try again.';
  }
  return switch (e.code) {
    'description_required' => 'Give the task a title.',
    'blocker_required' => 'Say what is blocking it, so someone can help.',
    'comment_required' =>
      'Say why you’re returning it, so they know what to fix.',
    'already_submitted' =>
      'It’s already been submitted. Ask the reviewer to return it if '
          'something needs changing.',
    'not_submitted' => 'It isn’t waiting for review any more.',
    'not_allowed' =>
      'You can’t do that for this task. Only the person it belongs to, '
          'whoever assigned it, their department head, a manager or an '
          'admin can.',
    'unknown_user' => 'That person’s account no longer exists.',
    'unknown_report' => 'That task no longer exists.',
    'bad_status' || 'bad_urgency' || 'bad_decision' =>
      'This version of the app is out of date. Update it and try again.',
    'bad_outputs' => 'Each output needs a name (letters, numbers and spaces).',
    'name_taken' => 'There’s already a department with that name.',
    'bad_name' => 'Enter a name.',
    'not_signed_in' =>
      'Your sign-in has ended, or this needs an admin. Sign out and in '
          'again.',
    'needs_update' =>
      'The online database hasn’t been set up for this version yet. Ask '
          'the admin to apply the update.',
    _ => 'That didn’t work (${e.code}).',
  };
}

// ------------------------------------------------------------- Offline ---

/// A task saved on this device while offline, waiting to be sent.
class QueuedTask {
  const QueuedTask({
    required this.report,
    required this.payload,
    required this.submit,
    this.error,
  });

  /// How it shows meanwhile ([ActivityReport.pending]; a new one has a
  /// negative id).
  final ActivityReport report;

  /// What is sent (the same as [DailyReportsService.save] sends).
  final Map<String, Object?> payload;
  final bool submit;

  /// Why the online database refused it the last time it was sent (kept
  /// here until it is changed, sent again or discarded).
  final String? error;

  QueuedTask withError(String? why) =>
      QueuedTask(report: report, payload: payload, submit: submit, error: why);

  factory QueuedTask.fromJson(Map<String, Object?> json) {
    final payload = (json['payload'] as Map).cast<String, Object?>();
    final report = ActivityReport.fromJson(
      (json['report'] as Map).cast<String, Object?>(),
    );
    return QueuedTask(
      report: report.clientOp == null && payload['op'] is String
          ? report.copyWith(clientOp: payload['op'] as String)
          : report,
      payload: payload,
      submit: json['submit'] as bool? ?? false,
      error: json['error'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'report': report.toJson(),
    'payload': payload,
    'submit': submit,
    'error': ?error,
  };
}

/// A name for creating one new task, unique to this device's try.
String newClientOp() {
  final r = Random.secure();
  return [
    for (var i = 0; i < 16; i++)
      r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// What happened to a save: the task as it is now, and whether it is
/// waiting on this device for the connection.
typedef SaveOutcome = ({ActivityReport task, bool queued});

/// Tasks added, changed or submitted while offline, kept on this device
/// (per person) and sent when the connection is back. They show on the
/// lists meanwhile, marked "Waiting to send".
final reportOutboxProvider =
    NotifierProvider<ReportOutboxNotifier, List<QueuedTask>>(
      ReportOutboxNotifier.new,
    );

class ReportOutboxNotifier extends Notifier<List<QueuedTask>> {
  static String _key(int user) => 'daily_reports_outbox_$user';

  int? _user;
  Future<void>? _loading;
  bool _flushing = false;

  /// Why something sent later was refused (shown once, then cleared).
  String? refused;

  @override
  List<QueuedTask> build() {
    final me = ref.watch(currentUserProvider)?.id;
    _user = me;
    if (me == null) return const [];
    _loading = _load(me);
    return const [];
  }

  Future<void> _load(int me) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key(me));
      if (raw == null || _user != me) return;
      final items = [
        for (final r in jsonDecode(raw) as List)
          QueuedTask.fromJson((r as Map).cast<String, Object?>()),
      ];
      if (_user == me) state = [...items, ...state];
    } catch (_) {
      // Unreadable: nothing waiting.
    }
  }

  Future<void> _store() async {
    final me = _user;
    if (me == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (state.isEmpty) {
      await prefs.remove(_key(me));
    } else {
      await prefs.setString(
        _key(me),
        jsonEncode([for (final q in state) q.toJson()]),
      );
    }
  }

  DateTime get _today {
    final meta = ref.read(reportStartProvider)?.meta;
    if (meta != null) return meta.today;
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// Saves (or with [submit], submits) [report]; if the connection is down
  /// it waits on this device instead and is sent later, keeping the day it
  /// was done. Errors from the online database (not allowed, a title
  /// needed…) are thrown as usual.
  Future<SaveOutcome> save(
    ActivityReport report, {
    bool submit = false,
    String note = '',
  }) async {
    await _loading;
    final service = ref.read(dailyReportsProvider);
    // A new task keeps one name for creating it through every try, online
    // or queued, so it can only be saved once.
    if (!report.isSaved && report.clientOp == null) {
      report = report.copyWith(clientOp: newClientOp());
    }
    if (report.pending) {
      return (task: _queue(report, submit, note), queued: true);
    }
    try {
      final saved = submit
          ? await service.submit(report, note: note)
          : await service.save(report);
      return (task: saved, queued: false);
    } on CloudException {
      rethrow;
    } catch (e) {
      // Only a lost connection is queued; any other fault is shown.
      if (!isConnectionError(e)) rethrow;
      return (task: _queue(report, submit, note), queued: true);
    }
  }

  ActivityReport _queue(ActivityReport report, bool submit, String note) {
    final today = _today;
    // A change to something already waiting replaces it.
    final old = state.where((q) => q.report.id == report.id).firstOrNull;
    final submitting =
        submit || (old?.submit ?? false) && !report.status.isOpen;
    final minId = state.fold<int>(
      0,
      (m, q) => (q.report.id ?? 0) < m ? q.report.id! : m,
    );
    final id = report.id ?? minId - 1;
    final me = ref.read(reportStartProvider)?.meta;
    final shown = report.copyWith(
      departmentId: report.departmentId ?? me?.myDepartmentId,
      id: id,
      pending: true,
      userId: report.userId ?? me?.myId,
      status: submitting ? ReportStatus.done : report.status,
      review: submitting ? ReviewState.submitted : null,
      date: submitting ? today : null,
      submittedAt: submitting ? DateTime.now() : null,
    );
    final payload = shown.toSaveJson(
      submit: submitting,
      note: note,
      doneOn: submitting ? today : null,
    );
    final item = QueuedTask(
      report: shown,
      payload: payload,
      submit: submitting,
    );
    state = [
      for (final q in state)
        if (q.report.id != id) q,
      item,
    ];
    unawaited(_store());
    ref.read(reportsChangedProvider.notifier).bump();
    return shown;
  }

  /// Takes back something waiting to be sent (Undo). True if it was there.
  bool cancel(int id) {
    final before = state.length;
    state = [
      for (final q in state)
        if (q.report.id != id) q,
    ];
    if (state.length == before) return false;
    unawaited(_store());
    return true;
  }

  /// Refusals that are about the connection or the sign-in, not the task:
  /// everything waits and is sent again later.
  static const _tryLater = {'not_signed_in', 'needs_update'};

  /// Sends what is waiting, oldest first. It stops (keeping everything)
  /// when the connection, the sign-in or the online database isn't ready;
  /// a task the online database refuses stays here with the reason, to be
  /// changed or discarded by the person — nothing is thrown away unasked.
  Future<void> flush() async {
    await _loading;
    if (_flushing || state.isEmpty) return;
    _flushing = true;
    var sent = false;
    try {
      final service = ref.read(dailyReportsProvider);
      for (final q in [...state]) {
        try {
          await service.saveQueued(q.payload);
        } on CloudException catch (e) {
          if (_tryLater.contains(e.code)) break;
          final why = describeReportError(e);
          refused = why;
          state = [
            for (final x in state) identical(x, q) ? x.withError(why) : x,
          ];
          await _store();
          continue;
        } catch (_) {
          break;
        }
        sent = true;
        state = [
          for (final x in state)
            if (!identical(x, q)) x,
        ];
        await _store();
      }
    } finally {
      _flushing = false;
    }
    if (sent) ref.read(reportsChangedProvider.notifier).bump();
  }

  /// Why each waiting task was refused, by its id (only those refused).
  Map<int, String> get refusals => {
    for (final q in state)
      if (q.error != null && q.report.id != null) q.report.id!: q.error!,
  };
}

/// Tasks deleted a moment ago, hidden while their Undo is offered.
final reportHiddenProvider = NotifierProvider<ReportHiddenNotifier, Set<int>>(
  ReportHiddenNotifier.new,
);

class ReportHiddenNotifier extends Notifier<Set<int>> {
  @override
  Set<int> build() => const {};

  void hide(int id) => state = {...state, id};
  void show(int id) => state = {...state}..remove(id);
}

/// What the page shows: the latest from [reportStartProvider], with what is
/// waiting to be sent and without what was just deleted.
final reportViewProvider = Provider<ReportsStart?>((ref) {
  final start = ref.watch(reportStartProvider);
  if (start == null) return null;
  final queued = ref.watch(reportOutboxProvider);
  final hidden = ref.watch(reportHiddenProvider);
  if (queued.isEmpty && hidden.isEmpty) return start;
  final replaced = {for (final q in queued) q.report.id};
  bool keep(ActivityReport t) =>
      !hidden.contains(t.id) && !replaced.contains(t.id);
  final waiting = [
    for (final q in queued)
      if (!hidden.contains(q.report.id)) q.report,
  ];
  return ReportsStart(
    meta: start.meta,
    badge: start.badge,
    tasks: [...waiting.where((t) => t.isOpen), ...start.tasks.where(keep)],
    submissions: [
      ...waiting.where((t) => t.isSubmitted),
      ...start.submissions.where(keep),
    ],
  );
});

// ------------------------------------------------------- Remembered ---

/// The last choices in Add activity, kept per person on this device:
/// Done today or To do, and the urgency.
typedef ReportChoices = ({String mode, TaskUrgency urgency});

final reportChoicesProvider =
    NotifierProvider<ReportChoicesNotifier, ReportChoices>(
      ReportChoicesNotifier.new,
    );

class ReportChoicesNotifier extends Notifier<ReportChoices> {
  static const _default = (mode: 'done', urgency: TaskUrgency.normal);
  static String _key(int user) => 'daily_reports_choices_$user';

  @override
  ReportChoices build() {
    final me = ref.watch(currentUserProvider)?.id;
    if (me != null) unawaited(_load(me));
    return _default;
  }

  Future<void> _load(int me) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key(me));
      if (raw == null) return;
      final j = (jsonDecode(raw) as Map).cast<String, Object?>();
      state = (
        mode: j['mode'] as String? ?? 'done',
        urgency: TaskUrgency.fromCode(j['urgency'] as String?),
      );
    } catch (_) {}
  }

  Future<void> remember({String? mode, TaskUrgency? urgency}) async {
    state = (mode: mode ?? state.mode, urgency: urgency ?? state.urgency);
    final me = ref.read(currentUserProvider)?.id;
    if (me == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(me),
      jsonEncode({'mode': state.mode, 'urgency': state.urgency.code}),
    );
  }
}

// ----------------------------------------------------------- Requests ---

/// Asks the Daily reports page to put the cursor somewhere: the quick line
/// (the N key, the 4 pm reminder) or the search (the / key).
enum ReportFocus { quickLine, search }

final reportFocusProvider = NotifierProvider<ReportFocusNotifier, ReportFocus?>(
  ReportFocusNotifier.new,
);

class ReportFocusNotifier extends Notifier<ReportFocus?> {
  @override
  ReportFocus? build() => null;

  void request(ReportFocus f) => state = f;
  void done() => state = null;
}
