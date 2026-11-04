import 'dart:async';

import 'package:supabase/supabase.dart';

import '../../config/cloud_config.dart';
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
  ];

  Future<T> _call<T>(String fn, [Map<String, Object?>? params]) async {
    try {
      return await _client.rpc(fn, params: params) as T;
    } on PostgrestException catch (e) {
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

  @override
  void dispose() {
    final channel = _channel;
    if (channel != null) _client.removeChannel(channel);
    _client.dispose();
    _changes.close();
    _connection.close();
  }
}
