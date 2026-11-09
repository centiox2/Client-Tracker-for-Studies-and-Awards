import 'dart:async';

import 'package:supabase/supabase.dart';

import '../../config/cloud_config.dart';
import '../../models/app_user.dart';
import 'cloud_api.dart';

/// [CloudApi] on Supabase: database functions for reading, pushing and the
/// admin password, and Realtime for live changes.
class SupabaseCloudApi implements CloudApi {
  SupabaseCloudApi()
    : _client = SupabaseClient(CloudConfig.url, CloudConfig.publishableKey);

  final SupabaseClient _client;
  RealtimeChannel? _channel;
  final _changes = StreamController<CloudChange>.broadcast();
  final _connection = StreamController<bool>.broadcast();

  static const _codes = [
    'wrong_password',
    'not_signed_in',
    'already_claimed',
    'unclaimed',
    'password_too_short',
    'wrong_recovery_code',
    'not_allowed',
    'unknown_profile',
    'locked',
    'deactivated',
    'bad_username',
    'bad_name',
    'username_taken',
    'last_admin',
    'own_account',
    'same_password',
    'unknown_user',
    'use_accounts',
    'no_department',
    'future_date',
    'date_too_old',
    'due_date_required',
    'description_required',
    'unknown_report',
    'bad_outputs',
    'name_taken',
    'unknown_department',
    'bad_access',
    'has_reports',
  ];

  Future<T> _call<T>(String fn, [Map<String, Object?>? params]) async {
    try {
      return await _client.rpc(fn, params: params) as T;
    } on PostgrestException catch (e) {
      // The function isn't there: the online database hasn't had this
      // version's update (supabase/migrations) applied yet.
      if (e.code == 'PGRST202') throw CloudException('needs_update', e.message);
      final code = _codes.firstWhere(
        (c) => e.message.contains(c),
        orElse: () => 'other',
      );
      throw CloudException(code, e.message);
    }
  }

  @override
  Future<Map<String, List<Map<String, Object?>>>> snapshot(String token) async {
    final data = await _call<Map<String, dynamic>>('sync_read', {
      'p_token': token,
    });
    return {
      for (final MapEntry(:key, :value) in data.entries)
        key: [
          for (final row in value as List)
            Map<String, Object?>.from(row as Map),
        ],
    };
  }

  @override
  Future<void> push(String token, Map<String, Object?> payload) =>
      _call<dynamic>('sync_push', {'p_token': token, 'p_payload': payload});

  @override
  Future<String> adminStatus() => _call<String>('admin_status');

  @override
  Future<String> claim(String password) =>
      _call<String>('admin_claim', {'p_password': password});

  @override
  Future<String> login(String password) =>
      _call<String>('admin_login', {'p_password': password});

  @override
  Future<void> setPassword(String token, String newPassword) => _call<dynamic>(
    'admin_set_password',
    {'p_token': token, 'p_new': newPassword},
  );

  @override
  Stream<CloudChange> changes() {
    _channel ??= _client
        .channel('client-tracker')
        // Only "something changed" (sync_ping); the data itself is read
        // with a profile's token.
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'sync_ping',
          callback: (p) => _changes.add(
            CloudChange(
              table: p.table,
              deleted: p.eventType == PostgresChangeEvent.delete,
              row: Map<String, Object?>.from(
                p.eventType == PostgresChangeEvent.delete
                    ? p.oldRecord
                    : p.newRecord,
              ),
            ),
          ),
        )
        .subscribe((status, _) {
          _connection.add(status == RealtimeSubscribeStatus.subscribed);
        });
    return _changes.stream;
  }

  @override
  Stream<bool> connection() => _connection.stream;

  @override
  Future<String> createRecoveryCode(String token) =>
      _call<String>('admin_create_recovery_code', {'p_token': token});

  @override
  Future<bool> hasRecoveryCode(String token) =>
      _call<bool>('admin_has_recovery', {'p_token': token});

  @override
  Future<String> recover(String code, String newPassword) =>
      _call<String>('admin_recover', {'p_code': code, 'p_new': newPassword});

  @override
  Future<Map<String, bool>> profileStatus() async {
    final data = await _call<Map<String, dynamic>>('profile_status');
    return {for (final e in data.entries) e.key: e.value == true};
  }

  @override
  Future<Map<String, String>> profileVersions() async {
    final data = await _call<Map<String, dynamic>>('profile_versions');
    return {for (final e in data.entries) e.key: '${e.value}'};
  }

  @override
  Future<String> profileLogin(String role, String password) =>
      _call<String>('profile_login', {'p_role': role, 'p_password': password});

  @override
  Future<void> setProfilePassword(String token, String role, String password) =>
      _call<dynamic>('admin_set_profile_password', {
        'p_token': token,
        'p_role': role,
        'p_password': password,
      });

  // ---- Personal accounts ------------------------------------------------

  UserSignIn _signIn(Map<String, dynamic> data) {
    final error = data['error'];
    if (error is String) throw CloudException(error);
    return UserSignIn(
      data['token'] as String,
      AppUser.fromJson(Map<String, Object?>.from(data['user'] as Map)),
    );
  }

  @override
  Future<Object?> callFunction(String name, Map<String, Object?> params) =>
      _call<Object?>(name, params);

  @override
  Future<String> usersStatus() => _call<String>('users_status');

  @override
  Future<UserSignIn> userSetup(
    String username,
    String fullName,
    String password,
  ) async => _signIn(
    await _call<Map<String, dynamic>>('user_setup', {
      'p_username': username,
      'p_full_name': fullName,
      'p_password': password,
    }),
  );

  @override
  Future<UserSignIn> userLogin(
    String username,
    String password,
    bool remember,
  ) async => _signIn(
    await _call<Map<String, dynamic>>('user_login', {
      'p_username': username,
      'p_password': password,
      'p_remember': remember,
    }),
  );

  @override
  Future<AppUser> userSession(String token) async => AppUser.fromJson(
    Map<String, Object?>.from(
      await _call<Map<String, dynamic>>('user_session', {'p_token': token}),
    ),
  );

  @override
  Future<void> userLogout(String token) =>
      _call<dynamic>('user_logout', {'p_token': token});

  @override
  Future<void> userChangePassword(String token, String current, String next) =>
      _call<dynamic>('user_change_password', {
        'p_token': token,
        'p_current': current,
        'p_new': next,
      });

  @override
  Future<List<AppUser>> adminListUsers(String token) async {
    final data = await _call<List<dynamic>>('admin_list_users', {
      'p_token': token,
    });
    return [
      for (final u in data)
        AppUser.fromJson(Map<String, Object?>.from(u as Map)),
    ];
  }

  @override
  Future<AppUser> adminSaveUser(
    String token,
    Map<String, Object?> user, {
    String? password,
  }) async => AppUser.fromJson(
    Map<String, Object?>.from(
      await _call<Map<String, dynamic>>('admin_save_user', {
        'p_token': token,
        'p_user': {...user, 'password': ?password},
      }),
    ),
  );

  @override
  Future<void> adminResetPassword(String token, int userId, String password) =>
      _call<dynamic>('admin_reset_password', {
        'p_token': token,
        'p_user_id': userId,
        'p_password': password,
      });

  @override
  void dispose() {
    final channel = _channel;
    if (channel != null) _client.removeChannel(channel);
    _client.dispose();
    _changes.close();
    _connection.close();
  }
}
