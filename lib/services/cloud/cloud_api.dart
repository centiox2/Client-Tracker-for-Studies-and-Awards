/// What the app needs from the online database. The real one talks to
/// Supabase ([SupabaseCloudApi]); tests use an in-memory fake.
abstract class CloudApi {
  /// Every synced table's rows, keyed by table name.
  Future<Map<String, List<Map<String, Object?>>>> snapshot();

  /// Applies one batch of local changes (needs an admin token):
  /// `{"deletes": {table: [keys]}, "upserts": {table: [rows]}}`.
  Future<void> push(String token, Map<String, Object?> payload);

  /// 'claimed' once an admin password exists online, else 'unclaimed'.
  Future<String> adminStatus();

  /// First admin sign-in anywhere: makes [password] the online password.
  /// Returns a token for pushing changes.
  Future<String> claim(String password);

  /// Checks [password]; returns a token for pushing changes.
  Future<String> login(String password);

  Future<void> setPassword(String token, String newPassword);

  /// Makes a one-time recovery code for a forgotten password (signed-in
  /// admins only). Only its hash is stored online; returns the code.
  Future<String> createRecoveryCode(String token);

  /// Whether a recovery code has been made (and not used yet).
  Future<bool> hasRecoveryCode(String token);

  /// Sets a new password with a recovery code; the code then stops
  /// working and every device must sign in again. Returns a token.
  Future<String> recover(String code, String newPassword);

  /// Live changes made by any device, as they happen.
  Stream<CloudChange> changes();

  /// Whether the live connection is up (true) or down (false).
  Stream<bool> connection();

  void dispose();
}

/// One row changed online.
class CloudChange {
  const CloudChange({
    required this.table,
    required this.deleted,
    required this.row,
  });

  final String table;
  final bool deleted;

  /// The new row, or (for a delete) at least its primary key.
  final Map<String, Object?> row;
}

/// A refusal from the online database, with a short [code]:
/// wrong_password, not_signed_in, already_claimed, unclaimed,
/// wrong_recovery_code, password_too_short, or other.
class CloudException implements Exception {
  CloudException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code: $detail';
}
