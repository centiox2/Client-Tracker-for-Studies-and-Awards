import '../../models/app_user.dart';

/// What the app needs from the online database. The real one talks to
/// Supabase ([SupabaseCloudApi]); tests use an in-memory fake.
abstract class CloudApi {
  /// Every synced table's rows, keyed by table name, read with a profile's
  /// [token]. Revenue comes back empty for profiles that may not see it.
  Future<Map<String, List<Map<String, Object?>>>> snapshot(String token);

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

  /// Which of the other profiles (admin_team, director, team) have a
  /// password: {"admin_team": true, ...}.
  Future<Map<String, bool>> profileStatus();

  /// When each profile's password last changed: {"director": "...", ...}.
  Future<Map<String, String>> profileVersions();

  /// Opens a profile with its password (any password for an open one).
  /// Returns the profile's token, for reading (and, for the admin team,
  /// sending changes).
  Future<String> profileLogin(String role, String password);

  /// The admin sets a profile's password; '' leaves it open.
  Future<void> setProfilePassword(String token, String role, String password);

  // ---- Personal accounts ------------------------------------------------

  /// 'empty' until the first account exists (a brand-new online database),
  /// then 'ready'.
  Future<String> usersStatus();

  /// A brand-new online database: creates the first account, an admin, and
  /// signs it in.
  Future<UserSignIn> userSetup(
    String username,
    String fullName,
    String password,
  );

  /// Signs in. Throws [CloudException] wrong_password (also for an unknown
  /// username), locked or deactivated.
  Future<UserSignIn> userLogin(String username, String password, bool remember);

  /// The signed-in user's latest details; also keeps the sign-in going
  /// (another 30 days, or a day without "Remember me"). Throws
  /// not_signed_in when it has ended.
  Future<AppUser> userSession(String token);

  Future<void> userLogout(String token);

  /// The user's own new password (needs the current one).
  Future<void> userChangePassword(String token, String current, String next);

  /// Admin only: every account.
  Future<List<AppUser>> adminListUsers(String token);

  /// Admin only: creates (no id; [password] is the temporary one) or
  /// changes an account.
  Future<AppUser> adminSaveUser(
    String token,
    Map<String, Object?> user, {
    String? password,
  });

  /// Admin only: a temporary password for a user who forgot theirs.
  Future<void> adminResetPassword(String token, int userId, String password);

  /// Calls one of the online database's functions with [params] and
  /// returns its JSON result (daily reports use this; they are read and
  /// written online only). Throws [CloudException] on a refusal.
  Future<Object?> callFunction(String name, Map<String, Object?> params);

  /// A signal each time any device changes the data (no data in it: the
  /// latest is then read with [snapshot]).
  Stream<CloudChange> changes();

  /// Whether the live connection is up (true) or down (false).
  Stream<bool> connection();

  void dispose();
}

/// A successful sign-in: the token the app reads (and writes) with, and
/// who signed in.
class UserSignIn {
  const UserSignIn(this.token, this.user);

  final String token;
  final AppUser user;
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
/// wrong_recovery_code, password_too_short, locked, deactivated,
/// bad_username, username_taken, last_admin, own_account, same_password,
/// or other.
class CloudException implements Exception {
  CloudException(this.code, [this.detail]);

  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code: $detail';
}
