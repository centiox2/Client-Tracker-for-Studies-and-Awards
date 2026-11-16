import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:excel/excel.dart';
import 'package:client_tracker/app.dart';
import 'package:client_tracker/services/daily_report_export.dart';
import 'package:client_tracker/services/daily_reports_service.dart';
import 'package:client_tracker/services/todo_service.dart';
import 'package:client_tracker/screens/daily_reports/report_editor.dart'
    show TaskMode, TaskModeToggle, UrgencyPill;
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/auth_repository.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/revenue_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/services/cloud/cloud_api.dart';
import 'package:client_tracker/services/cloud/sync_engine.dart';
import 'package:client_tracker/state/app_state.dart';
import 'package:client_tracker/state/cloud_sync.dart';

/// An in-memory stand-in for the Supabase functions (same rules: anyone
/// reads, a token is needed to write, the first password claims).
class FakeCloud implements CloudApi {
  final tables = <String, Map<String, Map<String, Object?>>>{
    for (final t in AppDatabase.syncedTables.keys) t: {},
  };
  String? password;
  final tokens = <String>{};
  bool offline = false;
  final _changes = StreamController<CloudChange>.broadcast();
  final _connection = StreamController<bool>.broadcast();

  /// Every change applied, as live updates other devices would receive.
  final emitted = <CloudChange>[];

  void _online() {
    if (offline) throw Exception('offline');
  }

  String? recoveryCode;

  /// Passwords of the other profiles (missing = open).
  final profilePasswords = <String, String>{};
  final teamTokens = <String>{};

  @override
  Future<Map<String, bool>> profileStatus() async {
    _online();
    return {
      for (final r in ['admin_team', 'director', 'team'])
        r: profilePasswords.containsKey(r),
    };
  }

  /// Bumped whenever a profile's password changes.
  final profileVersionNumbers = <String, int>{};

  @override
  Future<Map<String, String>> profileVersions() async {
    _online();
    return {
      for (final r in ['admin_team', 'director', 'team'])
        r: 'v${profileVersionNumbers[r] ?? 0}',
    };
  }

  @override
  Future<String> profileLogin(String role, String p) async {
    _online();
    final want = profilePasswords[role];
    if (want != null && want != p) throw CloudException('wrong_password');
    if (role != 'admin_team') {
      final t = '$role-${viewTokens.length}';
      viewTokens[t] = role;
      return t;
    }
    final t = 'team-${teamTokens.length}';
    teamTokens.add(t);
    return t;
  }

  @override
  Future<void> setProfilePassword(String token, String role, String p) async {
    _online();
    if (!tokens.contains(token)) throw CloudException('not_signed_in');
    if (p.isEmpty) {
      profilePasswords.remove(role);
    } else {
      profilePasswords[role] = p;
    }
    profileVersionNumbers[role] = (profileVersionNumbers[role] ?? 0) + 1;
    if (role == 'admin_team') teamTokens.clear();
  }

  @override
  Future<String> createRecoveryCode(String token) async {
    _online();
    if (!tokens.contains(token)) throw CloudException('not_signed_in');
    return recoveryCode = 'ABCD-EFGH-JKLM-NPQR';
  }

  @override
  Future<bool> hasRecoveryCode(String token) async {
    _online();
    if (!tokens.contains(token)) throw CloudException('not_signed_in');
    return recoveryCode != null;
  }

  @override
  Future<String> recover(String code, String newPassword) async {
    _online();
    final given = code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    if (recoveryCode == null || given != recoveryCode!.replaceAll('-', '')) {
      throw CloudException('wrong_recovery_code');
    }
    password = newPassword;
    recoveryCode = null;
    tokens.clear();
    final t = 'token-${DateTime.now().microsecondsSinceEpoch}';
    tokens.add(t);
    return t;
  }

  /// Tokens of the view-only profiles: token -> role.
  final viewTokens = <String, String>{};

  /// What each read was made as, newest last.
  final reads = <String>[];

  /// Runs while a read is on its way (to test edits made meanwhile).
  void Function()? duringRead;

  @override
  Future<Map<String, List<Map<String, Object?>>>> snapshot(String token) async {
    _online();
    duringRead?.call();
    final role = tokens.contains(token)
        ? 'admin'
        : teamTokens.contains(token)
        ? 'admin_team'
        : viewTokens[token] ?? _userRole(token);
    if (role == null) throw CloudException('not_signed_in');
    reads.add(role);
    final money = role == 'admin' || role == 'director';
    return {
      for (final MapEntry(:key, :value) in tables.entries)
        key: money || !key.startsWith('revenue')
            ? [for (final r in value.values) Map.of(r)]
            : [],
    };
  }

  @override
  Future<void> push(String token, Map<String, Object?> payload) async {
    _online();
    final userRole = _userRole(token);
    final team = teamTokens.contains(token) || userRole == 'admin_team';
    if (!tokens.contains(token) && !team && userRole != 'admin') {
      throw CloudException('not_signed_in');
    }
    final deletes = (payload['deletes'] as Map? ?? {}).cast<String, List>();
    final upserts = (payload['upserts'] as Map? ?? {}).cast<String, List>();
    if (team &&
        [
          'revenue_entries',
          'revenue_changes',
        ].any((t) => (deletes[t] ?? upserts[t] ?? const []).isNotEmpty)) {
      throw CloudException('not_allowed');
    }
    for (final MapEntry(key: t, value: keys) in deletes.entries) {
      final pk = AppDatabase.syncedTables[t]!;
      for (final k in keys) {
        tables[t]!.remove('$k');
        final c = CloudChange(table: t, deleted: true, row: {pk: k});
        emitted.add(c);
        _changes.add(c);
      }
    }
    for (final t in AppDatabase.syncedTables.keys) {
      final pk = AppDatabase.syncedTables[t]!;
      for (final row in upserts[t] ?? const []) {
        final r = Map<String, Object?>.from(row as Map);
        tables[t]!['${r[pk]}'] = r;
        final c = CloudChange(table: t, deleted: false, row: r);
        emitted.add(c);
        _changes.add(c);
      }
    }
  }

  @override
  Future<String> adminStatus() async {
    _online();
    return password == null ? 'unclaimed' : 'claimed';
  }

  @override
  Future<String> claim(String p) async {
    _online();
    if (password != null) throw CloudException('already_claimed');
    password = p;
    return _token();
  }

  @override
  Future<String> login(String p) async {
    _online();
    if (p != password) throw CloudException('wrong_password');
    return _token();
  }

  String _token() {
    final t = 'token-${tokens.length}';
    tokens.add(t);
    return t;
  }

  @override
  Future<void> setPassword(String token, String p) async {
    if (!tokens.contains(token)) throw CloudException('not_signed_in');
    password = p;
  }

  // ---- Personal accounts (same rules as the database functions) --------

  final users = <int, AppUser>{};
  final userPasswords = <int, String>{};
  final failed = <int, int>{};

  /// Signed-in tokens: token -> user id.
  final userTokens = <String, int>{};
  final logins = <String>[];

  AppUser addUser(
    String username,
    String password, {
    UserRole role = UserRole.team,
    String? name,
    bool mustChange = false,
    bool active = true,
    int? departmentId,
    ReportAccess reportAccess = ReportAccess.employee,
  }) {
    final id = users.length + 1;
    final user = AppUser(
      id: id,
      username: username,
      fullName: name ?? username,
      role: role,
      mustChange: mustChange,
      active: active,
      departmentId: departmentId,
      reportAccess: reportAccess,
    );
    users[id] = user;
    userPasswords[id] = password;
    return user;
  }

  String? _userRole(String token) {
    final id = userTokens[token];
    final user = id == null ? null : users[id];
    return user == null || !user.active ? null : user.role.serverName;
  }

  int _tokenUser(String token) {
    final id = userTokens[token];
    if (id == null || !(users[id]?.active ?? false)) {
      throw CloudException('not_signed_in');
    }
    return id;
  }

  UserSignIn _newSignIn(int id) {
    final t = 'user-$id-${userTokens.length}';
    userTokens[t] = id;
    return UserSignIn(t, users[id]!);
  }

  void _signOutEverywhere(int id, {String? except}) =>
      userTokens.removeWhere((t, u) => u == id && t != except);

  void _needAdmin(String token) {
    if (_userRole(token) != 'admin' && !tokens.contains(token)) {
      throw CloudException('not_signed_in');
    }
  }

  @override
  Future<String> usersStatus() async {
    _online();
    return users.isEmpty ? 'empty' : 'ready';
  }

  @override
  Future<UserSignIn> userSetup(String username, String name, String p) async {
    _online();
    if (users.isNotEmpty) throw CloudException('already_claimed');
    if (p.length < 8) throw CloudException('password_too_short');
    final u = addUser(username, p, role: UserRole.admin, name: name);
    return _newSignIn(u.id);
  }

  /// The next sign-in fails with this code (once).
  String? failNextLogin;

  @override
  Future<UserSignIn> userLogin(String username, String p, bool remember) async {
    _online();
    if (failNextLogin case final code?) {
      failNextLogin = null;
      throw CloudException(code);
    }
    logins.add(username);
    final user = users.values.where((u) => u.username == username).firstOrNull;
    if (user == null) throw CloudException('wrong_password');
    if ((failed[user.id] ?? 0) >= 5) throw CloudException('locked');
    if (userPasswords[user.id] != p) {
      failed[user.id] = (failed[user.id] ?? 0) + 1;
      throw CloudException(failed[user.id]! >= 5 ? 'locked' : 'wrong_password');
    }
    if (!user.active) throw CloudException('deactivated');
    failed[user.id] = 0;
    return _newSignIn(user.id);
  }

  @override
  Future<AppUser> userSession(String token) async {
    _online();
    return users[_tokenUser(token)]!;
  }

  @override
  Future<void> userLogout(String token) async {
    _online();
    userTokens.remove(token);
  }

  @override
  Future<void> userChangePassword(String token, String cur, String n) async {
    _online();
    final id = _tokenUser(token);
    if (n.length < 8) throw CloudException('password_too_short');
    if (userPasswords[id] != cur) throw CloudException('wrong_password');
    if (n == cur) throw CloudException('same_password');
    userPasswords[id] = n;
    final u = users[id]!;
    users[id] = AppUser(
      id: id,
      username: u.username,
      fullName: u.fullName,
      role: u.role,
      staffId: u.staffId,
      active: u.active,
    );
    _signOutEverywhere(id, except: token);
  }

  @override
  Future<List<AppUser>> adminListUsers(String token) async {
    _online();
    _needAdmin(token);
    return users.values.toList();
  }

  @override
  Future<AppUser> adminSaveUser(
    String token,
    Map<String, Object?> user, {
    String? password,
  }) async {
    _online();
    _needAdmin(token);
    final username = user['username'] as String;
    final id = user['id'] as int?;
    if (!AppUser.usernamePattern.hasMatch(username)) {
      throw CloudException('bad_username');
    }
    if (users.values.any((u) => u.username == username && u.id != id)) {
      throw CloudException('username_taken');
    }
    final role = UserRole.fromServerName(user['role'] as String);
    if (id == null) {
      if ((password ?? '').length < 8) {
        throw CloudException('password_too_short');
      }
      return addUser(
        username,
        password!,
        role: role,
        name: user['full_name'] as String,
        mustChange: true,
      );
    }
    final before = users[id]!;
    final active = user['active'] as bool? ?? true;
    if (userTokens[token] == id && (!active || role != UserRole.admin)) {
      throw CloudException('own_account');
    }
    users[id] = AppUser(
      id: id,
      username: username,
      fullName: user['full_name'] as String,
      role: role,
      staffId: user['staff_id'] as int?,
      active: active,
      mustChange: before.mustChange,
    );
    if (before.role != role || (before.active && !active)) {
      _signOutEverywhere(id);
    }
    return users[id]!;
  }

  @override
  Future<void> adminResetPassword(String token, int id, String p) async {
    _online();
    _needAdmin(token);
    if (p.length < 8) throw CloudException('password_too_short');
    userPasswords[id] = p;
    failed[id] = 0;
    final u = users[id]!;
    users[id] = AppUser(
      id: id,
      username: u.username,
      fullName: u.fullName,
      role: u.role,
      staffId: u.staffId,
      active: u.active,
      mustChange: true,
    );
    _signOutEverywhere(id);
  }

  // ---- Daily reports (same rules as the database functions) -------------

  DateTime reportsToday = DateTime(2026, 11, 9);
  final departments = <Map<String, Object?>>[
    {
      'id': 1,
      'name': 'Admissions & Applications',
      'outputs': [
        {'key': 'applications_submitted', 'label': 'Applications submitted'},
        {'key': 'coes_issued', 'label': 'COEs issued'},
      ],
      'active': true,
      'position': 1,
    },
    {
      'id': 2,
      'name': 'Visa Processing & Documentation',
      'outputs': [
        {'key': 'visa_lodgements', 'label': 'Visa lodgements'},
      ],
      'active': true,
      'position': 2,
    },
  ];
  final reports = <int, Map<String, Object?>>{};
  final reportChanges = <Map<String, Object?>>[];
  final calls = <String>[];
  final notifications = <Map<String, Object?>>[];
  int _nextReport = 100;
  int _tick = 0;

  /// A moment on [reportsToday]; each call a minute later, so orderings by
  /// time are stable.
  String _now() => DateTime.utc(
    reportsToday.year,
    reportsToday.month,
    reportsToday.day,
    8,
  ).add(Duration(minutes: _tick++)).toIso8601String();

  String _scope(int uid) {
    final u = users[uid]!;
    if (u.role == UserRole.admin ||
        u.role == UserRole.director ||
        u.reportAccess == ReportAccess.manager) {
      return 'all';
    }
    if (u.reportAccess == ReportAccess.head && u.departmentId != null) {
      return 'department';
    }
    return 'own';
  }

  bool _canSee(int uid, int owner, int? dept) => switch (_scope(uid)) {
    'all' => true,
    'department' => owner == uid || dept == users[uid]!.departmentId,
    _ => owner == uid,
  };

