import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import '../state/cloud_sync.dart';
import 'cloud/cloud_api.dart';

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

  /// Reads the latest; keeps what's shown if it can't.
  Future<void> refresh() async {
    final seq = ++_seq;
    try {
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
