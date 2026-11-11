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

  String _day(DateTime d) => dateKey(d);

  final comments = <Map<String, Object?>>[];

  Map<String, Object?> _reportJson(Map<String, Object?> r) => {
    ...r,
    'user_name': users[r['user_id']]!.fullName,
    'assigned_by_name': users[r['assigned_by']]?.fullName,
    'comment_count': comments.where((c) => c['report_id'] == r['id']).length,
    'department_name': departments.firstWhere(
      (d) => d['id'] == r['department_id'],
    )['name'],
  };

  @override
  Future<Object?> callFunction(String name, Map<String, Object?> p) async {
    _online();
    calls.add(name);
    final uid = _tokenUser(p['p_token'] as String);
    final me = users[uid]!;
    final today = reportsToday;
    List<Map<String, Object?>> visible() => [
      for (final r in reports.values)
        if (_canSee(uid, r['user_id'] as int, r['department_id'] as int?)) r,
    ];
    switch (name) {
      case 'reports_meta':
        final scope = _scope(uid);
        return {
          'today': _day(today),
          'me': {...me.toJson(), 'scope': scope},
          'departments': departments,
          'people': [
            for (final u in users.values)
              if (scope == 'all' ||
                  u.id == uid ||
                  (scope == 'department' && u.departmentId == me.departmentId))
                {
                  'id': u.id,
                  'full_name': u.fullName,
                  'department_id': u.departmentId,
                  'active': u.active,
                },
          ],
        };
      case 'report_list':
        final f = (p['p_filter'] as Map).cast<String, Object?>();
        final rows = visible().where((r) {
          final d = r['report_date'] as String;
          final open = r['status'] != 'completed';
          return (f['from'] == null || d.compareTo(f['from'] as String) >= 0) &&
              (f['to'] == null || d.compareTo(f['to'] as String) <= 0) &&
              (f['user_id'] == null || r['user_id'] == f['user_id']) &&
              (f['department_id'] == null ||
                  r['department_id'] == f['department_id']) &&
              (f['statuses'] == null ||
                  (f['statuses'] as List).contains(r['status'])) &&
              (f['open_only'] != true || open) &&
              (f['overdue_only'] != true ||
                  (open &&
                      r['due_date'] != null &&
                      (r['due_date'] as String).compareTo(_day(today)) < 0)) &&
              (f['search'] == null ||
                  '${r['description']} ${r['reference']}'
                      .toLowerCase()
                      .contains((f['search'] as String).toLowerCase()));
        }).toList()..sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
        return [for (final r in rows) _reportJson(r)];
      case 'report_summary':
        final from = p['p_from'] as String;
        final to = p['p_to'] as String;
        final deptFilter = p['p_department'] as int?;
        final userFilter = p['p_user'] as int?;
        final inRange = visible().where((r) {
          final d = r['report_date'] as String;
          return d.compareTo(from) >= 0 &&
              d.compareTo(to) <= 0 &&
              (deptFilter == null || r['department_id'] == deptFilter) &&
              (userFilter == null || r['user_id'] == userFilter);
        }).toList();
        final status = <String, int>{};
        for (final r in inRange) {
          status[r['status'] as String] =
              (status[r['status'] as String] ?? 0) + 1;
        }
        final scope = _scope(uid);
        final open = visible().where(
          (r) =>
              r['status'] != 'completed' &&
              (userFilter == null || r['user_id'] == userFilter),
        );
        return {
          'from': from,
          'to': to,
          'today': _day(today),
          'working_days': 1,
          'status': status,
          'departments': [
            for (final d in departments)
              if ((deptFilter == null || d['id'] == deptFilter) &&
                  (scope == 'all' || d['id'] == me.departmentId))
                () {
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
                        .where((r) => r['status'] == 'completed')
                        .length,
                    'open': rs.where((r) => r['status'] != 'completed').length,
                    'blocked': rs.where((r) => r['status'] == 'blocked').length,
                    'escalated': rs
                        .where((r) => r['status'] == 'escalated')
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
                  'days_submitted': inRange
                      .where((r) => r['user_id'] == u.id)
                      .map((r) => r['report_date'])
                      .toSet()
                      .length,
                  'entries': inRange.where((r) => r['user_id'] == u.id).length,
                  'submitted_today': reports.values.any(
                    (r) =>
                        r['user_id'] == u.id && r['report_date'] == _day(today),
                  ),
                },
          ],
          'overdue': [
            for (final r in open)
              if (r['due_date'] != null &&
                  (r['due_date'] as String).compareTo(_day(today)) < 0)
                _reportJson(r),
          ],
          'attention': [
            for (final r in open)
              if (r['status'] == 'blocked' || r['status'] == 'escalated')
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
        if (before != null &&
            before['user_id'] != uid &&
            before['assigned_by'] != uid &&
            me.role != UserRole.admin) {
          throw CloudException('not_allowed');
        }
        // Assigning a task to someone else.
        final forId = before == null ? r['user_id'] as int? : null;
        final owner = forId == null || forId == uid ? null : users[forId];
        if (forId != null && forId != uid) {
          if (owner == null) throw CloudException('unknown_user');
          if (_scope(uid) == 'own' ||
              !_canSee(uid, owner.id, owner.departmentId)) {
            throw CloudException('not_allowed');
          }
          if (r['due_date'] == null) {
            throw CloudException('due_date_required');
          }
        }
        final dept =
            before?['department_id'] ?? owner?.departmentId ?? me.departmentId;
        if (dept == null) throw CloudException('no_department');
        final date = r['report_date'] as String? ?? _day(today);
        if (date.compareTo(_day(today)) > 0) {
          throw CloudException('future_date');
        }
        final status = r['status'] as String? ?? 'completed';
        if (status != 'completed' && r['due_date'] == null) {
          throw CloudException('due_date_required');
        }
        if ('${r['description'] ?? ''}'.trim().isEmpty) {
          throw CloudException('description_required');
        }
        final keys = [
          for (final o
              in departments.firstWhere((d) => d['id'] == dept)['outputs']!
                  as List)
            (o as Map)['key'],
          // An edit keeps keys the report already had.
          ...((before?['outputs'] as Map?) ?? const {}).keys,
        ];
        final saved = <String, Object?>{
          'id': id ?? reports.length + 100,
          'user_id': before?['user_id'] ?? owner?.id ?? uid,
          'assigned_by': before?['assigned_by'] ?? (owner == null ? null : uid),
          'department_id': dept,
          'report_date': date,
          'description': '${r['description']}'.trim(),
          'reference': r['reference'] ?? '',
          'outputs': {
            for (final e in ((r['outputs'] as Map?) ?? {}).entries)
              if (keys.contains(e.key) && (e.value as int) > 0) e.key: e.value,
          },
          'status': status,
          'next_action': r['next_action'] ?? '',
          'blocker': r['blocker'] ?? '',
          'priority': r['priority'] ?? 'medium',
          'due_date': r['due_date'],
          'created_at': '2026-11-09T08:00:00Z',
          'updated_at': '2026-11-09T08:00:00Z',
        };
        reports[saved['id'] as int] = saved;
        reportChanges.add({
          'report_id': saved['id'],
          'action': before == null ? 'created' : 'edited',
          'changed_by': me.fullName,
          'changed_at': '2026-11-09T08:00:00Z',
        });
        return _reportJson(saved);
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
          'changed_at': '2026-11-09T09:00:00Z',
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
        final visible =
            r != null &&
            _canSee(uid, r['user_id'] as int, r['department_id'] as int?);
        if (name == 'report_comment_add') {
          if (!visible) throw CloudException('not_allowed');
          comments.add({
            'id': comments.length + 1,
            'report_id': rid,
            'user_id': uid,
            'user_name': me.fullName,
            'body': (p['p_body'] as String).trim(),
            'created_at': '2026-11-09T09:30:00Z',
          });
        }
        if (!visible) return [];
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
    int dept, {
    String status = 'completed',
    String date = '2026-11-09',
    String? due,
    Map<String, int> outputs = const {},
    String description = 'Work done',
  }) => cloud.reports[id] = {
    'id': id,
    'user_id': userId,
    'department_id': dept,
    'report_date': date,
    'description': description,
    'reference': '',
    'outputs': outputs,
    'status': status,
    'next_action': '',
    'blocker': status == 'blocked' ? 'Clinic closed' : '',
    'priority': 'medium',
    'due_date': due,
    'created_at': '2026-11-09T08:00:00Z',
    'updated_at': '2026-11-09T08:00:00Z',
  };

  testWidgets('daily reports: an employee records their day', (tester) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 1400),
    );
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    expect(container.read(navTabProvider), AppTab.dailyReports);
    expect(find.text('What I did today'), findsOneWidget);
    // Employees see only their own: no Overview.
    expect(find.byKey(const ValueKey('reports-tab')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Lodged visa applications',
    );
    await tester.enterText(
      find.byKey(const ValueKey('output-visa_lodgements')),
      '3',
    );
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    expect(cloud.reports.values.single['outputs'], {'visa_lodgements': 3});
    expect(cloud.reports.values.single['user_id'], 1);
    expect(find.text('Lodged visa applications'), findsOneWidget);
    expect(find.textContaining('Visa lodgements 3'), findsWidgets);

    // Something still open needs a due date.
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Waiting for medical results',
    );
    await tester.tap(find.byKey(const ValueKey('report-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Blocked').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('report-error')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('report-due')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    final blocked = cloud.reports.values.firstWhere(
      (r) => r['status'] == 'blocked',
    );
    expect(blocked['due_date'], '2026-11-10');
    expect(find.text('My open items'), findsOneWidget);

    // Done later: one tap.
    await tester.tap(find.text('Mark done'));
    await settle(tester);
    expect(cloud.reports[blocked['id']]!['status'], 'completed');
    container.dispose();
  });

  testWidgets('daily reports: the manager’s overview, the head’s department', (
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
      date: '2026-11-07',
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
    // No department of her own: straight to the Overview.
    expect(find.text('Submission compliance'), findsOneWidget);
    expect(find.text('1 of 3 today'), findsOneWidget);
    expect(find.textContaining('Otieno · Admissions'), findsWidgets);
    expect(find.text('Waiting on clinic'), findsOneWidget); // needs attention
    expect(find.textContaining('Applications submitted 4'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('stat-overdue')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    container.dispose();

    // The Visa head sees Visa only.
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, admin, size: const Size(1600, 2600));
    await signIn(tester, 'grace', 'grace-pass-1');
    await settle(tester);
    await tester.tap(find.text('Overview'));
    await settle(tester);
    expect(find.text('Visa Processing & Documentation'), findsWidgets);
    expect(find.text('Admissions & Applications'), findsNothing);
    expect(find.text('Submitted applications'), findsNothing);
    expect(find.text('Waiting on clinic'), findsWidgets);
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
      'status': {'completed': 1, 'blocked': 1},
      'departments': [
        {
          'id': 1,
          'name': 'Admissions & Applications',
          'activities': 2,
          'completed': 1,
          'open': 1,
          'blocked': 1,
          'escalated': 0,
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
      'status': 'completed',
      'priority': 'high',
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
    expect(entries.rows[1][1]?.value.toString(), 'Otieno');

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
      status: 'escalated',
      due: '2026-11-08',
      description: 'A long description of a visa case that is escalated',
    );
    const phone = Size(360, 780);
    var container = await pumpAccounts(tester, boss, size: phone);
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('report-status')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    container.dispose();

    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, admin, size: phone);
    await signIn(tester, 'ruth', 'ruth-pass-1');
    await settle(tester);
    await tester.tap(find.text('Overview'));
    await settle(tester);
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
    expect(find.textContaining('Monday, 9 November 2026'), findsOneWidget);

    // Left open overnight: the app notices the new day (data version).
    cloud.reportsToday = DateTime(2026, 11, 10);
    container.read(dataVersionProvider.notifier).bump();
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(find.textContaining('Tuesday, 10 November 2026'), findsOneWidget);

    // A new entry now goes on the new day.
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Next day work',
    );
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    expect(cloud.reports.values.single['report_date'], '2026-11-10');
    container.dispose();
  });

  testWidgets('daily reports: filters stay in step; one person’s figures', (
    tester,
  ) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    cloud.addUser('otieno', 'otieno-pass-1', name: 'Otieno', departmentId: 1);
    cloud.addUser(
      'ruth',
      'ruth-pass-1',
      name: 'Ruth',
      reportAccess: ReportAccess.manager,
    );
    seedReport(10, 1, 2, status: 'blocked', due: '2026-11-08');
    seedReport(11, 2, 1);
    seedReport(12, 2, 1);
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 2600),
    );
    await signIn(tester, 'ruth', 'ruth-pass-1');
    await settle(tester);
    Finder stat(String value) => find.descendant(
      of: find.byKey(const ValueKey('stat-total')),
      matching: find.text(value),
    );
    expect(stat('3'), findsOneWidget);

    // Tapping a department row: the dropdown says so too.
    await tester.tap(find.text('Admissions & Applications').last);
    await settle(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('report-department')),
        matching: find.text('Admissions & Applications'),
      ),
      findsOneWidget,
    );
    expect(stat('2'), findsOneWidget);

    // Back to all, then one person: the figures are that person's.
    await tester.tap(find.byKey(const ValueKey('report-department')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All departments').last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('report-person')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Amina').last);
    await settle(tester);
    expect(stat('1'), findsOneWidget);
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
      status: 'pending',
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
    await tester.tap(find.text('Old style report').first);
    await tester.pumpAndSettle();
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

    // Add again today: a copy to start from.
    await tester.tap(find.text('Weekly visa audit'));
    await tester.pumpAndSettle();
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

    // Cancel after typing asks first.
    await tester.tap(find.byKey(const ValueKey('add-activity')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Half typed',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Half typed'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('discard-report')));
    await tester.pumpAndSettle();
    expect(find.text('Add activity').hitTestable(), findsOneWidget);
    expect(cloud.reports, hasLength(2));
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

  testWidgets('team: a head assigns a task; the person works it; comments', (
    tester,
  ) async {
    cloud.addUser('zawadi', 'zawadi-pass1', name: 'Zawadi', departmentId: 2);
    cloud.addUser(
      'grace',
      'grace-pass-1',
      name: 'Grace',
      departmentId: 2,
      reportAccess: ReportAccess.head,
    );
    var container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 2600),
    );
    await signIn(tester, 'grace', 'grace-pass-1');
    await settle(tester);
    await tester.tap(find.text('Overview'));
    await settle(tester);

    // Grace assigns Zawadi a task, due tomorrow (one tap).
    await tester.tap(find.byKey(const ValueKey('assign-task')));
    await tester.pumpAndSettle();
    expect(find.text('Assign a task'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('assign-person')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Zawadi ·').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('report-description')),
      'Audit January files',
    );
    await tester.tap(find.byKey(const ValueKey('due-Tomorrow')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('report-save')));
    await settle(tester);
    final task = cloud.reports.values.single;
    expect(task['user_id'], 1);
    expect(task['assigned_by'], 2);
    expect(task['status'], 'pending');
    expect(task['due_date'], '2026-11-10');

    // Grace asks a question on it.
    await tester.tap(find.text('Audit January files').first);
    await tester.pumpAndSettle();
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
    container.dispose();

    // Zawadi sees it among her open items, assigned by Grace, with the
    // comment, and moves it on in one tap.
    await tester.pumpWidget(const SizedBox());
    container = await pumpAccounts(tester, admin, size: const Size(1600, 2600));
    await signIn(tester, 'zawadi', 'zawadi-pass1');
    await settle(tester);
    expect(find.textContaining('Assigned by Grace'), findsWidgets);
    await tester.tap(find.byKey(ValueKey('status-menu-${task['id']}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('In progress').last);
    await settle(tester);
    expect(cloud.reports[task['id']]!['status'], 'in_progress');
    expect(cloud.reports[task['id']]!['assigned_by'], 2);

    // She replies.
    await tester.tap(find.text('Audit January files').first);
    await tester.pumpAndSettle();
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
    container.dispose();
  });

  testWidgets('team: My week adds up the person’s own week', (tester) async {
    cloud.addUser('amina', 'amina-pass-1', name: 'Amina', departmentId: 2);
    cloud.addUser('otieno', 'otieno-pass-1', name: 'Otieno', departmentId: 1);
    seedReport(10, 1, 2, date: '2026-11-09', outputs: {'visa_lodgements': 3});
    seedReport(11, 1, 2, date: '2026-11-09', outputs: {'visa_lodgements': 2});
    seedReport(12, 1, 2, status: 'pending', due: '2026-11-12');
    seedReport(13, 2, 1, date: '2026-11-09'); // someone else's
    seedReport(14, 1, 2, date: '2026-11-08'); // Sunday: last week
    final container = await pumpAccounts(
      tester,
      boss,
      size: const Size(1600, 2200),
    );
    await signIn(tester, 'amina', 'amina-pass-1');
    await settle(tester);
    final week = find.byKey(const ValueKey('my-week'));
    expect(week, findsOneWidget);
    // 9 Nov 2026 is a Monday: one working day so far and reported, 3
    // entries this week, 2 completed.
    expect(
      find.descendant(of: week, matching: find.text('1 of 1')),
      findsOneWidget,
    );
    expect(find.descendant(of: week, matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: week, matching: find.text('2')), findsOneWidget);
    expect(
      find.descendant(of: week, matching: find.text('Visa lodgements 5')),
      findsOneWidget,
    );
    container.dispose();
  });
}