  bool _canSeeTask(int uid, Map<String, Object?> r) =>
      r['user_id'] == uid ||
      r['assigned_by'] == uid ||
      _canSee(uid, r['user_id'] as int, r['department_id'] as int?);

  bool _canReview(int uid, Map<String, Object?> r) {
    if (r['user_id'] == uid) return false;
    if (r['assigned_by'] == uid) return true;
    return switch (_scope(uid)) {
      'all' => true,
      'department' => r['department_id'] == users[uid]!.departmentId,
      _ => false,
    };
  }

  String _day(DateTime d) => dateKey(d);

  final comments = <Map<String, Object?>>[];

  /// Personal to-do items per person (as the server's todo_items).
  final todos = <int, Map<int, Map<String, Object?>>>{};

  void _notify(Object? user, String kind, int? rid, int? actor, String body) {
    if (user == null || user == actor) return;
    notifications.add({
      'id': notifications.length + 1,
      'user_id': user,
      'kind': kind,
      'report_id': rid,
      'actor_id': actor,
      'body': body,
      'created_at': _now(),
      'read': false,
    });
  }

  void _comment(int rid, int uid, String kind, String body) => comments.add({
    'id': comments.length + 1,
    'report_id': rid,
    'user_id': uid,
    'user_name': users[uid]!.fullName,
    'kind': kind,
    'body': body,
    'created_at': _now(),
  });

  Map<String, Object?> _reportJson(Map<String, Object?> r) => {
    ...r,
    'user_name': users[r['user_id']]!.fullName,
    'assigned_by_name': users[r['assigned_by']]?.fullName,
    'reviewed_by_name': users[r['reviewed_by']]?.fullName,
    'comment_count': comments
        .where((c) => c['report_id'] == r['id'] && c['kind'] == 'comment')
        .length,
    'last_review_note': comments
        .where(
          (c) =>
              c['report_id'] == r['id'] &&
              (c['kind'] == 'returned' || c['kind'] == 'approved'),
        )
        .lastOrNull?['body'],
    'department_name': departments
        .where((d) => d['id'] == r['department_id'])
        .firstOrNull?['name'],
  };

  bool _isOpen(Map<String, Object?> r) =>
      r['status'] != 'done' || r['review'] == 'returned';

  bool _between(Object? day, String from, String to) =>
      day is String && day.compareTo(from) >= 0 && day.compareTo(to) <= 0;

  @override
  Future<Object?> callFunction(String name, Map<String, Object?> p) async {
    _online();
    calls.add(name);
    final uid = _tokenUser(p['p_token'] as String);
    final me = users[uid]!;
    final today = reportsToday;
    final t = _day(today);
    List<Map<String, Object?>> visible() => [
      for (final r in reports.values)
        if (_canSeeTask(uid, r)) r,
    ];
    Future<Object?> again(String fn, [Map<String, Object?> more = const {}]) =>
        callFunction(fn, {'p_token': p['p_token'], ...more});
    List<Map<String, Object?>> todoList() {
      final mine = todos[uid] ?? {};
      return [
        for (final id in (mine.keys.toList()..sort()))
          if (mine[id]!['deleted'] != true) {...mine[id]!}..remove('deleted'),
      ];
    }

    switch (name) {
      case 'todo_list':
        return todoList();
      case 'todo_save':
        final mine = todos.putIfAbsent(uid, () => {});
        for (final i in (p['p_items'] as List).cast<Map>()) {
          final item = i.cast<String, Object?>();
          final id = (item['id'] as num).toInt();
          final old = mine[id];
          final at = item['changed_at'] as String;
          if (old != null && at.compareTo(old['changed_at'] as String) < 0) {
            continue;
          }
          mine[id] = {...item, 'sent_id': item['sent_id'] ?? old?['sent_id']};
        }
        return todoList();
      case 'report_start':
        // As the server: everything the page opens with, in one call.
        return {
          'meta': await again('reports_meta'),
          'badge': await again('report_badge'),
          'tasks': await again('report_list', {
            'p_filter': {'user_id': uid, 'open_only': true},
          }),
          'submissions': await again('report_list', {
            'p_filter': {
              'user_id': uid,
              'reviews': ['submitted', 'approved'],
              'from': _day(today.subtract(const Duration(days: 60))),
            },
          }),
        };
      case 'reports_meta':
        final scope = _scope(uid);
        return {
          'today': t,
          'now': '${t}T09:00:00',
          'me': {...me.toJson(), 'scope': scope, 'can_assign': scope != 'own'},
          'departments': departments,
          'people': [
            for (final u in users.values)
              if (scope != 'own' || u.id == uid)
                {
                  'id': u.id,
                  'full_name': u.fullName,
                  'department_id': u.departmentId,
                  'active': u.active,
                },
          ],
        };
      case 'report_badge':
        return {
          'unread': notifications
              .where((n) => n['user_id'] == uid && n['read'] != true)
              .length,
          'to_review': reports.values
              .where((r) => r['review'] == 'submitted' && _canReview(uid, r))
              .length,
          'submitted_today': reports.values.any(
            (r) => r['user_id'] == uid && r['report_date'] == t,
          ),
          'needs_report': me.departmentId != null,
        };
      case 'report_notifications':
        return [
          for (final n in notifications.reversed)
            if (n['user_id'] == uid)
              {
                ...n,
                'actor_name': users[n['actor_id']]?.fullName,
                'task': reports[n['report_id']]?['description'],
                'urgency': reports[n['report_id']]?['urgency'],
                'report':
                    reports[n['report_id']] == null ||
                        !_canSeeTask(uid, reports[n['report_id']]!)
                    ? null
                    : _reportJson(reports[n['report_id']]!),
              },
        ];
      case 'report_notifications_read':
        final ids = (p['p_ids'] as List?)?.cast<int>();
        for (final n in notifications) {
          if (n['user_id'] == uid && (ids == null || ids.contains(n['id']))) {
            n['read'] = true;
          }
        }
        return null;
      case 'report_list':
        final f = (p['p_filter'] as Map).cast<String, Object?>();
        final search = (f['search'] as String?)?.trim().toLowerCase();
        final searchId = search == null
            ? null
            : int.tryParse(search.replaceFirst('#', ''));
        final rows = visible().where((r) {
          final d = r['report_date'] as String?;
          bool on(String key, bool Function(String) test) =>
              f[key] == null || (d != null && test(f[key] as String));
          return on('from', (v) => d!.compareTo(v) >= 0) &&
              on('to', (v) => d!.compareTo(v) <= 0) &&
              (f['user_id'] == null || r['user_id'] == f['user_id']) &&
              (f['department_id'] == null ||
                  r['department_id'] == f['department_id']) &&
              (f['statuses'] == null ||
                  (f['statuses'] as List).contains(r['status'])) &&
              (f['reviews'] == null ||
                  (f['reviews'] as List).contains(r['review'])) &&
              (f['urgency'] == null || r['urgency'] == f['urgency']) &&
              (f['open_only'] != true || _isOpen(r)) &&
              (f['overdue_only'] != true ||
                  (r['status'] != 'done' &&
                      r['due_date'] != null &&
                      (r['due_date'] as String).compareTo(t) < 0)) &&
              (f['assigned_by_me'] != true || r['assigned_by'] == uid) &&
              (f['to_review'] != true ||
                  (r['review'] == 'submitted' && _canReview(uid, r))) &&
              (f['reviewed_by_me'] != true || r['reviewed_by'] == uid) &&
              (search == null ||
                  r['id'] == searchId ||
                  [
                    r['description'],
                    r['details'],
                    r['reference'],
                    r['blocker'],
                    users[r['user_id']]?.fullName,
                    users[r['assigned_by']]?.fullName,
                    departments.firstWhere(
                      (x) => x['id'] == r['department_id'],
                    )['name'],
                  ].join(' ').toLowerCase().contains(search));
        }).toList();
        String when(Map<String, Object?> r) =>
            (r['submitted_at'] ?? r['updated_at']) as String;
        rows.sort((a, b) {
          final c = when(b).compareTo(when(a));
          return c != 0 ? c : (b['id'] as int).compareTo(a['id'] as int);
        });
        final limit = f['limit'] as int?;
        return [
          for (final r in limit == null ? rows : rows.take(limit))
            _reportJson(r),
        ];
      case 'report_summary':
        final from = p['p_from'] as String;
        final to = p['p_to'] as String;
        final deptFilter = p['p_department'] as int?;
        final userFilter = p['p_user'] as int?;
        bool scoped(Map<String, Object?> r) =>
            (deptFilter == null || r['department_id'] == deptFilter) &&
            (userFilter == null || r['user_id'] == userFilter);
        final inView = visible().where(scoped).toList();
        final inRange = inView
            .where((r) => _between(r['report_date'], from, to))
            .toList();
        final status = <String, int>{};
        for (final r in inView) {
          if (r['status'] != 'done' || _between(r['report_date'], from, to)) {
            status['${r['status']}'] = (status['${r['status']}'] ?? 0) + 1;
          }
        }
        final review = <String, int>{};
        for (final r in inRange) {
          review['${r['review']}'] = (review['${r['review']}'] ?? 0) + 1;
        }
        final scope = _scope(uid);
        return {
          'from': from,
          'to': to,
          'today': t,
          'working_days': 1,
          'status': status,
          'review': review,
          'departments': [
            for (final d in departments)
              if ((deptFilter == null || d['id'] == deptFilter) &&
                  (scope == 'all' || d['id'] == me.departmentId))
                () {
                  final all = inView.where(
                    (r) => r['department_id'] == d['id'],
                  );
                  final rs = inRange.where(
                    (r) => r['department_id'] == d['id'],
                  );
                  final outputs = <String, int>{};
                  for (final r in rs) {
                    (r['outputs'] as Map).forEach(
                      (k, v) =>
                          outputs['$k'] = (outputs['$k'] ?? 0) + (v as int),
                    );
                  }
                  return {
                    'id': d['id'],
                    'name': d['name'],
                    'activities': rs.length,
                    'completed': rs
                        .where((r) => r['review'] == 'approved')
                        .length,
                    'open': all.where((r) => r['status'] != 'done').length,
                    'blocked': all
                        .where((r) => r['status'] == 'blocked')
                        .length,
                    'awaiting': all
                        .where((r) => r['review'] == 'submitted')
                        .length,
                    'people': rs.map((r) => r['user_id']).toSet().length,
                    'outputs': outputs,
                  };
                }(),
          ],
          'compliance': [
            for (final u in users.values)
              if (u.active &&
                  u.departmentId != null &&
                  (userFilter == null || u.id == userFilter) &&
                  (deptFilter == null || u.departmentId == deptFilter) &&
                  (scope == 'all' ||
                      u.id == uid ||
                      (scope == 'department' &&
                          u.departmentId == me.departmentId)))
                {
                  'id': u.id,
                  'full_name': u.fullName,
                  'department_id': u.departmentId,
                  'department_name': departments.firstWhere(
                    (d) => d['id'] == u.departmentId,
                  )['name'],
                  'days_submitted': reports.values
                      .where(
                        (r) =>
                            r['user_id'] == u.id &&
                            _between(r['report_date'], from, to),
                      )
                      .map((r) => r['report_date'])
                      .toSet()
                      .length,
                  'entries': reports.values
                      .where(
                        (r) =>
                            r['user_id'] == u.id &&
                            _between(r['report_date'], from, to),
                      )
                      .length,
                  'open': reports.values
                      .where(
                        (r) => r['user_id'] == u.id && r['status'] != 'done',
                      )
                      .length,
                  'submitted_today': reports.values.any(
                    (r) => r['user_id'] == u.id && r['report_date'] == t,
                  ),
                },
          ],
          'overdue': [
            for (final r in inView)
              if (r['status'] != 'done' &&
                  r['due_date'] != null &&
                  (r['due_date'] as String).compareTo(t) < 0)
                _reportJson(r),
          ],
          'attention': [
            for (final r in inView)
              if (r['status'] == 'blocked' ||
                  r['review'] == 'returned' ||
                  (r['urgency'] == 'urgent' && r['status'] != 'done'))
                _reportJson(r),
          ],
        };
      case 'report_save':
        final r = (p['p_report'] as Map).cast<String, Object?>();
        final id = r['id'] as int?;
        final before = id == null ? null : reports[id];
        if (id != null && before == null) {
          throw CloudException('unknown_report');
        }
        var status = r['status'] as String? ?? 'to_do';
        if (!['to_do', 'in_progress', 'blocked', 'done'].contains(status)) {
          throw CloudException('bad_status');
        }
        final urgency = r['urgency'] as String? ?? 'normal';
        if (!['low', 'normal', 'high', 'urgent'].contains(urgency)) {
          throw CloudException('bad_urgency');
        }
        if ('${r['description'] ?? ''}'.trim().isEmpty) {
          throw CloudException('description_required');
        }
        var submit = r['submit'] == true;
        if (submit) status = 'done';
        final forId = r['user_id'] as int?;
        int owner;
        int? assigned;
        int? dept;
        if (before != null) {
          if (before['user_id'] != uid &&
              before['assigned_by'] != uid &&
              me.role != UserRole.admin) {
            throw CloudException('not_allowed');
          }
          if (['submitted', 'approved'].contains(before['review']) &&
              before['user_id'] == uid &&
              before['assigned_by'] != uid &&
              me.role != UserRole.admin) {
            throw CloudException('already_submitted');
          }
          owner = before['user_id'] as int;
          assigned = before['assigned_by'] as int?;
          dept = before['department_id'] as int?;
          if (forId != null &&
              forId != owner &&
              (assigned == uid || me.role == UserRole.admin)) {
            final o = users[forId];
            if (o == null || !o.active) throw CloudException('unknown_user');
            owner = o.id;
            dept = o.departmentId;
          }
        } else if (forId != null && forId != uid) {
          if (_scope(uid) == 'own') throw CloudException('not_allowed');
          final o = users[forId];
          if (o == null || !o.active) throw CloudException('unknown_user');
          owner = o.id;
          dept = o.departmentId;
          assigned = uid;
          submit = false;
          if (status == 'done') status = 'to_do';
        } else {
          owner = uid;
          dept = me.departmentId;
        }
        if (status == 'blocked' && '${r['blocker'] ?? ''}'.trim().isEmpty) {
          throw CloudException('blocker_required');
        }
        var reviewState = (before?['review'] as String?) ?? 'none';
        var reportDate = before?['report_date'];
        var submittedAt = before?['submitted_at'];
        final now = _now();
        if (submit) {
          if (owner != uid) throw CloudException('not_allowed');
          reviewState = 'submitted';
          // Saved offline and sent later: the day it was done (a week
          // back at most).
          final doneOn = r['done_on'] as String?;
          reportDate =
              doneOn != null &&
                  doneOn.compareTo(t) <= 0 &&
                  doneOn.compareTo(
                        _day(today.subtract(const Duration(days: 7))),
                      ) >=
                      0
              ? doneOn
              : t;
          submittedAt = now;
        } else if (status != 'done' && reviewState == 'approved') {
          reviewState = 'none';
        }
        final keys = [
          if (dept != null)
            for (final o
                in departments.firstWhere((d) => d['id'] == dept)['outputs']!
                    as List)
              (o as Map)['key'],
          // An edit keeps keys the report already had.
          ...((before?['outputs'] as Map?) ?? const {}).keys,
        ];
        final saved = <String, Object?>{
          ...?before,
          'id': id ?? _nextReport++,
          'user_id': owner,
          'assigned_by': assigned,
          'department_id': dept,
          'report_date': reportDate,
          'description': '${r['description']}'.trim(),
          'details': '${r['details'] ?? ''}'.trim(),
          'reference': '${r['reference'] ?? ''}'.trim(),
          'outputs': {
            for (final e in ((r['outputs'] as Map?) ?? {}).entries)
              if (keys.contains(e.key) && (e.value as int) > 0) e.key: e.value,
          },
          'status': status,
          'blocker': status == 'blocked' ? '${r['blocker']}'.trim() : '',
          'urgency': urgency,
          'due_date': r['due_date'],
          'review': reviewState,
          'submitted_at': submittedAt,
          'created_at': before?['created_at'] ?? now,
          'updated_at': now,
        };
        final sid = saved['id'] as int;
        reports[sid] = saved;
        reportChanges.add({
          'report_id': sid,
          'action': before == null
              ? 'created'
              : submit
              ? 'submitted'
              : 'edited',
          'changed_by': me.fullName,
          'changed_at': now,
        });
        final title = saved['description'] as String;
        if (before == null) {
          if (assigned != null) _notify(owner, 'assigned', sid, uid, title);
        } else if (owner != before['user_id']) {
          _notify(owner, 'assigned', sid, uid, title);
          _notify(before['user_id'], 'reassigned', sid, uid, title);
        }
        if (status == 'blocked' && before?['status'] != 'blocked') {
          _notify(assigned, 'blocked', sid, uid, saved['blocker'] as String);
        }
        if (submit) {
          _comment(sid, uid, 'submitted', '${r['note'] ?? ''}'.trim());
          _notify(assigned, 'submitted', sid, uid, title);
        }
        return _reportJson(saved);
      case 'report_withdraw':
        final id = p['p_report'] as int;
        final r = reports[id];
        if (r == null) throw CloudException('unknown_report');
        if (r['user_id'] != uid) throw CloudException('not_allowed');
        if (r['review'] != 'submitted') throw CloudException('not_submitted');
        final lastReview = comments
            .where(
              (c) =>
                  c['report_id'] == id &&
                  ['approved', 'returned'].contains(c['kind']),
            )
            .lastOrNull;
        final now = _now();
        r
          ..['review'] = lastReview?['kind'] == 'returned' ? 'returned' : 'none'
          ..['status'] = 'in_progress'
          ..['report_date'] = null
          ..['submitted_at'] = null
          ..['updated_at'] = now;
        final sub = comments
            .where((c) => c['report_id'] == id && c['kind'] == 'submitted')
            .lastOrNull;
        if (sub != null) comments.remove(sub);
        notifications.removeWhere(
          (n) =>
              n['report_id'] == id &&
              n['kind'] == 'submitted' &&
              n['read'] != true,
        );
        reportChanges.add({
          'report_id': id,
          'action': 'withdrawn',
          'changed_by': me.fullName,
          'changed_at': now,
        });
        return _reportJson(r);
      case 'report_review':
        final id = p['p_report'] as int;
        final r = reports[id];
        if (r == null) throw CloudException('unknown_report');
        if (!_canReview(uid, r)) throw CloudException('not_allowed');
        final decision = p['p_decision'] as String;
        if (!['approved', 'returned'].contains(decision)) {
          throw CloudException('bad_decision');
        }
        if (r['review'] != 'submitted' &&
            !(r['reviewed_by'] == uid &&
                ['approved', 'returned'].contains(r['review']))) {
          throw CloudException('not_submitted');
        }
        final note = '${p['p_comment'] ?? ''}'.trim();
        if (decision == 'returned' && note.isEmpty) {
          throw CloudException('comment_required');
        }
        final now = _now();
        r
          ..['review'] = decision
          ..['status'] = decision == 'returned' ? 'in_progress' : 'done'
          ..['report_date'] = decision == 'returned'
              ? null
              : (r['report_date'] ?? '2026-11-09')
          ..['reviewed_by'] = uid
          ..['reviewed_at'] = now
          ..['updated_at'] = now;
        _comment(id, uid, decision, note);
        reportChanges.add({
          'report_id': id,
          'action': decision,
          'changed_by': me.fullName,
          'changed_at': now,
        });
        _notify(
          r['user_id'],
          decision,
          id,
          uid,
          note.isEmpty ? r['description'] as String : note,
        );
        return _reportJson(r);
      case 'report_delete':
        final id = p['p_report'] as int;
        final r = reports[id];
        if (r == null) return null;
        if (r['user_id'] != uid &&
            r['assigned_by'] != uid &&
            me.role != UserRole.admin) {
          throw CloudException('not_allowed');
        }
        reports.remove(id);
        reportChanges.add({
          'report_id': id,
          'action': 'deleted',
          'changed_by': me.fullName,
          'changed_at': _now(),
        });
        return null;
      case 'report_history':
        return [
          for (final c in reportChanges)
            if (c['report_id'] == p['p_report']) c,
        ];
      case 'report_comments':
      case 'report_comment_add':
        final rid = p['p_report'] as int;
        final r = reports[rid];
        final canSee = r != null && _canSeeTask(uid, r);
        if (name == 'report_comment_add') {
          if (!canSee) throw CloudException('not_allowed');
          final body = (p['p_body'] as String).trim();
          _comment(rid, uid, 'comment', body);
          for (final who in {
            r['user_id'],
            r['assigned_by'],
            r['reviewed_by'],
          }) {
            _notify(who, 'comment', rid, uid, body);
          }
        }
        if (!canSee) return [];
        return [
          for (final c in comments)
            if (c['report_id'] == rid) c,
        ];
      case 'report_comment_delete':
        comments.removeWhere(
          (c) =>
              c['id'] == p['p_comment'] &&
              (c['user_id'] == uid || me.role == UserRole.admin),
        );
        return null;
      case 'admin_delete_user':
        _needAdmin(p['p_token'] as String);
        final id = p['p_user_id'] as int;
        if (id == uid) throw CloudException('own_account');
        if (!users.containsKey(id)) throw CloudException('unknown_user');
        final n = reports.values.where((r) => r['user_id'] == id).length;
        if (n > 0 && p['p_with_reports'] != true) {
          throw CloudException('has_reports', 'has_reports:$n');
        }
        reports.removeWhere((_, r) => r['user_id'] == id);
        users.remove(id);
        userTokens.removeWhere((_, u) => u == id);
        return null;
      case 'admin_save_department':
        _needAdmin(p['p_token'] as String);
        final d = (p['p_department'] as Map).cast<String, Object?>();
        if (departments.any(
          (x) =>
              '${x['name']}'.toLowerCase() == '${d['name']}'.toLowerCase() &&
              x['id'] != d['id'],
        )) {
          throw CloudException('name_taken');
        }
        final saved = {
          'id': d['id'] ?? departments.length + 1,
          'name': d['name'],
          'outputs': d['outputs'],
          'active': d['active'] ?? true,
          'position': departments.length + 1,
        };
        departments
          ..removeWhere((x) => x['id'] == saved['id'])
          ..add(saved);
        return saved;
    }
    throw CloudException('needs_update');
  }

