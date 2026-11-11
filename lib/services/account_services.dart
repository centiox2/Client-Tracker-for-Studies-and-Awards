import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../state/cloud_sync.dart';
import 'cloud/cloud_api.dart';

typedef _Call = Future<Object?> Function(
  String name, [
  Map<String, Object?>? params,
]);

Map<String, Object?> _map(Object? v) => (v as Map).cast<String, Object?>();
DateTime? _time(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toLocal() : null;

// ---------------------------------------------------------------- sessions --

/// One place the person is signed in.
class AccountSession {
  const AccountSession({
    required this.id,
    required this.device,
    required this.signedIn,
    required this.lastSeen,
    required this.current,
    required this.remember,
  });

  final String id;
  final String device;
  final DateTime? signedIn;
  final DateTime? lastSeen;
  final bool current;
  final bool remember;

  static AccountSession fromJson(Map<String, Object?> j) => AccountSession(
    id: j['id']! as String,
    device: (j['device'] as String?) ?? 'Unknown device',
    signedIn: _time(j['signed_in']),
    lastSeen: _time(j['last_seen']),
    current: j['current'] == true,
    remember: j['remember'] == true,
  );
}

class SessionsService {
  SessionsService(this._call);
  final _Call _call;

  Future<List<AccountSession>> list() async => [
    for (final s in (await _call('user_sessions') as List? ?? const []))
      AccountSession.fromJson(_map(s)),
  ];

  /// Signs out one other session; returns how many ended.
  Future<int> signOut(String id) async =>
      ((await _call('user_sign_out_sessions', {'p_id': id})) as num?)
          ?.toInt() ??
      0;

  /// Signs out every session but this one.
  Future<int> signOutOthers() async =>
      ((await _call('user_sign_out_sessions', {'p_id': null})) as num?)
          ?.toInt() ??
      0;
}

final sessionsServiceProvider = Provider<SessionsService>(
  (ref) => SessionsService(ref.read(cloudSyncProvider.notifier).callAsUser),
);

// ------------------------------------------------------------- audit log ---

/// One change in the activity log.
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.at,
    required this.actor,
    required this.action,
    required this.table,
    required this.changed,
    this.oldRow,
    this.newRow,
  });

  final int id;
  final DateTime at;
  final String actor;

  /// added / changed / deleted
  final String action;
  final String table;
  final List<String> changed;
  final Map<String, Object?>? oldRow;
  final Map<String, Object?>? newRow;

  static AuditEntry fromJson(Map<String, Object?> j) => AuditEntry(
    id: (j['id'] as num).toInt(),
    at: _time(j['at']) ?? DateTime.now(),
    actor: (j['actor'] as String?) ?? '',
    action: (j['action'] as String?) ?? '',
    table: (j['table_name'] as String?) ?? '',
    changed: [for (final c in (j['changed'] as List? ?? const [])) '$c'],
    oldRow: j['old_row'] == null ? null : _map(j['old_row']),
    newRow: j['new_row'] == null ? null : _map(j['new_row']),
  );

  /// "Payment", "Week", "Staff member"…
  String get thing => switch (table) {
    'revenue_entries' => 'Payment',
    'weeks' => 'Week',
    'staff' => 'Staff member',
    'staff_day_off' => 'Time off',
    'day_notes' => 'Day note',
    'app_settings' => 'Setting',
    'departments' => 'Department',
    'activity_reports' => 'Daily report',
    'report_comments' => 'Comment',
    'app_users' => 'User',
    _ => table,
  };

  Map<String, Object?> get row => newRow ?? oldRow ?? const {};

  /// Which one: the payment's amount and note, the person's name…
  String describe({String currency = 'KSh'}) {
    final r = row;
    String? s(String k) {
      final v = r[k];
      return v == null || '$v'.trim().isEmpty ? null : '$v';
    }

    switch (table) {
      case 'revenue_entries':
        final cents = (r['amount_cents'] as num?)?.toInt() ?? 0;
        final amount = NumberFormat.decimalPattern().format(cents / 100);
        return ['$currency $amount', ?s('date'), ?s('note')].join(' · ');
      case 'weeks':
        return [s('start_date'), s('end_date')].whereType<String>().join(' – ');
      case 'staff':
      case 'departments':
        return s('name') ?? '';
      case 'app_users':
        return [
          s('full_name'),
          s('username') == null ? null : '@${s('username')}',
        ].whereType<String>().join(' · ');
      case 'app_settings':
        return s('key') ?? '';
      case 'activity_reports':
        return [
          s('report_date'),
          s('description'),
        ].whereType<String>().join(' · ');
      case 'report_comments':
        return s('body') ?? '';
      case 'day_notes':
        return s('note') ?? '';
      default:
        return '';
    }
  }

  /// "amount: 5,000 → 7,000"-style lines for a change.
  List<String> get differences => [
    for (final k in changed)
      '${k.replaceAll('_', ' ')}: ${_show(oldRow?[k])} → ${_show(newRow?[k])}',
  ];

  static String _show(Object? v) {
    if (v == null || '$v'.isEmpty) return '—';
    final t = '$v';
    return t.length > 60 ? '${t.substring(0, 57)}…' : t;
  }
}

class AuditService {
  AuditService(this._call);
  final _Call _call;

  /// Newest first; [before] continues from an earlier page.
  Future<List<AuditEntry>> list({int? before, int limit = 100}) async => [
    for (final e
        in (await _call('audit_list', {'p_before': ?before, 'p_limit': limit})
                as List? ??
            const []))
      AuditEntry.fromJson(_map(e)),
  ];
}

final auditServiceProvider = Provider<AuditService>(
  (ref) => AuditService(ref.read(cloudSyncProvider.notifier).callAsUser),
);

// --------------------------------------------------------- error reports ---

/// An error the app reported (counted when it happens again).
class ErrorReport {
  const ErrorReport({
    required this.message,
    required this.stack,
    required this.count,
    required this.lastSeen,
    required this.version,
    required this.platform,
    required this.who,
  });

  final String message;
  final String stack;
  final int count;
  final DateTime? lastSeen;
  final String version;
  final String platform;
  final String who;

  static ErrorReport fromJson(Map<String, Object?> j) => ErrorReport(
    message: (j['message'] as String?) ?? '',
    stack: (j['stack'] as String?) ?? '',
    count: (j['count'] as num?)?.toInt() ?? 1,
    lastSeen: _time(j['last_seen']),
    version: (j['app_version'] as String?) ?? '',
    platform: (j['platform'] as String?) ?? '',
    who: (j['who'] as String?) ?? '',
  );
}

class ErrorsService {
  ErrorsService(this._call);
  final _Call _call;

  Future<List<ErrorReport>> list() async => [
    for (final e in (await _call('error_list') as List? ?? const []))
      ErrorReport.fromJson(_map(e)),
  ];

  Future<void> clear() => _call('error_clear');
}

final errorsServiceProvider = Provider<ErrorsService>(
  (ref) => ErrorsService(ref.read(cloudSyncProvider.notifier).callAsUser),
);

/// A short message for these online calls.
String describeAccountError(Object e) {
  if (e is CloudException) {
    return switch (e.code) {
      'not_allowed' => 'Only an admin can see this.',
      'not_signed_in' => 'Your sign-in has ended. Sign out and in again.',
      'needs_update' =>
        'The online database needs an update for this. Ask the admin to '
            'apply it.',
      _ => 'That didn’t work (${e.code}).',
    };
  }
  return 'Couldn’t reach the online database. Check the internet connection.';
}
