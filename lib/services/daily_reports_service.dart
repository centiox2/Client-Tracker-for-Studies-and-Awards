import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';
import '../state/cloud_sync.dart';
import 'cloud/cloud_api.dart';

/// Daily activity reports, read and written online as the signed-in person.
/// The online database decides what each person may see and change.
class DailyReportsService {
  DailyReportsService(this._call, {this.onChanged});

  final Future<Object?> Function(String name, [Map<String, Object?>? params])
  _call;

  /// Called after a report is added, changed or deleted.
  final void Function()? onChanged;

  static Map<String, Object?> _map(Object? v) =>
      (v as Map).cast<String, Object?>();

  Future<ReportsMeta> meta() async =>
      ReportsMeta.fromJson(_map(await _call('reports_meta')));

  Future<List<ActivityReport>> list(ReportFilter filter) async {
    final rows = await _call('report_list', {'p_filter': filter.toJson()});
    return [
      for (final r in (rows as List? ?? const []))
        ActivityReport.fromJson(_map(r)),
    ];
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

  Future<ActivityReport> save(ActivityReport report) async {
    final saved = ActivityReport.fromJson(
      _map(await _call('report_save', {'p_report': report.toSaveJson()})),
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

  /// Adds a comment; returns all the report's comments.
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

/// Goes up when the person's reports change (or a new day starts), so the
/// "nothing recorded today" reminder checks again.
final reportsChangedProvider = NotifierProvider<ReportsChangedNotifier, int>(
  ReportsChangedNotifier.new,
);

class ReportsChangedNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// True when the signed-in person has a department and hasn't recorded
/// anything today: the Daily reports page shows a reminder dot. False when
/// it can't be checked (offline, no department, no accounts).
final reportDueTodayProvider = FutureProvider<bool>((ref) async {
  ref.watch(reportsChangedProvider);
  if (!ref.watch(accountsEnabledProvider)) return false;
  final user = ref.watch(currentUserProvider);
  if (user == null || user.departmentId == null) return false;
  // Asked again once the connection is up (the sign-in may only be usable
  // online after the app has started).
  if (!ref.watch(cloudSyncProvider.select((s) => s.phase == SyncPhase.live))) {
    return false;
  }
  try {
    // "Today" as the online database sees it (Kenya time), like every
    // other daily-report decision — not this device's clock, which may be
    // in another time zone or simply wrong.
    final service = ref.read(dailyReportsProvider);
    final today = (await service.meta()).today;
    final mine = await service.list(
      ReportFilter(from: today, to: today, userId: user.id),
    );
    return mine.isEmpty;
  } catch (_) {
    return false;
  }
});

/// A short, plain message for a report action that didn't work.
String describeReportError(Object e) {
  if (e is! CloudException) {
    return 'Couldn’t reach the online database. Daily reports need an '
        'internet connection — check it and try again.';
  }
  return switch (e.code) {
    'no_department' =>
      'You aren’t in a department yet. Ask an admin to set yours in '
          'Settings › Users.',
    'future_date' => 'The date can’t be in the future.',
    'date_too_old' =>
      'Reports can be added or moved up to 7 days back. Ask a manager to '
          'correct older ones.',
    'due_date_required' =>
      'Anything not completed needs a due / follow-up date.',
    'description_required' => 'Describe the activity or task.',
    'not_allowed' =>
      'Only the person it belongs to, whoever assigned it, or an admin can '
          'change it.',
    'unknown_user' => 'That person’s account no longer exists.',
    'unknown_report' => 'That report no longer exists.',
    'bad_outputs' => 'Each output needs a name (letters, numbers and spaces).',
    'name_taken' => 'There’s already a department with that name.',
    'bad_name' => 'Enter a name.',
    'not_signed_in' =>
      'Your sign-in has ended, or this needs an admin. Sign out and in '
          'again.',
    'needs_update' =>
      'The online database hasn’t been set up for daily reports yet. Ask '
          'the admin to apply the update.',
    _ => 'That didn’t work (${e.code}).',
  };
}