  @override
  Stream<CloudChange> changes() => _changes.stream;

  @override
  Stream<bool> connection() => _connection.stream;

  @override
  void dispose() {}
}

void main() {
  late AppDatabase admin;
  late AppDatabase boss;
  late FakeCloud cloud;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AuthRepository.iterations = 10;
    admin = openInMemoryDatabase();
    boss = openInMemoryDatabase();
    cloud = FakeCloud();
  });
  tearDown(() {
    admin.close();
    boss.close();
  });

  int staffId(AppDatabase db, String name) =>
      db.raw.select('SELECT id FROM staff WHERE name = ?;', [name]).first['id']!
          as int;

  test('local edits are queued for upload automatically', () {
    final engine = SyncEngine(admin, cloud);
    admin.raw.execute('DELETE FROM sync_outbox;');
    final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    expect(engine.pending, greaterThan(0));
    final before = engine.pending;
    ClientCountRepository(admin).saveCount(
      dayId: WeekRepository(admin).getDays(week.id).first.id,
      staffId: staffId(admin, 'Joy'),
      newClients: 2,
      existingClients: 1,
    );
    expect(engine.pending, greaterThan(before));
  });

  test(
    'the first admin device seeds the cloud; the boss downloads it',
    () async {
      final token = await cloud.claim('pass1234');
      final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
      final monday = WeekRepository(admin).getDays(week.id).first;
      ClientCountRepository(admin).saveCount(
        dayId: monday.id,
        staffId: staffId(admin, 'Joy'),
        newClients: 4,
        existingClients: 3,
      );
      final a = SyncEngine(admin, cloud);
      await a.pull(token: token, readToken: token);
      expect(a.connected, isTrue);
      expect(a.pending, 0);
      expect(cloud.tables['staff'], hasLength(14));
      expect(cloud.tables['weeks'], hasLength(1));

      // The boss's fresh device: its starter data is replaced by the cloud's.
      StaffRepository(boss).rename(staffId(boss, 'Joy'), 'Not Joy');
      final b = SyncEngine(boss, cloud);
      expect(
        await b.pull(readToken: await cloud.profileLogin('director', '')),
        isTrue,
      );
      expect(b.pending, 0, reason: 'nothing from the boss device goes up');
      final joy = staffId(boss, 'Joy');
      final day = WeekRepository(boss).getDays(week.id).first;
      expect(
        ClientCountRepository(boss).countValues(day.id, joy).newClients,
        4,
      );
    },
  );

  test('live: admin edits reach the boss, deletes too, without echo', () async {
    final token = await cloud.claim('pass1234');
    final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    final a = SyncEngine(admin, cloud);
    await a.pull(token: token, readToken: token);
    final b = SyncEngine(boss, cloud);
    await b.pull(readToken: await cloud.profileLogin('director', ''));
    final sub = cloud.changes().listen(b.apply);

    final day = WeekRepository(admin).getDays(week.id)[2];
    ClientCountRepository(admin).saveCount(
      dayId: day.id,
      staffId: staffId(admin, 'Ian'),
      newClients: 6,
      existingClients: 0,
    );
    await a.flush(token);
    await Future<void>.delayed(Duration.zero);
    expect(
      ClientCountRepository(boss)
          .countValues(day.id, staffId(boss, 'Ian'))
          .newClients,
      6,
    );
    expect(b.pending, 0, reason: 'applying cloud changes queues nothing');

    WeekRepository(admin).deleteWeek(week.id);
    await a.flush(token);
    await Future<void>.delayed(Duration.zero);
    expect(WeekRepository(boss).getAllWeeks(), isEmpty);
    await sub.cancel();
  });

  test('unsent local edits are never overwritten by cloud data', () async {
    final token = await cloud.claim('pass1234');
    final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    final a = SyncEngine(admin, cloud);
    await a.pull(token: token, readToken: token);
    final day = WeekRepository(admin).getDays(week.id).first;
    final joy = staffId(admin, 'Joy');
    final counts = ClientCountRepository(admin);
    counts.saveCount(
      dayId: day.id,
      staffId: joy,
      newClients: 12,
      existingClients: 0,
    );
    // A late cloud echo of an older value for the same row.
    final row = admin.raw.select(
      'SELECT * FROM client_counts WHERE day_id = ? AND staff_id = ?;',
      [day.id, joy],
    ).first;
    a.apply(
      CloudChange(
        table: 'client_counts',
        deleted: false,
        row: {...row, 'new_clients': 1},
      ),
    );
    expect(counts.countValues(day.id, joy).newClients, 12);
    // Offline: the change waits, then goes up.
    cloud.offline = true;
    await expectLater(a.flush(token), throwsException);
    expect(a.pending, greaterThan(0));
    cloud.offline = false;
    await a.flush(token);
    expect(a.pending, 0);
    final up = cloud.tables['client_counts']!.values.firstWhere(
      (r) => r['day_id'] == day.id && r['staff_id'] == joy,
    );
    expect(up['new_clients'], 12);
  });

  test('a restored backup is sent online as a whole', () async {
    final token = await cloud.claim('pass1234');
    final a = SyncEngine(admin, cloud);
    WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    await a.pull(token: token, readToken: token);
    final other = openInMemoryDatabase();
    addTearDown(other.close);
    WeekRepository(other).createWeekFor(DateTime(2026, 9, 7));
    WeekRepository(other).createWeekFor(DateTime(2026, 9, 14));
    admin.restoreFromJson(other.exportToJson());
    await a.flush(token);
    expect(cloud.tables['weeks'], hasLength(2));
    expect(
      cloud.tables['weeks']!.values.map((w) => w['start_date']),
      containsAll(['2026-09-07', '2026-09-14']),
    );
  });

  // -------------------------------------------------------- sign-in flow ---

  Future<ProviderContainer> pumpApp(WidgetTester tester, AppDatabase db) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cloudApiFactoryProvider.overrideWithValue(() => cloud),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('first admin sign-in claims the online password', (tester) async {
    final container = await pumpApp(tester, admin);
    expect(container.read(cloudSyncProvider).phase, SyncPhase.live);
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    expect(find.text('Create the admin password'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'secret-1');
    await tester.enterText(fields.at(1), 'secret-1');
    await tester.tap(find.text('Create password and sign in'));
    await tester.pumpAndSettle();
    expect(cloud.password, 'secret-1');
    expect(container.read(cloudSyncProvider).adminLinked, isTrue);
    // The staff list went up.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(cloud.tables['staff'], isNotEmpty);
    container.dispose(); // stops sync's timers, as closing the app would
  });

  testWidgets('a forgotten password is reset with the recovery code', (
    tester,
  ) async {
    cloud.password = 'old-secret';
    cloud.tokens.add('t1');
    cloud.recoveryCode = 'ABCD-EFGH-JKLM-NPQR';
    final container = await pumpApp(tester, boss);
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('forgot-password')));
    await tester.pumpAndSettle();

    // A wrong code is refused.
    await tester.enterText(
      find.byKey(const ValueKey('recovery-code-field')),
      'WRONG-CODE',
    );
    await tester.enterText(
      find.byKey(const ValueKey('recovery-new-password')),
      'new-secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey('recovery-new-password2')),
      'new-secret',
    );
    await tester.tap(find.text('Set password'));
    await tester.pumpAndSettle();
    expect(find.textContaining('isn’t right'), findsOneWidget);
    expect(cloud.password, 'old-secret');

    // The right code (dashes or not) sets it, everywhere.
    await tester.enterText(
      find.byKey(const ValueKey('recovery-code-field')),
      'abcd efgh jklm npqr',
    );
    await tester.tap(find.text('Set password'));
    await tester.pumpAndSettle();
    expect(cloud.password, 'new-secret');
    expect(cloud.recoveryCode, isNull); // one use only
    expect(cloud.tokens, isNot(contains('t1'))); // other devices signed out
    expect(container.read(adminSessionProvider), UserRole.admin);
    expect(AuthRepository(boss).verifyAdmin('new-secret'), isTrue);
    container.dispose();
  });

  testWidgets('a new device signs in with the online password', (tester) async {
    cloud.password = 'secret-1';
    final container = await pumpApp(tester, boss);
    expect(container.read(cloudSyncProvider).claimed, isTrue);
    await tester.tap(find.text('Admin'));
    await tester.pumpAndSettle();
    // No "create a password" on this device: it signs in instead.
    expect(find.text('Create the admin password'), findsNothing);
    expect(find.text('Admin sign in'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wrong');
    await tester.tap(find.text('Sign in to workspace'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong password. Try again.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'secret-1');
    await tester.tap(find.text('Sign in to workspace'));
    await tester.pumpAndSettle();
    expect(container.read(adminSessionProvider), UserRole.admin);
    // Remembered locally, so it also works offline next time.
    expect(AuthRepository(boss).verifyAdmin('secret-1'), isTrue);
    container.dispose();
  });

  testWidgets('a profile password set on another device is asked for here', (
    tester,
  ) async {
    cloud.profilePasswords['director'] = 'd-pass';
    final container = await pumpApp(tester, boss);
    expect(AuthRepository(boss).isLocked(UserRole.director), isTrue);
    await tester.tap(find.byKey(const ValueKey('profile-director')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('profile-password')),
      'd-pass',
    );
    await tester.tap(find.byKey(const ValueKey('profile-open')));
    await tester.pumpAndSettle();
    expect(container.read(adminSessionProvider), UserRole.director);
    // Remembered here, so it opens offline next time.
    expect(
      AuthRepository(boss).verifyProfile(UserRole.director, 'd-pass'),
      true,
    );
    container.dispose();
  });

  testWidgets('the admin team’s device can send their changes', (tester) async {
    final container = await pumpApp(tester, boss);
    await tester.tap(find.byKey(const ValueKey('profile-adminTeam')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(container.read(adminSessionProvider), UserRole.adminTeam);
    expect(cloud.teamTokens, hasLength(1));
    expect(container.read(cloudSyncProvider).adminLinked, isTrue);
    container.dispose();
  });

  testWidgets('kept signed in, until the admin changes the password', (
    tester,
  ) async {
    cloud.profilePasswords['director'] = 'd-pass';
    final auth = AuthRepository(boss);
    auth.setProfilePassword(UserRole.director, 'd-pass');
    auth.rememberProfile(UserRole.director, version: 'v0');
    SharedPreferences.setMockInitialValues({
      'cloud_director_token': await cloud.profileLogin('director', 'd-pass'),
    });
    var container = await pumpApp(tester, boss);
    expect(container.read(adminSessionProvider), UserRole.director);
    container.dispose();

    // Changed on the admin's device: this one asks again.
    cloud.profileVersionNumbers['director'] = 1;
    await tester.pumpWidget(const SizedBox());
    container = await pumpApp(tester, boss);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(container.read(adminSessionProvider), isNull);
    expect(find.text('Who’s using the app?'), findsOneWidget);
    expect(find.textContaining('password was changed'), findsOneWidget);
    container.dispose();
  });

  test(
    'reading needs a sign-in; revenue only for admin and director',
    () async {
      final token = await cloud.claim('pass1234');
      RevenueRepository(admin).add(DateTime(2026, 10, 12), 300000);
      final a = SyncEngine(admin, cloud);
      await a.pull(token: token, readToken: token);
      expect(cloud.tables['revenue_entries'], hasLength(1));

      // A Team device keeps no revenue, even one it had before.
      RevenueRepository(boss).add(DateTime(2026, 10, 1), 100);
      final b = SyncEngine(boss, cloud);
      await b.pull(readToken: await cloud.profileLogin('team', ''));
      expect(
        RevenueRepository(boss).entriesFor(DateTime(2026, 10, 1)),
        isEmpty,
      );
      expect(
        RevenueRepository(boss).entriesFor(DateTime(2026, 10, 12)),
        isEmpty,
      );
      expect(cloud.tables['staff'], isNotEmpty);

      // The director's does.
      await b.pull(readToken: await cloud.profileLogin('director', ''));
      expect(
        RevenueRepository(boss).entriesFor(DateTime(2026, 10, 12)),
        hasLength(1),
      );

      // No sign-in, no data.
      await expectLater(
        b.pull(readToken: 'made-up'),
        throwsA(isA<CloudException>()),
      );
    },
  );

  test('a number typed while downloading is not overwritten', () async {
    final token = await cloud.claim('pass1234');
    final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    final a = SyncEngine(admin, cloud);
    await a.pull(token: token, readToken: token);
    final day = WeekRepository(admin).getDays(week.id).first;
    final joy = staffId(admin, 'Joy');
    cloud.duringRead = () => ClientCountRepository(
      admin,
    ).saveCount(dayId: day.id, staffId: joy, newClients: 9, existingClients: 0);
    expect(await a.pull(token: token, readToken: token), isFalse);
    cloud.duringRead = null;
    expect(ClientCountRepository(admin).countValues(day.id, joy).newClients, 9);
    expect(a.pending, greaterThan(0)); // still to go up
    await a.pull(token: token, readToken: token);
    expect(a.pending, 0);
    expect(ClientCountRepository(admin).countValues(day.id, joy).newClients, 9);
  });

  testWidgets('changes from another device arrive while the app is open', (
    tester,
  ) async {
    final token = await cloud.claim('pass1234');
    final week = WeekRepository(admin).createWeekFor(DateTime(2026, 10, 12));
    await SyncEngine(admin, cloud).pull(token: token, readToken: token);
    final container = await pumpApp(tester, boss);
    await tester.tap(find.byKey(const ValueKey('profile-director')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(cloud.reads.last, 'director');
    final before = cloud.reads.length;

    // The admin enters a number on their device.
    final day = WeekRepository(admin).getDays(week.id)[1];
    ClientCountRepository(admin).saveCount(
      dayId: day.id,
      staffId: staffId(admin, 'Ian'),
      newClients: 5,
      existingClients: 1,
    );
    await tester.runAsync(() => SyncEngine(admin, cloud).flush(token));
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(cloud.reads.length, greaterThan(before));
    expect(
      ClientCountRepository(boss)
          .countValues(day.id, staffId(boss, 'Ian'))
          .newClients,
      5,
    );
    container.dispose();
  });

  testWidgets('kept signed in from an older version: asked once more', (
    tester,
  ) async {
    cloud.profilePasswords['director'] = 'd-pass';
    final auth = AuthRepository(boss);
    auth.setProfilePassword(UserRole.director, 'd-pass');
    auth.rememberProfile(UserRole.director, version: 'v0');
    final container = await pumpApp(tester, boss); // no saved sign-in
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(container.read(adminSessionProvider), isNull);
    expect(
      find.textContaining('sign in to Director once more'),
      findsOneWidget,
    );
    container.dispose();
  });

  // ------------------------------------------------- personal accounts ---

  Future<ProviderContainer> pumpAccounts(
    WidgetTester tester,
    AppDatabase db, {
    Size size = const Size(1600, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cloudApiFactoryProvider.overrideWithValue(() => cloud),
        accountsEnabledProvider.overrideWithValue(true),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ClientTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  Future<void> signIn(
    WidgetTester tester,
    String username,
    String password, {
    bool remember = false,
  }) async {
    await tester.enterText(
      find.byKey(const ValueKey('login-username')),
      username,
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('login-password')),
        matching: find.byType(TextField),
      ),
      password,
    );
    if (remember) {
      await tester.tap(find.byKey(const ValueKey('login-remember')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pumpAndSettle();
    await settle(tester);
  }

  Finder field(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(TextField),
  );

  testWidgets('accounts: sign in with username and password', (tester) async {
    cloud.addUser('mary.wanjiku', 'mary-pass-1', name: 'Mary Wanjiku');
    final container = await pumpAccounts(tester, boss);
    expect(find.text('Sign in'), findsWidgets);
    expect(find.text('Remember me'), findsOneWidget);

    await signIn(tester, 'mary.wanjiku', 'wrong-pass');
    expect(find.text('Username or password is incorrect.'), findsOneWidget);
    expect(container.read(currentUserProvider), isNull);

    // Typed in capitals: usernames are lower case.
    await signIn(tester, 'Mary.Wanjiku', 'mary-pass-1');
    final user = container.read(currentUserProvider);
    expect(user?.fullName, 'Mary Wanjiku');
    expect(container.read(sessionProvider), UserRole.team);
    expect(cloud.reads.last, 'team');
    // Not remembered: nothing kept to open straight in next time.
    expect(AuthRepository(boss).rememberedUser, isNull);
    expect(find.textContaining('Mary Wanjiku'), findsWidgets);
    container.dispose();
  });

  testWidgets('accounts: Remember me opens straight in next time', (
    tester,
  ) async {
    cloud.addUser('ian', 'ian-pass-12', role: UserRole.adminTeam);
    var container = await pumpAccounts(tester, boss);
    await signIn(tester, 'ian', 'ian-pass-12', remember: true);
    expect(container.read(sessionProvider), UserRole.adminTeam);
    expect(AuthRepository(boss).rememberedUser?.user.username, 'ian');
    container.dispose();

    // The app opened again: no sign-in screen, and the session checked.
    await tester.pumpWidget(const SizedBox());
    final loginsBefore = cloud.logins.length;
    container = await pumpAccounts(tester, boss);
    await settle(tester);
    expect(container.read(currentUserProvider)?.username, 'ian');
    expect(cloud.logins.length, loginsBefore, reason: 'no password asked');
    expect(container.read(cloudSyncProvider).adminLinked, isTrue);

    // Signing out forgets it, online too.
    final tokensBefore = cloud.userTokens.length;
    await tester.tap(find.byKey(const ValueKey('sign-out')));
    await settle(tester);
    expect(container.read(currentUserProvider), isNull);
    expect(AuthRepository(boss).rememberedUser, isNull);
    expect(cloud.userTokens.length, tokensBefore - 1);
    expect(find.byKey(const ValueKey('login-username')), findsOneWidget);
    container.dispose();
  });

  testWidgets('accounts: a temporary password must be replaced first', (
    tester,
  ) async {
    cloud.addUser('joy', 'temp-1234', mustChange: true, name: 'Joy');
    final container = await pumpAccounts(tester, boss);
    await signIn(tester, 'joy', 'temp-1234');
    expect(container.read(currentUserProvider), isNull);
    expect(find.text('Welcome, Joy'), findsOneWidget);

    // Too short, then the same as the temporary one: refused.
    await tester.enterText(field('new-password'), 'short');
    await tester.enterText(field('new-password-again'), 'short');
    await tester.tap(find.byKey(const ValueKey('new-password-save')));
    await tester.pumpAndSettle();
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    await tester.enterText(field('new-password'), 'temp-1234');
    await tester.enterText(field('new-password-again'), 'temp-1234');
    await tester.tap(find.byKey(const ValueKey('new-password-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('different from the temporary'), findsOneWidget);

    await tester.enterText(field('new-password'), 'joy-own-pass');
    await tester.enterText(field('new-password-again'), 'joy-own-pass');
    await tester.tap(find.byKey(const ValueKey('new-password-save')));
    await settle(tester);
    expect(container.read(currentUserProvider)?.username, 'joy');
    expect(cloud.userPasswords[1], 'joy-own-pass');
    expect(cloud.users[1]!.mustChange, isFalse);
    container.dispose();
  });

  testWidgets('accounts: locked, switched off, and the first admin', (
    tester,
  ) async {
    // A brand-new online database asks for the first admin account.
    var container = await pumpAccounts(tester, boss);
    expect(find.text('Create the first admin account'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('setup-name')),
      'Collins Korir',
    );
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('setup-username')))
          .controller!
          .text,
      'collins.korir',
    );
    await tester.enterText(field('setup-password'), 'admin-pass-1');
    await tester.enterText(field('setup-confirm'), 'admin-pass-1');
    await tester.tap(find.byKey(const ValueKey('setup-submit')));
    await settle(tester);
    expect(container.read(sessionProvider), UserRole.admin);
    expect(cloud.users.values.single.username, 'collins.korir');
    container.dispose();

    cloud.addUser('dennis', 'dennis-pass', active: false);
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, admin);
    await signIn(tester, 'dennis', 'dennis-pass');
    expect(find.textContaining('switched off'), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await signIn(tester, 'collins.korir', 'nope-nope');
    }
    expect(find.textContaining('Too many wrong passwords'), findsOneWidget);
    expect(container.read(currentUserProvider), isNull);
    container.dispose();
  });

  testWidgets('accounts: no internet — only a device signed in before', (
    tester,
  ) async {
    cloud.addUser('whitney', 'whitney-pw1', role: UserRole.adminTeam);
    var container = await pumpAccounts(tester, boss);
    await signIn(tester, 'whitney', 'whitney-pw1');
    container.dispose();

    cloud.offline = true;
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, boss);
    await signIn(tester, 'someone.new', 'whatever-1');
    expect(find.textContaining('No internet connection'), findsOneWidget);
    await signIn(tester, 'whitney', 'wrong-pass-1');
    expect(find.text('Username or password is incorrect.'), findsOneWidget);
    await signIn(tester, 'whitney', 'whitney-pw1');
    expect(container.read(currentUserProvider)?.username, 'whitney');

    // Back online: signed in online by itself, and changes can go up.
    cloud.offline = false;
    final logins = cloud.logins.length;
    await tester.runAsync(
      () => container.read(cloudSyncProvider.notifier).syncNow(),
    );
    await tester.pumpAndSettle();
    expect(cloud.logins.length, logins + 1);
    expect(container.read(cloudSyncProvider).adminLinked, isTrue);
    container.dispose();
  });

  testWidgets('accounts: an ended sign-in goes back to the sign-in screen', (
    tester,
  ) async {
    cloud.addUser('talaam', 'talaam-pw1', role: UserRole.director);
    final container = await pumpAccounts(tester, boss);
    await signIn(tester, 'talaam', 'talaam-pw1', remember: true);
    expect(container.read(sessionProvider), UserRole.director);

    // The admin resets the password elsewhere.
    cloud.userTokens.clear();
    await tester.runAsync(
      () => container.read(cloudSyncProvider.notifier).checkSession(),
    );
    await tester.pumpAndSettle();
    expect(container.read(currentUserProvider), isNull);
    expect(find.byKey(const ValueKey('signin-notice')), findsOneWidget);
    expect(AuthRepository(boss).rememberedUser, isNull);
    container.dispose();
  });

  testWidgets('accounts: the admin adds a user and resets a password', (
    tester,
  ) async {
    cloud.addUser('admin', 'admin-pass-1', role: UserRole.admin, name: 'Admin');
    final container = await pumpAccounts(
      tester,
      admin,
      size: const Size(1600, 2400),
    );
    await signIn(tester, 'admin', 'admin-pass-1');
    container.read(navTabProvider.notifier).set(AppTab.settings);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('settings-cat-team')));
    await settle(tester);
    expect(find.text('Users'), findsWidgets);
    expect(find.text('Profiles'), findsNothing);
    expect(find.byKey(const ValueKey('user-admin')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-user')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('user-name')),
      'Beatrice Achieng',
    );
    await tester.pump();
    final temp = tester
        .widget<TextField>(find.byKey(const ValueKey('user-password')))
        .controller!
        .text;
    expect(temp.length, greaterThanOrEqualTo(8));
    await tester.tap(find.byKey(const ValueKey('user-save')));
    await settle(tester);
    final created = cloud.users.values.firstWhere(
      (u) => u.fullName == 'Beatrice Achieng',
    );
    expect(created.username, 'beatrice.achieng');
    expect(created.mustChange, isTrue);
    expect(cloud.userPasswords[created.id], temp);
    expect(find.textContaining('Temporary password: $temp'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // Forgot it: a new temporary password.
    await tester.tap(find.byKey(const ValueKey('user-menu-beatrice.achieng')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset password'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-reset')));
    await settle(tester);
    expect(cloud.userPasswords[created.id], isNot(temp));
    expect(find.text('Password reset'), findsOneWidget);
    container.dispose();
  });

  testWidgets('accounts: the sign-in screen fits a phone', (tester) async {
    cloud.addUser('rhab', 'rhab-pass-1', role: UserRole.adminTeam);
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(360, 740),
    );
    expect(find.byKey(const ValueKey('login-remember')), findsOneWidget);
    await signIn(tester, 'rhab', 'rhab-pass-1', remember: true);
    expect(container.read(currentUserProvider)?.username, 'rhab');
    container.dispose();
  });

  test('usernames are suggested from names', () {
    expect(AppUser.suggestUsername('Mary Wanjiku'), 'mary.wanjiku');
    expect(AppUser.suggestUsername('  Director/Eve '), 'director.eve');
    expect(AppUser.suggestUsername('Canisius Yego'), 'canisius.yego');
    expect(AppUser.suggestUsername('Jo'), 'jo1');
    expect(AppUser.suggestUsername('Joy', taken: ['joy']), 'joy2');
    expect(AppUser.suggestUsername('Zoë O’Neil'), 'zoe.oneil');
    for (final n in ['Mary Wanjiku', 'Director/Eve', 'Jo', 'Zoë O’Neil']) {
      expect(
        AppUser.usernamePattern.hasMatch(AppUser.suggestUsername(n)),
        true,
      );
    }
  });

  // ------------------------------------------------------- daily reports ---

  Map<String, Object?> seedReport(
    int id,
    int userId,
    int? dept, {
    String status = 'done',
    String review = 'submitted',
    String? date = '2026-11-09',
    String? due,
    String urgency = 'normal',
    int? assignedBy,
    Map<String, int> outputs = const {},
    String description = 'Work done',
  }) => cloud.reports[id] = {
    'id': id,
    'user_id': userId,
    'assigned_by': assignedBy,
    'department_id': dept,
    'report_date': status == 'done' ? date : null,
    'description': description,
    'details': '',
    'reference': '',
    'outputs': outputs,
    'status': status,
    'blocker': status == 'blocked' ? 'Clinic closed' : '',
    'urgency': urgency,
    'due_date': due,
    'review': status == 'done' ? review : 'none',
    'submitted_at': status == 'done' ? '${date}T07:00:00Z' : null,
    'created_at': '2026-11-09T07:00:00Z',
    'updated_at': '2026-11-09T07:00:00Z',
  };

  /// Which button of a Done / To do pair is chosen.
  TaskMode modeOf(String key) => find
      .ancestor(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TaskModeToggle),
      )
      .evaluate()
      .map((e) => (e.widget as TaskModeToggle).value)
      .first;

  /// A task card's title (it's rich text, after the #id).
  Finder taskTitle(String text) =>
      find.textContaining(text, findRichText: true);

  /// The Daily reports tab whose label starts with [label].
  Finder reportsTab(String label) => find.descendant(
    of: find.byKey(const ValueKey('reports-tab')),
    matching: find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').startsWith(label),
    ),
  );

  Future<void> openReportsTab(WidgetTester tester, String label) async {
    // On a phone the tabs scroll sideways.
    await tester.ensureVisible(reportsTab(label));
    await tester.pumpAndSettle();
    await tester.tap(reportsTab(label));
    await settle(tester);
  }

  /// Types [value] into a count stepper.
  Future<void> enterCount(WidgetTester tester, String key, String value) =>
      tester.enterText(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(TextField),
        ),
        value,
      );

  testWidgets('daily reports: an employee adds activity done and plans', (
    tester,
  ) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1400),
    );
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    expect(container.read(navTabProvider), AppTab.dailyReports);
    // Everything the page opens with comes in one call.
    expect(cloud.calls.where((c) => c == 'report_start'), hasLength(1));
    expect(find.byKey(const ValueKey('my-today')), findsOneWidget);
    expect(find.textContaining('nothing submitted yet'), findsOneWidget);
    // Employees: My tasks and My submissions only.
    expect(reportsTab('My submissions'), findsOneWidget);
    expect(reportsTab('Team'), findsNothing);
    expect(reportsTab('Review'), findsNothing);

    // Add activity done: submitted at once, dated today.
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, 'Add activity'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Lodged visa applications',
    );
    await enterCount(tester, 'output-visa_lodgements', '3');
    // Urgency, notes and reference are behind More.
    expect(find.byKey(const ValueKey('urgency-high')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('report-more')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('urgency-high')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    final done = cloud.reports.values.single;
    expect(done['outputs'], {'visa_lodgements': 3});
    expect(done['user_id'], 1);
    expect(done['status'], 'done');
    expect(done['review'], 'submitted');
    expect(done['report_date'], '2026-11-09');
    expect(done['urgency'], 'high');
    expect(find.textContaining('1 submitted'), findsOneWidget);

    // Plan a task (Done / To do buttons), then Save & add another.
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    // Two statuses only: no In progress.
    expect(find.text('Doing now'), findsNothing);
    expect(find.text('In progress'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('task-mode-todo')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, 'Add a task'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Call the embassy',
    );
    // The urgency used last is remembered (shown beside More details).
    expect(find.byKey(const ValueKey('urgency-high')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(UrgencyPill),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('report-more')));
    await tester.pump();
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('urgency-high')))
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('urgency-normal')));
    await tester.tap(find.byKey(const ValueKey('due-Tomorrow')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('report-save-another')));
    await settle(tester);
    expect(find.byKey(const ValueKey('added-list')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Chase medical results',
    );
    // To do stays chosen for the next one.
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    final call = cloud.reports.values.firstWhere(
      (r) => r['description'] == 'Call the embassy',
    );
    expect(call['status'], 'to_do');
    expect(call['due_date'], '2026-11-10');
    expect(call['report_date'], isNull);
    final chase = cloud.reports.values.firstWhere(
      (r) => r['description'] == 'Chase medical results',
    );
    expect(chase['status'], 'to_do');
    expect(find.byKey(const ValueKey('section-todo')), findsOneWidget);

    // The list card: typed items wait there with a status drop-down
    // each, until they're saved together.
    await tester.enterText(
      find.byKey(const ValueKey('quick-task')),
      'Print the COE letters',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.byKey(const ValueKey('draft-1')), findsOneWidget);
    expect(
      cloud.reports.values.where(
        (r) => r['description'] == 'Print the COE letters',
      ),
      isEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('draft-mode-1-todo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('draft-urgency-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Urgent').last);
    await tester.pumpAndSettle();
    expect(find.text('Add 1 to my list'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('draft-save')));
    await settle(tester);
    expect(find.byKey(const ValueKey('draft-1')), findsNothing);
    final printIt = cloud.reports.values.firstWhere(
      (r) => r['description'] == 'Print the COE letters',
    );
    expect(printIt['urgency'], 'urgent');
    expect(printIt['status'], 'to_do');

    // Cards have no status menu: the section says it, the tick finishes.
    expect(find.byKey(ValueKey('status-menu-${call['id']}')), findsNothing);

    // Submit when done, with what was done and counts.
    await tester.tap(find.byKey(ValueKey('submit-${call['id']}')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('submit-details')),
      'Booked the interview for Monday',
    );
    await enterCount(tester, 'submit-output-visa_lodgements', '1');
    await tester.enterText(
      find.byKey(const ValueKey('submit-note')),
      'Please check the date',
    );
    await tester.tap(find.byKey(const ValueKey('submit-confirm')));
    await settle(tester);
    final sent = cloud.reports[call['id']]!;
    expect(sent['review'], 'submitted');
    expect(sent['status'], 'done');
    expect(sent['report_date'], '2026-11-09');
    expect(sent['details'], 'Booked the interview for Monday');
    expect(cloud.comments.last, containsPair('body', 'Please check the date'));

    // My submissions: grouped under today, with the totals.
    await openReportsTab(tester, 'My submissions');
    expect(find.byKey(const ValueKey('day-2026-11-09')), findsOneWidget);
    expect(find.textContaining('2 tasks'), findsOneWidget);
    expect(find.textContaining('Visa lodgements 4'), findsWidgets);
    expect(taskTitle('Lodged visa applications'), findsOneWidget);
    expect(find.textContaining('Submitted '), findsWidgets);
    container.dispose();
  });

  testWidgets('daily reports: assign, notify, submit, return, resubmit, '
      'approve', (tester) async {
    cloud.addUser('zawadi', 'zawadi-pass1', name: 'Zawadi', departmentId: 2);
    cloud.addUser(
      'grace',
      'grace-pass-1',
      name: 'Grace',
      departmentId: 2,
      reportAccess: ReportAccess.head,
    );
    cloud.addUser('otieno', 'otieno-pass-1', name: 'Otieno', departmentId: 1);
    var container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 2600),
    );
    await signIn(tester, 'grace', 'grace-pass-1');
    await settle(tester);

    // Grace assigns a task to two people at once, urgent, due tomorrow.
    await openReportsTab(tester, 'Team');
    await tester.tap(find.byKey(const ValueKey('assign-task')));
    await tester.pumpAndSettle();
    expect(find.text('Assign a task'), findsOneWidget);
    // A department head can assign to anyone.
    expect(find.byKey(const ValueKey('assign-3')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('assign-1')));
    await tester.tap(find.byKey(const ValueKey('assign-3')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Audit January files',
    );
    await tester.tap(find.byKey(const ValueKey('urgency-urgent')));
    await tester.tap(find.byKey(const ValueKey('due-Tomorrow')));
    await tester.pump();
    expect(find.text('Assign to 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    expect(cloud.reports, hasLength(2));
    final task = cloud.reports.values.firstWhere((r) => r['user_id'] == 1);
    final id = task['id'] as int;
    expect(task['assigned_by'], 2);
    expect(task['status'], 'to_do');
    expect(task['urgency'], 'urgent');
    expect(task['due_date'], '2026-11-10');
    expect(
      cloud.notifications.where((n) => n['kind'] == 'assigned'),
      hasLength(2),
    );
    container.dispose();

    // Zawadi: a notification, and the task on her list, from Grace.
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, admin, size: const Size(1600, 2600));
    await signIn(tester, 'zawadi', 'zawadi-pass1');
    await settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('report-bell')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('report-bell')));
    await settle(tester);
    expect(find.text('Grace assigned you a task #$id'), findsOneWidget);
    expect(
      cloud.notifications.every((n) => n['user_id'] != 1 || n['read'] == true),
      isTrue,
    );
    await tester.tap(find.text('Close'));
    await settle(tester);
    expect(find.textContaining('From Grace', findRichText: true), findsWidgets);

    // She submits it; it goes to Grace.
    await tester.tap(find.byKey(ValueKey('submit-$id')));
    await tester.pumpAndSettle();
    expect(find.textContaining('to Grace to review'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('submit-details')),
      'Checked 40 files',
    );
    await tester.tap(find.byKey(const ValueKey('submit-confirm')));
    await settle(tester);
    expect(cloud.reports[id]!['review'], 'submitted');
    // Waiting for review: she can't change it now.
    await tester.tap(find.byKey(const ValueKey('reports-refresh')));
    await settle(tester);
    expect(find.byKey(ValueKey('submit-$id')), findsNothing);
    container.dispose();

    // Grace: Review shows it; returning needs a comment.
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, boss, size: const Size(1600, 2600));
    await signIn(tester, 'grace', 'grace-pass-1');
    await settle(tester);
    expect(reportsTab('Review (1)'), findsOneWidget);
    await openReportsTab(tester, 'Review');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('review-waiting')),
        matching: taskTitle('Audit January files'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Checked 40 files'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('return-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('review-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('review-error')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('review-comment')),
      'Include the February ones too',
    );
    await tester.tap(find.byKey(const ValueKey('review-confirm')));
    await settle(tester);
    expect(cloud.reports[id]!['review'], 'returned');
    expect(cloud.reports[id]!['status'], 'in_progress');
    container.dispose();

    // Zawadi: returned, with the comment; she resubmits.
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, admin, size: const Size(1600, 2600));
    await signIn(tester, 'zawadi', 'zawadi-pass1');
    await settle(tester);
    expect(find.byKey(const ValueKey('section-returned')), findsOneWidget);
    expect(
      find.textContaining('Include the February ones too', findRichText: true),
      findsWidgets,
    );
    await tester.tap(find.byKey(ValueKey('submit-$id')));
    await tester.pumpAndSettle();
    // The dialog repeats what to fix, with what was sent before filled in
    // (and editable). An assigned task keeps its title.
    expect(
      find.text('Returned: Include the February ones too'),
      findsOneWidget,
    );
    expect(find.text('Resubmit #$id'), findsOneWidget);
    expect(find.byKey(const ValueKey('submit-title')), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('submit-details')))
          .controller!
          .text,
      'Checked 40 files',
    );
    await tester.enterText(
      find.byKey(const ValueKey('submit-details')),
      'Checked 40 files and the February ones',
    );
    await tester.tap(find.byKey(const ValueKey('submit-confirm')));
    await settle(tester);
    expect(cloud.reports[id]!['review'], 'submitted');
    expect(
      cloud.reports[id]!['details'],
      'Checked 40 files and the February ones',
    );
    container.dispose();

    // Grace approves it from the task itself; the timeline shows it all.
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, boss, size: const Size(1600, 2600));
    await signIn(tester, 'grace', 'grace-pass-1');
    await settle(tester);
    await openReportsTab(tester, 'Review');
    await tester.tap(find.byKey(ValueKey('report-$id')));
    await settle(tester);
    expect(find.byKey(const ValueKey('task-id')), findsOneWidget);
    expect(
      find.textContaining('Include the February ones too', findRichText: true),
      findsWidgets,
    );
    await tester.tap(find.byKey(const ValueKey('approve-report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('review-confirm')));
    await settle(tester);
    expect(cloud.reports[id]!['review'], 'approved');
    expect(
      [
        for (final c in reportChangesFor(cloud, id))
          if (c != 'created' && c != 'edited') c,
      ],
      ['submitted', 'returned', 'submitted', 'approved'],
    );
    expect(
      cloud.notifications.where((n) => n['user_id'] == 1).map((n) => n['kind']),
      containsAll(['assigned', 'returned', 'approved']),
    );
    container.dispose();
  });

  testWidgets('daily reports: search by words, a name or #id', (tester) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    cloud.addUser('otieno', 'otieno-pass-1', name: 'Otieno', departmentId: 1);
    cloud.addUser(
      'ruth',
      'ruth-pass-1',
      name: 'Ruth',
      reportAccess: ReportAccess.manager,
    );
    seedReport(10, 1, 2, description: 'Visa lodgement for Zoë');
    seedReport(11, 2, 1, description: 'Offer letters sent');
    seedReport(12, 2, 1, status: 'to_do', description: 'Phone the bank');
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 2600),
    );
    await signIn(tester, 'ruth', 'ruth-pass-1');
    await settle(tester);
    Future<void> search(String text) async {
      if (find.byKey(const ValueKey('task-search')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('search-open')));
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.byKey(const ValueKey('task-search')), text);
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
    }

    await search('#11');
    expect(find.text('1 task matching “#11”'), findsOneWidget);
    expect(taskTitle('Offer letters sent'), findsOneWidget);
    await search('otieno');
    expect(find.text('2 tasks matching “otieno”'), findsOneWidget);
    await search('visa');
    expect(taskTitle('Visa lodgement for Zoë'), findsOneWidget);
    await search('nothing like this');
    expect(find.textContaining('Nothing matches'), findsOneWidget);
    container.dispose();
  });

  testWidgets('daily reports: the team view, the head’s department', (
    tester,
  ) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    cloud.addUser(
      'grace',
      'grace-pass-1',
      name: 'Grace',
      departmentId: 2,
      reportAccess: ReportAccess.head,
    );
    cloud.addUser('otieno', 'otieno-pass-1', name: 'Otieno', departmentId: 1);
    cloud.addUser(
      'ruth',
      'ruth-pass-1',
      name: 'Ruth',
      reportAccess: ReportAccess.manager,
    );
    seedReport(
      10,
      1,
      2,
      status: 'blocked',
      due: '2026-11-08',
      description: 'Waiting on clinic',
    );
    seedReport(
      11,
      3,
      1,
      outputs: {'applications_submitted': 4},
      description: 'Submitted applications',
    );

    var container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 2600),
    );
    await signIn(tester, 'ruth', 'ruth-pass-1');
    await settle(tester);
    // No department of her own: straight to Team.
    expect(find.text('Who has reported'), findsOneWidget);
    expect(find.text('1 of 3 today'), findsOneWidget);
    expect(find.textContaining('Applications submitted 4'), findsWidgets);
    Finder stat(String key, String value) => find.descendant(
      of: find.byKey(ValueKey(key)),
      matching: find.text(value),
    );
    expect(stat('stat-total', '1'), findsOneWidget);
    expect(stat('stat-overdue', '1'), findsOneWidget);
    // Open tasks list: the blocked one, red note.
    expect(taskTitle('Waiting on clinic'), findsOneWidget);
    expect(
      find.textContaining('Clinic closed', findRichText: true),
      findsOneWidget,
    );

    // A department: the figures follow.
    await tester.tap(find.text('Admissions & Applications').last);
    await settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('report-department')),
        matching: find.text('Admissions & Applications'),
      ),
      findsOneWidget,
    );
    expect(stat('stat-overdue', '0'), findsOneWidget);
    container.dispose();

    // The Visa head sees Visa only.
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, admin, size: const Size(1600, 2600));
    await signIn(tester, 'grace', 'grace-pass-1');
    await settle(tester);
    await openReportsTab(tester, 'Team');
    expect(find.text('Visa Processing & Documentation'), findsWidgets);
    expect(find.text('Admissions & Applications'), findsNothing);
    expect(taskTitle('Submitted applications'), findsNothing);
    expect(taskTitle('Waiting on clinic'), findsWidgets);
    container.dispose();
  });

  testWidgets('daily reports: the admin manages departments', (tester) async {
    cloud.addUser('admin', 'admin-pass-1', role: UserRole.admin, name: 'Admin');
    final container = await pumpAccounts(
      tester,
      admin,
      size: const Size(1600, 3000),
    );
    await signIn(tester, 'admin', 'admin-pass-1');
    container.read(navTabProvider.notifier).set(AppTab.settings);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('settings-cat-team')));
    await settle(tester);
    expect(find.byKey(const ValueKey('department-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-department')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('department-name')),
      'Customer Care',
    );
    await tester.enterText(
      find.byKey(const ValueKey('department-outputs')),
      'Calls made\nComplaints resolved\n\nCalls made',
    );
    await tester.tap(find.byKey(const ValueKey('department-save')));
    await settle(tester);
    final care = cloud.departments.firstWhere(
      (d) => d['name'] == 'Customer Care',
    );
    expect(care['outputs'], [
      {'key': 'calls_made', 'label': 'Calls made'},
      {'key': 'complaints_resolved', 'label': 'Complaints resolved'},
    ]);

    // A person's department and report access are set in Users.
    await tester.tap(find.byKey(const ValueKey('add-user')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('user-department')), findsOneWidget);
    expect(find.byKey(const ValueKey('user-access')), findsOneWidget);
    container.dispose();
  });

  test('operations report exports: Excel sheets and a real PDF', () async {
    final summary = ReportSummary.fromJson({
      'from': '2026-11-03',
      'to': '2026-11-09',
      'today': '2026-11-09',
      'working_days': 5,
      'status': {'done': 1, 'blocked': 1},
      'review': {'approved': 1},
      'departments': [
        {
          'id': 1,
          'name': 'Admissions & Applications',
          'activities': 2,
          'completed': 1,
          'open': 1,
          'blocked': 1,
          'awaiting': 0,
          'people': 1,
          'outputs': {'applications_submitted': 4},
        },
      ],
      'compliance': [
        {
          'id': 1,
          'full_name': 'Otieno',
          'department_name': 'Admissions & Applications',
          'days_submitted': 3,
          'entries': 4,
          'submitted_today': true,
          'last_date': '2026-11-09',
        },
      ],
      'overdue': [],
      'attention': [],
    });
    final entry = ActivityReport.fromJson({
      'id': 1,
      'user_id': 1,
      'user_name': 'Otieno',
      'department_id': 1,
      'department_name': 'Admissions & Applications',
      'report_date': '2026-11-09',
      'description': 'Submitted applications — Zoë’s file',
      'outputs': {'applications_submitted': 4},
      'status': 'done',
      'review': 'approved',
      'urgency': 'high',
      'submitted_at': '2026-11-09T09:00:00Z',
    });
    final report = OperationsReport(
      title: 'Weekly Performance Report',
      periodLabel: '3 Nov 2026 – 9 Nov 2026',
      filtersLabel: 'All departments · Everyone',
      generatedBy: 'Ruth',
      generatedAt: DateTime(2026, 11, 9, 17),
      summary: summary,
      entries: [entry],
      departments: [
        Department.fromJson({
          'id': 1,
          'name': 'Admissions & Applications',
          'outputs': [
            {
              'key': 'applications_submitted',
              'label': 'Applications submitted',
            },
          ],
        }),
      ],
    );
    expect(report.outputsText(1, entry.outputs), 'Applications submitted 4');
    expect(
      report.fileStem,
      'weekly_performance_report_2026-11-03_to_2026-11-09',
    );

    final xlsx = Excel.decodeBytes(operationsReportToExcel(report));
    expect(
      xlsx.tables.keys,
      containsAll(['Summary', 'Departments', 'Entries', 'Compliance']),
    );
    final entries = xlsx.tables['Entries']!;
    expect(entries.rows[1][0]?.value.toString(), '#1');
    expect(entries.rows[1][2]?.value.toString(), 'Otieno');

    ByteData font(String f) =>
        ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync());
    final pdf = await operationsReportToPdf(
      report,
      regular: font('Inter-400.ttf'),
      bold: font('Inter-700.ttf'),
    );
    expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    expect(pdf.length, greaterThan(2000));
  });

  testWidgets('to-do: a personal list on every device, sent to Daily '
      'reports when wanted', (tester) async {
    final aminaId = cloud
        .addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2)
        .id;
    var container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1400, 1000),
    );
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    container.read(appActionsProvider).selectTab(AppTab.todo);
    await settle(tester);
    expect(find.text('Nothing on your list'), findsOneWidget);

    // Enter adds; a pasted list adds a line each.
    final input = find.byKey(const ValueKey('todo-input'));
    await tester.enterText(input, 'Call the embassy');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(input, '- Print COE letters\n- Book interview\n');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('3 to do · 0 done'), findsOneWidget);
    // Saved with the account, not only here.
    expect(cloud.todos[aminaId]!.values, hasLength(3));
    expect(
      find.text('Your own list, the same on all your devices.'),
      findsOneWidget,
    );

    final ids = container.read(todoListProvider).map((t) => t.id).toList();
    await tester.tap(find.byKey(ValueKey('todo-tick-${ids[0]}')));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('2 to do · 1 done'), findsOneWidget);
    expect(find.text('Done (1)'), findsOneWidget);

    // Delete with Undo.
    await tester.tap(find.byKey(ValueKey('todo-menu-${ids[2]}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(find.text('Book interview'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('report-undo')));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('Book interview'), findsOneWidget);
    expect(cloud.todos[aminaId]![ids[2]]!['deleted'], isNot(true));
    container.dispose();

    // Another device (nothing kept on it): the same list.
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.setMockInitialValues({});
    container = await pumpAccounts(tester, boss, size: const Size(390, 860));
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    container.read(appActionsProvider).selectTab(AppTab.todo);
    await settle(tester);
    expect(find.text('2 to do · 1 done'), findsOneWidget);
    expect(find.text('Call the embassy'), findsOneWidget);

    // Send to Daily reports: done ones are submitted, the rest listed.
    await tester.tap(find.byKey(const ValueKey('todo-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('todo-send-${ids[1]}')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('todo-send-confirm')));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    final call = cloud.reports.values.singleWhere(
      (r) => r['description'] == 'Call the embassy',
    );
    expect(call['review'], 'submitted');
    final print = cloud.reports.values.singleWhere(
      (r) => r['description'] == 'Print COE letters',
    );
    expect(print['status'], 'to_do');
    expect(
      cloud.reports.values.where((r) => r['description'] == 'Book interview'),
      isEmpty,
    );
    expect(find.byKey(ValueKey('todo-sent-${ids[0]}')), findsOneWidget);
    expect(find.byKey(ValueKey('todo-sent-${ids[1]}')), findsOneWidget);
    expect(cloud.todos[aminaId]![ids[0]]!['sent_id'], call['id']);
    // Only the unsent one is left to send.
    await tester.tap(find.byKey(const ValueKey('todo-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('todo-send-${ids[2]}')), findsOneWidget);
    expect(find.byKey(ValueKey('todo-send-${ids[0]}')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Clear done, with Undo.
    await tester.tap(find.byKey(const ValueKey('todo-clear-done')));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('Call the embassy'), findsNothing);
    expect(cloud.todos[aminaId]![ids[0]]!['deleted'], isTrue);
    expect(tester.takeException(), isNull);
    container.dispose();
  });

  testWidgets('daily reports: Review updates by itself when work is '
      'submitted', (tester) async {
    cloud.addUser('zawadi', 'zawadi-pass1', name: 'Zawadi', departmentId: 2);
    cloud.addUser(
      'grace',
      'grace-pass-1',
      name: 'Grace',
      departmentId: 2,
      reportAccess: ReportAccess.head,
    );
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1400),
    );
    await signIn(tester, 'grace', 'grace-pass-1');
    await settle(tester);
    await openReportsTab(tester, 'Review');
    expect(taskTitle('Lodged six visas'), findsNothing);

    // Zawadi submits on her own device; Grace touches nothing.
    seedReport(40, 1, 2, description: 'Lodged six visas');
    await tester.pump(const Duration(seconds: 31));
    await settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('review-waiting')),
        matching: taskTitle('Lodged six visas'),
      ),
      findsOneWidget,
    );
    expect(reportsTab('Review (1)'), findsOneWidget);
    container.dispose();
  });

  testWidgets('daily reports: your own returned task can be renamed when '
      'resubmitted', (tester) async {
    cloud.addUser('zawadi', 'zawadi-pass1', name: 'Zawadi', departmentId: 2);
    final r = seedReport(41, 1, 2, description: 'Lodged visas');
    r['review'] = 'returned';
    r['status'] = 'in_progress';
    r['report_date'] = null;
    r['details'] = 'Six lodged';
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1400),
    );
    await signIn(tester, 'zawadi', 'zawadi-pass1');
    await settle(tester);
    expect(find.byKey(const ValueKey('section-returned')), findsOneWidget);
    expect(find.text('Resubmit'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('submit-41')));
    await tester.pumpAndSettle();
    final title = find.byKey(const ValueKey('submit-title'));
    expect(tester.widget<TextField>(title).controller!.text, 'Lodged visas');
    await tester.enterText(title, 'Lodged visas for the Nairobi intake');
    await tester.tap(find.byKey(const ValueKey('submit-confirm')));
    await settle(tester);
    expect(cloud.reports[41]!['review'], 'submitted');
    expect(
      cloud.reports[41]!['description'],
      'Lodged visas for the Nairobi intake',
    );
    expect(cloud.reports[41]!['details'], 'Six lodged');
    container.dispose();
  });

  testWidgets('daily reports fit a phone', (tester) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    cloud.addUser(
      'ruth',
      'ruth-pass-1',
      name: 'Ruth',
      reportAccess: ReportAccess.manager,
      departmentId: 1,
    );
    seedReport(
      10,
      1,
      2,
      status: 'in_progress',
      urgency: 'urgent',
      due: '2026-11-08',
      description: 'A long description of a visa case that is urgent and late',
    );
    const phone = Size(360, 780);
    var container = await pumpAccounts(tester, boss, size: phone);
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    // Search is a button until it's wanted.
    expect(find.byKey(const ValueKey('phone-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-search')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('search-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-search')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-search')), findsNothing);
    expect(find.byKey(const ValueKey('section-doing')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-mode-done')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-mode-todo')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    container.dispose();

    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, admin, size: phone);
    await signIn(tester, 'ruth', 'ruth-pass-1');
    await settle(tester);
    await openReportsTab(tester, 'Team');
    expect(find.byKey(const ValueKey('stat-total')), findsOneWidget);
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -1500),
    );
    await tester.pumpAndSettle();
    container.dispose();
  });

  // ------------------------------------------------------- review fixes ---

  testWidgets('daily reports: a new day and Refresh reload the page', (
    tester,
  ) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1400),
    );
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    expect(find.textContaining('Mon 9 Nov'), findsOneWidget);

    // Left open overnight: the app notices the new day (data version).
    cloud.reportsToday = DateTime(2026, 11, 10);
    container.read(dataVersionProvider.notifier).bump();
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.textContaining('Tue 10 Nov'), findsOneWidget);

    // Work done now is submitted for the new day.
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Next day work',
    );
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    expect(cloud.reports.values.single['report_date'], '2026-11-10');

    // Refresh picks up a task assigned meanwhile.
    seedReport(50, 1, 2, status: 'to_do', description: 'Assigned meanwhile');
    await tester.tap(find.byKey(const ValueKey('reports-refresh')));
    await settle(tester);
    expect(taskTitle('Assigned meanwhile'), findsOneWidget);
    container.dispose();
  });

  testWidgets('daily reports: the page opens at once from this device', (
    tester,
  ) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    seedReport(10, 1, 2, status: 'to_do', description: 'Remembered task');
    var container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1400),
    );
    await signIn(tester, 'amina', 'amina-pass-1', remember: true);
    await settle(tester);
    expect(taskTitle('Remembered task'), findsOneWidget);
    container.dispose();

    // Offline next time: the copy saved on this device still shows.
    cloud.offline = true;
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, boss, size: const Size(1600, 1400));
    await settle(tester);
    expect(container.read(currentUserProvider)?.username, 'amina');
    container.read(navTabProvider.notifier).set(AppTab.dailyReports);
    await settle(tester);
    expect(find.byKey(const ValueKey('reports-skeleton')), findsNothing);
    expect(taskTitle('Remembered task'), findsOneWidget);
    container.dispose();
  });

  testWidgets('daily reports: editing keeps counts for removed outputs', (
    tester,
  ) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    seedReport(
      10,
      1,
      2,
      status: 'in_progress',
      outputs: {'visa_grants': 2, 'visa_lodgements': 1},
      description: 'Old style report',
      due: '2024-01-15',
    );
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1400),
    );
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('report-10')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('edit-report')));
    await tester.pumpAndSettle();
    // A due date far in the past still opens the picker.
    await tester.tap(find.byKey(const ValueKey('report-due')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Old style report, fixed',
    );
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    expect(cloud.reports[10]!['description'], 'Old style report, fixed');
    expect(cloud.reports[10]!['outputs'], {
      'visa_grants': 2,
      'visa_lodgements': 1,
    });
    container.dispose();
  });

  testWidgets('accounts: backing out of a temporary password ends it', (
    tester,
  ) async {
    cloud.addUser('joy', 'temp-1234', mustChange: true, name: 'Joy');
    final container = await pumpAccounts(tester, boss);
    await signIn(tester, 'joy', 'temp-1234');
    expect(find.text('Welcome, Joy'), findsOneWidget);
    expect(cloud.userTokens, hasLength(1));
    await tester.tap(find.text('Back'));
    await settle(tester);
    expect(cloud.userTokens, isEmpty);
    expect(find.byKey(const ValueKey('login-username')), findsOneWidget);
    container.dispose();
  });

  testWidgets('accounts: a server hiccup doesn’t end an offline sign-in', (
    tester,
  ) async {
    cloud.addUser('whitney', 'whitney-pw1', role: UserRole.adminTeam);
    var container = await pumpAccounts(tester, boss);
    await signIn(tester, 'whitney', 'whitney-pw1');
    container.dispose();

    cloud.offline = true;
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, boss);
    await signIn(tester, 'whitney', 'whitney-pw1');
    expect(container.read(currentUserProvider)?.username, 'whitney');

    // Back online, but the server refuses for another reason.
    cloud.offline = false;
    cloud.failNextLogin = 'other';
    await tester.runAsync(
      () => container.read(cloudSyncProvider.notifier).syncNow(),
    );
    await tester.pumpAndSettle();
    expect(container.read(currentUserProvider)?.username, 'whitney');
    expect(AuthRepository(boss).knowsUser('whitney'), isTrue);

    // Next time it works.
    await tester.runAsync(
      () => container.read(cloudSyncProvider.notifier).syncNow(),
    );
    await tester.pumpAndSettle();
    expect(container.read(cloudSyncProvider).adminLinked, isTrue);
    container.dispose();
  });

  // ------------------------------------------------- quality of life ------

  testWidgets('admin deletes accounts; reports need a second yes', (
    tester,
  ) async {
    cloud.addUser('admin', 'admin-pass-1', role: UserRole.admin, name: 'Admin');
    cloud.addUser('temp', 'temp-pass-1', name: 'Temp Person');
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    seedReport(10, 3, 2);
    final container = await pumpAccounts(
      tester,
      admin,
      size: const Size(1600, 3000),
    );
    await signIn(tester, 'admin', 'admin-pass-1');
    container.read(navTabProvider.notifier).set(AppTab.settings);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('settings-cat-team')));
    await settle(tester);

    // No reports: deleted after one confirmation.
    await tester.tap(find.byKey(const ValueKey('user-menu-temp')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete-user')));
    await settle(tester);
    expect(cloud.users.values.any((u) => u.username == 'temp'), isFalse);
    expect(find.byKey(const ValueKey('user-temp')), findsNothing);

    // With reports: offered "switch off instead"; that keeps everything.
    await tester.tap(find.byKey(const ValueKey('user-menu-amina')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete-user')));
    await settle(tester);
    expect(find.textContaining('1 daily report was recorded'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-switch-off-instead')));
    await settle(tester);
    expect(cloud.users[3]!.active, isFalse);
    expect(cloud.reports, hasLength(1));

    // Or deleted with the reports.
    await tester.tap(find.byKey(const ValueKey('user-menu-amina')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete-user')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-with-reports')));
    await settle(tester);
    expect(cloud.users.containsKey(3), isFalse);
    expect(cloud.reports, isEmpty);

    // Never your own account.
    await tester.tap(find.byKey(const ValueKey('user-menu-admin')));
    await tester.pumpAndSettle();
    expect(find.text('Delete account…'), findsNothing);
    container.dispose();
  });

  testWidgets('the last username is filled in next time', (tester) async {
    cloud.addUser('mary.wanjiku', 'mary-pass-1', name: 'Mary');
    var container = await pumpAccounts(tester, boss);
    await signIn(tester, 'mary.wanjiku', 'mary-pass-1');
    await tester.tap(find.byKey(const ValueKey('sign-out')));
    await settle(tester);
    container.dispose();

    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, boss);
    await settle(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('login-username')))
          .controller!
          .text,
      'mary.wanjiku',
    );
    container.dispose();
  });

  testWidgets('daily reports: reminder dot, Ctrl+Enter, add again, discard', (
    tester,
  ) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1400),
    );
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    // Nothing yet today: a dot on Daily reports.
    expect(find.byKey(const ValueKey('report-due-dot')), findsOneWidget);

    // Ctrl+Enter saves.
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Weekly visa audit',
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(cloud.reports.values.single['description'], 'Weekly visa audit');
    expect(find.byKey(const ValueKey('report-due-dot')), findsNothing);

    // Add again: a copy to start from.
    await openReportsTab(tester, 'My submissions');
    await tester.tap(taskTitle('Weekly visa audit'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('repeat-report')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('report-description')))
          .controller!
          .text,
      'Weekly visa audit',
    );
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    expect(cloud.reports, hasLength(2));
    expect(cloud.reports.values.last['review'], 'submitted');
    await tester.tap(find.text('Close').last);
    await settle(tester);

    // Cancel after typing doesn't ask: Undo brings the draft back.
    await openReportsTab(tester, 'My tasks');
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Half typed',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Not saved.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('report-undo')));
    await tester.pumpAndSettle();
    expect(find.text('Half typed'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(cloud.reports, hasLength(2));
    container.dispose();
  });

  testWidgets('daily reports: quick line, tick, undo, paste, wrap up, '
      'offline, keys, notifications', (tester) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 2000),
    );
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    final quick = find.byKey(const ValueKey('quick-task'));
    Future<void> type(String text) async {
      await tester.enterText(quick, text);
      await tester.pump();
    }

    Future<void> enter() async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
    }

    Future<void> saveAll() async {
      await tester.tap(find.byKey(const ValueKey('draft-save')));
      await settle(tester);
    }

    // "done" and a count: on the list as Done today, the count in its
    // place; sent with Submit.
    await type('Lodged visas 3 done');
    await enter();
    expect(cloud.reports, isEmpty);
    expect(modeOf('draft-mode-1'), TaskMode.done);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('draft-count-1-visa_lodgements')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    expect(find.text('Submit 1'), findsOneWidget);
    await saveAll();
    final lodged = cloud.reports.values.single;
    expect(lodged['description'], 'Lodged visas');
    expect(lodged['outputs'], {'visa_lodgements': 3});
    expect(lodged['review'], 'submitted');
    // Undo: it was new, so it goes.
    await tester.tap(find.byKey(const ValueKey('report-undo')));
    await settle(tester);
    expect(cloud.reports, isEmpty);

    // New items start as To do once that's chosen; a due day and an
    // urgency in words.
    await tester.tap(find.byKey(const ValueKey('draft-default-mode-todo')));
    await tester.pumpAndSettle();
    await type('Call embassy tomorrow urgent');
    await enter();
    expect(find.text('Add 1 to my list'), findsOneWidget);
    await saveAll();
    final call = cloud.reports.values.single;
    expect(call['description'], 'Call embassy');
    expect(call['urgency'], 'urgent');
    expect(call['due_date'], '2026-11-10');
    expect(call['status'], 'to_do');
    final callId = call['id'] as int;

    // A pasted list: a task per line.
    await type('Book flights\nRenew passport\n- Email the school');
    await settle(tester);
    expect(find.text('Add 3 to my list'), findsOneWidget);
    // One is removed, with Undo.
    await tester.tap(find.byKey(const ValueKey('draft-remove-4')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('draft-4')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('report-undo')));
    await tester.pumpAndSettle();
    expect(find.text('Add 3 to my list'), findsOneWidget);
    await saveAll();
    expect(cloud.reports, hasLength(4));
    expect(
      cloud.reports.values.map((r) => r['description']),
      containsAll(['Book flights', 'Renew passport', 'Email the school']),
    );
    expect(find.text('Added 3 to your list'), findsOneWidget);
    expect(tester.widget<TextField>(quick).controller!.text, isEmpty);
    int idOf(String title) =>
        cloud.reports.values.firstWhere((r) => r['description'] == title)['id']
            as int;
    final flights = idOf('Book flights');
    final passport = idOf('Renew passport');
    final school = idOf('Email the school');

    // The department records counts, so ticking asks for them.
    await tester.tap(find.byKey(ValueKey('tick-$callId')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('submit-confirm')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Delete: hidden at once, Undo keeps it.
    await tester.tap(find.byKey(ValueKey('report-$school')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('delete-report')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('report-$school')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('report-undo')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('report-$school')), findsOneWidget);
    expect(cloud.reports.containsKey(school), isTrue);
    // Without Undo it goes when the message does.
    await tester.tap(find.byKey(ValueKey('report-$school')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('delete-report')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 8));
    await settle(tester);
    expect(cloud.reports.containsKey(school), isFalse);

    // Wrap up my day: tick what got done.
    await tester.tap(find.byKey(const ValueKey('wrap-up')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('wrap-$flights')));
    await tester.pump();
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(ValueKey('wrap-$flights')))
          .value,
      isTrue,
    );
    await tester.tap(find.byKey(ValueKey('wrap-$passport')));
    await tester.pump();
    await tester.enterText(
      find.byKey(ValueKey('wrap-$passport-visa_lodgements')),
      '2',
    );
    expect(find.text('Submit 2 tasks'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wrap-submit')));
    await settle(tester);
    expect(cloud.reports[flights]!['review'], 'submitted');
    expect(cloud.reports[passport]!['review'], 'submitted');
    expect(cloud.reports[passport]!['outputs'], {'visa_lodgements': 2});
    // Undo takes both back.
    await tester.tap(find.byKey(const ValueKey('report-undo')));
    await settle(tester);
    expect(cloud.reports[flights]!['review'], 'none');
    expect(cloud.reports[passport]!['status'], 'in_progress');
    expect(
      cloud.reportChanges.where((c) => c['action'] == 'withdrawn'),
      hasLength(2),
    );

    // Offline: kept on this device, shown, and sent later for that day.
    cloud.offline = true;
    await type('Scanned passports done');
    await enter();
    await saveAll();
    expect(
      cloud.reports.values.where(
        (r) => r['description'] == 'Scanned passports',
      ),
      isEmpty,
    );
    expect(find.byKey(const ValueKey('section-waiting')), findsOneWidget);
    expect(find.textContaining('sent when you’re back online'), findsOneWidget);
    cloud.offline = false;
    await tester.tap(find.byKey(const ValueKey('reports-refresh')));
    await settle(tester);
    final scanned = cloud.reports.values.firstWhere(
      (r) => r['description'] == 'Scanned passports',
    );
    expect(scanned['review'], 'submitted');
    expect(scanned['report_date'], '2026-11-09');
    expect(container.read(reportOutboxProvider), isEmpty);
    expect(find.textContaining('Waiting to send'), findsNothing);

    // Keys: Esc leaves the quick line, N comes back to it, Down to the
    // cards, / to search.
    await tester.tap(quick);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'my tasks');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'quick line');
    // Enter puts it on the list; Ctrl+Enter saves the whole list.
    await tester.enterText(quick, 'Ring the bank');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(
      cloud.reports.values.where((r) => r['description'] == 'Ring the bank'),
      isEmpty,
    );
    await tester.enterText(quick, 'Filed the receipts done');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(
      cloud.reports.values.firstWhere(
        (r) => r['description'] == 'Filed the receipts',
      )['review'],
      'submitted',
    );
    expect(
      cloud.reports.values.firstWhere(
        (r) => r['description'] == 'Ring the bank',
      )['status'],
      'to_do',
    );
    expect(find.text('Submitted 1, added 1 to your list'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'quick line');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, startsWith('task '));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, startsWith('task '));
    // Space ticks the card (here: its counts first).
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('submit-confirm')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, startsWith('task '));
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'task search');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    // A notification opens its task without looking it up, and the
    // reminder opens the quick line.
    cloud.notifications.addAll([
      {
        'id': 90,
        'user_id': 1,
        'kind': 'assigned',
        'report_id': callId,
        'actor_id': 1,
        'body': 'Call embassy',
        'created_at': '2026-11-09T08:00:00Z',
        'read': false,
      },
      {
        'id': 91,
        'user_id': 1,
        'kind': 'reminder',
        'report_id': null,
        'actor_id': null,
        'body': 'Nothing submitted yet today',
        'created_at': '2026-11-09T13:00:00Z',
        'read': false,
      },
    ]);
    await tester.tap(find.byKey(const ValueKey('report-bell')));
    await settle(tester);
    final lists = cloud.calls.where((c) => c == 'report_list').length;
    await tester.tap(find.byKey(const ValueKey('notification-90')));
    await settle(tester);
    expect(find.byKey(const ValueKey('task-id')), findsOneWidget);
    expect(cloud.calls.where((c) => c == 'report_list').length, lists);
    await tester.tap(find.text('Close').last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('notification-91')));
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'quick line');
    container.dispose();
  });

  testWidgets('daily reports: the list card keeps items until they are '
      'saved together', (tester) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    var container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1600),
    );
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    final quick = find.byKey(const ValueKey('quick-task'));
    await tester.tap(find.byKey(const ValueKey('draft-default-mode-todo')));
    await tester.pumpAndSettle();
    await tester.enterText(quick, 'Renewed passports 2 done');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.enterText(quick, 'Book the interview');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    // Kept on this device: still there after closing the app.
    await tester.pump(const Duration(seconds: 1));
    container.dispose();
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, boss, size: const Size(1600, 1600));
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    expect(find.byKey(const ValueKey('draft-summary')), findsOneWidget);
    expect(find.text('Submit 1, add 1'), findsOneWidget);

    // Clear, with Undo.
    await tester.tap(find.byKey(const ValueKey('draft-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('draft-summary')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('report-undo')));
    await tester.pumpAndSettle();
    expect(find.text('Submit 1, add 1'), findsOneWidget);

    // A blank title stops it; nothing is sent.
    final titles = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          (w.key is ValueKey<String>) &&
          (w.key! as ValueKey<String>).value.startsWith('draft-title-'),
    );
    expect(titles, findsNWidgets(2));
    await tester.enterText(titles.last, '');
    await tester.tap(find.byKey(const ValueKey('draft-save')));
    await settle(tester);
    expect(find.text('Give it a title.'), findsOneWidget);
    expect(cloud.reports, isEmpty);
    await tester.enterText(titles.last, 'Book the visa interview');
    await tester.pump();

    // The done one goes for review with its count, the other to the list
    // with a due day.
    final dueMenus = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('draft-due-'),
    );
    expect(dueMenus, findsOneWidget);
    await tester.tap(dueMenus);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Tomorrow').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('draft-save')));
    await settle(tester);
    final renewed = cloud.reports.values.firstWhere(
      (r) => r['description'] == 'Renewed passports',
    );
    expect(renewed['review'], 'submitted');
    expect(renewed['outputs'], {'visa_lodgements': 2});
    final book = cloud.reports.values.firstWhere(
      (r) => r['description'] == 'Book the visa interview',
    );
    expect(book['status'], 'to_do');
    expect(book['due_date'], '2026-11-10');
    expect(find.byKey(const ValueKey('draft-summary')), findsNothing);
    expect(find.byKey(const ValueKey('section-today')), findsOneWidget);
    container.dispose();

    // On a phone the item's menus wrap under its title.
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, boss, size: const Size(360, 780));
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    await tester.enterText(quick, 'Scan the offer letters tomorrow urgent');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('draft-save')), findsOneWidget);
    container.dispose();
  });

  testWidgets('daily reports: one tap finishes a task when there are no '
      'counts', (tester) async {
    cloud.addUser('ken', 'ken-pass-1', name: 'Ken');
    cloud.reports[5] = seedReport(5, 1, null, status: 'to_do');
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1400),
    );
    await signIn(tester, 'ken', 'ken-pass-1');
    await settle(tester);
    container.read(navTabProvider.notifier).set(AppTab.dailyReports);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('tick-5')));
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(cloud.reports[5]!['review'], 'submitted');
    expect(cloud.reports[5]!['report_date'], '2026-11-09');
    // Off the list, into Submitted today.
    expect(find.byKey(const ValueKey('tick-5')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('section-today')),
        matching: find.byKey(const ValueKey('report-5')),
      ),
      findsOneWidget,
    );
    // Undo: back on the list as Doing.
    await tester.tap(find.byKey(const ValueKey('report-undo')));
    await settle(tester);
    expect(cloud.reports[5]!['review'], 'none');
    expect(cloud.reports[5]!['status'], 'in_progress');
    expect(find.byKey(const ValueKey('report-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('section-today')), findsNothing);
    expect(
      cloud.comments.where(
        (c) => c['report_id'] == 5 && c['kind'] == 'submitted',
      ),
      isEmpty,
    );
    container.dispose();
  });

  testWidgets('overview: copy a reminder for who hasn’t submitted', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    cloud.addUser('joy', 'joy-pass-1', name: 'Joy', departmentId: 1);
    cloud.addUser('ian', 'ian-pass-1', name: 'Ian', departmentId: 2);
    cloud.addUser(
      'ruth',
      'ruth-pass-1',
      name: 'Ruth',
      reportAccess: ReportAccess.manager,
    );
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 2600),
    );
    await signIn(tester, 'ruth', 'ruth-pass-1');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('copy-reminder')));
    await tester.pumpAndSettle();
    expect(
      copied,
      anyOf(contains('Hi Ian and Joy'), contains('Hi Joy and Ian')),
    );
    expect(copied, contains('S&A Hub'));
    container.dispose();
  });

  // ------------------------------------------------ team: daily reports ---

  testWidgets('team: comments go both ways and notify', (tester) async {
    cloud.addUser('zawadi', 'zawadi-pass1', name: 'Zawadi', departmentId: 2);
    cloud.addUser(
      'grace',
      'grace-pass-1',
      name: 'Grace',
      departmentId: 2,
      reportAccess: ReportAccess.head,
    );
    seedReport(
      10,
      1,
      2,
      status: 'to_do',
      assignedBy: 2,
      description: 'Audit January files',
    );
    var container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 2600),
    );
    await signIn(tester, 'grace', 'grace-pass-1');
    await settle(tester);
    await openReportsTab(tester, 'Team');
    await tester.tap(find.byKey(const ValueKey('report-10')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('comment-field')),
      'Start with the Australian ones',
    );
    await tester.tap(find.byKey(const ValueKey('comment-send')));
    await settle(tester);
    expect(
      find.textContaining('Start with the Australian ones', findRichText: true),
      findsOneWidget,
    );
    expect(
      cloud.notifications.single,
      allOf(containsPair('user_id', 1), containsPair('kind', 'comment')),
    );
    container.dispose();

    // Zawadi replies; Grace hears.
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, admin, size: const Size(1600, 2600));
    await signIn(tester, 'zawadi', 'zawadi-pass1');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('report-10')));
    await settle(tester);
    expect(
      find.textContaining('Start with the Australian ones', findRichText: true),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('comment-field')),
      'Will do',
    );
    await tester.tap(find.byKey(const ValueKey('comment-send')));
    await settle(tester);
    expect(cloud.comments, hasLength(2));
    expect(
      cloud.notifications.last,
      allOf(containsPair('user_id', 2), containsPair('kind', 'comment')),
    );
    container.dispose();
  });

  test('daily reports: the model reads the server’s tasks', () {
    final t = ActivityReport.fromJson({
      'id': 42,
      'user_id': 1,
      'user_name': 'Amina',
      'department_id': 2,
      'report_date': '2026-11-09',
      'description': 'Lodged visas',
      'details': 'Three files',
      'outputs': {'visa_lodgements': 3},
      'status': 'done',
      'urgency': 'urgent',
      'review': 'returned',
      'submitted_at': '2026-11-09T11:30:00Z',
      'last_review_note': 'Add the receipts',
      'assigned_by': 2,
      'assigned_by_name': 'Grace',
    });
    expect(t.ref, '#42');
    expect(t.urgency, TaskUrgency.urgent);
    expect(t.review, ReviewState.returned);
    expect(t.isOpen, isTrue); // returned work is open again
    expect(t.isSubmitted, isFalse);
    expect(t.submittedAt, isNotNull);
    expect(t.lastReviewNote, 'Add the receipts');
    final save = t.toSaveJson(submit: true, note: 'Done now');
    expect(save['submit'], true);
    expect(save['note'], 'Done now');
    expect(save['urgency'], 'urgent');
    expect(save['status'], 'done');
    // Unknown codes from a newer server don't break older screens.
    final odd = ActivityReport.fromJson({
      'description': 'x',
      'status': 'something_new',
      'urgency': 'extreme',
      'review': 'later',
    });
    expect(odd.status, ReportStatus.toDo);
    expect(odd.urgency, TaskUrgency.normal);
    expect(odd.review, ReviewState.none);
    // Every urgency has its own colour.
    expect({
      for (final u in TaskUrgency.values) u.color(Brightness.light),
    }, hasLength(TaskUrgency.values.length));
  });
}

List<String> reportChangesFor(FakeCloud cloud, int id) => [
  for (final c in cloud.reportChanges)
    if (c['report_id'] == id) c['action'] as String,
];
