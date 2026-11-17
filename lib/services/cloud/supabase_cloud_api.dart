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

  static const _codes = {
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
    'too_many_items',
    'bad_request',
    'not_submitted',
    'blocker_required',
    'bad_urgency',
    'bad_status',
    'already_submitted',
    'comment_required',
    'bad_decision',
    'title_required',
    'accounts_only',
    'airtable_token_rejected',
    'no_airtable_token',
    'airtable_not_found',
    'airtable_limit',
    'airtable_budget',
    'airtable_empty',
    'airtable_too_many_pages',
  };

  /// How long one call may take before it counts as no connection. The
  /// full download gets longer (it is the biggest answer).
  static const _timeout = Duration(seconds: 30);
  static const _longTimeout = Duration(seconds: 90);
  static const _long = {
    'sync_read',
    'sync_push',
    'admin_backup',
    'admin_restore_online',
    'airtable_sync_now',
  };

  Future<T> _call<T>(String fn, [Map<String, Object?>? params]) async {
    try {
      final reply = await _client
          .rpc(fn, params: params)
          .timeout(_long.contains(fn) ? _longTimeout : _timeout);
      return reply as T;
    } on TypeError catch (e) {
      throw CloudException('other', 'Unexpected answer from $fn: $e');
    } on PostgrestException catch (e) {
      // The function isn't there: the online database hasn't had this
      // version's update (supabase/migrations) applied yet.
      if (e.code == 'PGRST202') throw CloudException('needs_update', e.message);
      throw CloudException(codeOf(e.message), e.message);
    }
  }

  /// Reads an answer of an unexpected shape as a refusal ("other"), not a
  /// crash.
  static R _shape<R>(String fn, R Function() read) {
    try {
      return read();
    } on TypeError catch (e) {
      throw CloudException('other', 'Unexpected answer from $fn: $e');
    }
  }

  /// The refusal code in a server message. The server raises its codes as
  /// the whole message ("not_allowed", or "has_reports:3"), so only an
  /// exact code at the start counts: a database error that merely contains
  /// a code word ("table is locked") is "other", never mistaken for a
  /// refusal (and never signs anyone out).
  static String codeOf(String message) {
    final m = RegExp(r'^([a-z][a-z0-9_]*)(?::|$)').firstMatch(message.trim());
    final word = m?.group(1);
    if (word == null) return 'other';
    if (word == 'update_required') return 'needs_update';
    return _codes.contains(word) ? word : 'other';
  }

  @override
  Future<Map<String, List<Map<String, Object?>>>> snapshot(String token) async {
    final data = await _call<Map<String, dynamic>>('sync_read', {
      'p_token': token,
    });
    return _shape(
      'sync_read',
      () => {
        for (final MapEntry(:key, :value) in data.entries)
          key: [
            for (final row in value as List)
              Map<String, Object?>.from(row as Map),
          ],
      },
    );
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
      _token('admin_login', {'p_password': password}, 'wrong_password');

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
  Future<String> recover(String code, String newPassword) => _token(
    'admin_recover',
    {'p_code': code, 'p_new': newPassword},
    'wrong_recovery_code',
  );

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
  Future<String> profileLogin(String role, String password) => _token(
    'profile_login',
    {'p_role': role, 'p_password': password},
    'wrong_password',
  );

  /// A sign-in that answers NULL for a wrong password or code: the server
  /// counts wrong tries, and a raised error would undo that count.
  Future<String> _token(
    String fn,
    Map<String, Object?> params,
    String wrongCode,
  ) async {
    final t = await _call<String?>(fn, params);
    if (t == null || t.isEmpty) throw CloudException(wrongCode, wrongCode);
    return t;
  }

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
    return _shape(
      'sign-in',
      () => UserSignIn(
        data['token'] as String,
        AppUser.fromJson(Map<String, Object?>.from(data['user'] as Map)),
      ),
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
  Future<AppUser> userSession(String token) async {
    final data = await _call<Map<String, dynamic>>('user_session', {
      'p_token': token,
    });
    return _shape(
      'user_session',
      () => AppUser.fromJson(Map<String, Object?>.from(data)),
    );
  }

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
    return _shape(
      'admin_list_users',
      () => [
        for (final u in data)
          AppUser.fromJson(Map<String, Object?>.from(u as Map)),
      ],
    );
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
    _channel = null;
    _client.dispose();
    // The streams stay open: a late listener gets nothing rather than a
    // StateError from a closed controller.
  }
}
