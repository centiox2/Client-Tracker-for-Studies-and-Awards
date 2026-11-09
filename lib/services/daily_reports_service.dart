import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/daily_report.dart';
import '../state/cloud_sync.dart';
import 'cloud/cloud_api.dart';

/// Daily activity reports, read and written online as the signed-in person.
/// The online database decides what each person may see and change.
class DailyReportsService {
  DailyReportsService(this._call);

  final Future<Object?> Function(String name, [Map<String, Object?>? params])
  _call;

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

  Future<ActivityReport> save(ActivityReport report) async =>
      ActivityReport.fromJson(
        _map(await _call('report_save', {'p_report': report.toSaveJson()})),
      );

  Future<void> delete(int id) => _call('report_delete', {'p_report': id});

  Future<List<ReportChange>> history(int id) async {
    final rows = await _call('report_history', {'p_report': id});
    return [
      for (final r in (rows as List? ?? const []))
        ReportChange.fromJson(_map(r)),
    ];
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
  (ref) => DailyReportsService(ref.read(cloudSyncProvider.notifier).callAsUser),
);

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
    'not_allowed' => 'Only the person who wrote a report can change it.',
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
