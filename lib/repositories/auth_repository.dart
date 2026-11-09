import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../database/database.dart';
import '../models/app_user.dart';
import '../models/user_role.dart';

/// The admin password that guards the workspace (data entry and editing).
/// Reports are open to anyone using the app without signing in.
///
/// This gates the app on a shared computer; it is not network security —
/// anyone with access to the database file can still read the client counts.
/// The password is never stored, only a salted PBKDF2-HMAC-SHA256 hash, in
/// the `app_accounts` row with role 'admin'.
class AuthRepository {
  AuthRepository(this._db);

  final AppDatabase _db;

  /// PBKDF2 rounds. Lowered in tests to keep them fast.
  static int iterations = 20000;

  static const int minPasswordLength = 4;

  bool get hasAdminPassword => _db.raw
      .select("SELECT 1 FROM app_accounts WHERE role = 'admin';")
      .isNotEmpty;

  /// Creates or replaces the admin password.
  void setAdminPassword(String password) {
    if (password.length < minPasswordLength) {
      throw ArgumentError(
        'Password must be at least $minPasswordLength characters.',
      );
    }
    final salt = _randomSalt();
    _db.raw.execute(
      'INSERT INTO app_accounts (role, password_hash, salt, updated_at) '
      "VALUES ('admin', ?, ?, ?) "
      'ON CONFLICT(role) DO UPDATE SET password_hash = excluded.password_hash, '
      'salt = excluded.salt, updated_at = excluded.updated_at;',
      [
        _hash(password, salt),
        base64Encode(salt),
        DateTime.now().toIso8601String(),
      ],
    );
  }

  bool verifyAdmin(String password) {
    final rows = _db.raw.select(
      "SELECT password_hash, salt FROM app_accounts WHERE role = 'admin';",
    );
    if (rows.isEmpty) return false;
    final salt = base64Decode(rows.first['salt']! as String);
    final expected = rows.first['password_hash']! as String;
    return _constantTimeEquals(_hash(password, salt), expected);
  }

  // ---- The other profiles (Admin team, Director, Team) -------------------

  /// Whether [role] needs a password. Unknown (never set here or seen
  /// online) counts as open.
  bool isLocked(UserRole role) => _db.raw.select(
    'SELECT 1 FROM profile_passwords WHERE role = ? AND locked = 1;',
    [role.serverName],
  ).isNotEmpty;

  /// Sets [role]'s password; empty leaves the profile open.
  void setProfilePassword(UserRole role, String password) {
    if (password.isEmpty) {
      _putProfile(role, locked: false);
      return;
    }
    if (password.length < minPasswordLength) {
      throw ArgumentError(
        'Password must be at least $minPasswordLength characters.',
      );
    }
    final salt = _randomSalt();
    _putProfile(
      role,
      locked: true,
      hash: _hash(password, salt),
      salt: base64Encode(salt),
    );
  }

  /// What the online database says: locked or open. A lock without a known
  /// password here keeps any hash already stored (the same password).
  void markProfile(UserRole role, {required bool locked}) {
    if (!locked) {
      if (isLocked(role)) _putProfile(role, locked: false);
      return;
    }
    if (isLocked(role)) return;
    _putProfile(role, locked: true);
  }

  /// Checks [password] for [role] on this device: true or false, or null
  /// when it can't be checked here (locked online, never opened here).
  bool? verifyProfile(UserRole role, String password) {
    final rows = _db.raw.select(
      'SELECT locked, password_hash, salt FROM profile_passwords '
      'WHERE role = ?;',
      [role.serverName],
    );
    if (rows.isEmpty || rows.first['locked'] != 1) return true;
    final hash = rows.first['password_hash'] as String?;
    final salt = rows.first['salt'] as String?;
    if (hash == null || salt == null) return null;
    return _constantTimeEquals(_hash(password, base64Decode(salt)), hash);
  }

  // ---- Keep me signed in on this device ----------------------------------

  /// The profile this device opens straight into, if someone chose "Keep
  /// me signed in" (the admin is never kept).
  UserRole? get rememberedProfile {
    final rows = _db.raw.select(
      'SELECT role FROM profile_passwords WHERE stay_signed_in = 1 LIMIT 1;',
    );
    if (rows.isEmpty) return null;
    final name = rows.first['role'];
    return UserRole.others.where((r) => r.serverName == name).firstOrNull;
  }

  /// Opens [role] straight away on this device from now on. [version]: the
  /// password's online version, if known.
  void rememberProfile(UserRole role, {String? version}) {
    forgetProfile();
    _db.raw.execute(
      'INSERT INTO profile_passwords (role, locked, updated_at, '
      'stay_signed_in, version) VALUES (?, 0, ?, 1, ?) '
      'ON CONFLICT(role) DO UPDATE SET stay_signed_in = 1, '
      'version = excluded.version;',
      [role.serverName, DateTime.now().toIso8601String(), version],
    );
  }

  /// Back to the profile screen at launch.
  void forgetProfile() =>
      _db.raw.execute('UPDATE profile_passwords SET stay_signed_in = 0;');

  /// The password version kept with "Keep me signed in" (null: unknown).
  String? rememberedVersion(UserRole role) {
    final rows = _db.raw.select(
      'SELECT version FROM profile_passwords WHERE role = ?;',
      [role.serverName],
    );
    return rows.isEmpty ? null : rows.first['version'] as String?;
  }

  void setRememberedVersion(UserRole role, String? version) => _db.raw.execute(
    'UPDATE profile_passwords SET version = ? WHERE role = ?;',
    [version, role.serverName],
  );

  void _putProfile(
    UserRole role, {
    required bool locked,
    String? hash,
    String? salt,
  }) {
    _db.raw.execute(
      'INSERT INTO profile_passwords (role, locked, password_hash, salt, '
      'updated_at) VALUES (?, ?, ?, ?, ?) '
      // A new password (or none) ends "Keep me signed in".
      'ON CONFLICT(role) DO UPDATE SET locked = excluded.locked, '
      'password_hash = excluded.password_hash, salt = excluded.salt, '
      'updated_at = excluded.updated_at, stay_signed_in = 0, version = NULL;',
      [
        role.serverName,
        locked ? 1 : 0,
        hash,
        salt,
        DateTime.now().toIso8601String(),
      ],
    );
  }

  // ---- Personal accounts on this device ------------------------------------

  /// The account kept signed in here ("Remember me"), with its online
  /// token; null when nobody is.
  ({AppUser user, String token})? get rememberedUser {
    final rows = _db.raw.select(
      'SELECT user_json, token FROM user_signins '
      'WHERE remembered = 1 AND token IS NOT NULL LIMIT 1;',
    );
    if (rows.isEmpty) return null;
    try {
      final user = AppUser.fromJson(
        (jsonDecode(rows.first['user_json']! as String) as Map)
            .cast<String, Object?>(),
      );
      return (user: user, token: rows.first['token']! as String);
    } catch (_) {
      return null;
    }
  }

  /// Notes a successful sign-in on this device: the user's details and a
  /// hash of [password] (so they can sign in here without internet), and,
  /// with [remember], the online [token] to open straight in next time.
  /// Only one account is kept signed in at a time.
  void saveSignIn(
    AppUser user,
    String password, {
    required String? token,
    required bool remember,
  }) {
    final salt = _randomSalt();
    _db.transaction(() {
      _db.raw.execute('UPDATE user_signins SET remembered = 0, token = NULL;');
      _db.raw.execute(
        'INSERT INTO user_signins (username, user_json, password_hash, salt, '
        'token, remembered, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(username) DO UPDATE SET user_json = excluded.user_json, '
        'password_hash = excluded.password_hash, salt = excluded.salt, '
        'token = excluded.token, remembered = excluded.remembered, '
        'updated_at = excluded.updated_at;',
        [
          user.username,
          jsonEncode(user.toJson()),
          _hash(password, salt),
          base64Encode(salt),
          remember ? token : null,
          remember && token != null ? 1 : 0,
          DateTime.now().toIso8601String(),
        ],
      );
    });
  }

  /// The user's latest details (role, name…) from the online database.
  void updateUser(AppUser user) => _db.raw.execute(
    'UPDATE user_signins SET user_json = ? WHERE username = ?;',
    [jsonEncode(user.toJson()), user.username],
  );

  /// A new online token for the account kept signed in.
  void updateToken(String username, String token) => _db.raw.execute(
    'UPDATE user_signins SET token = ? WHERE username = ? AND remembered = 1;',
    [token, username],
  );

  /// Nobody is kept signed in here any more.
  void forgetSignIn() =>
      _db.raw.execute('UPDATE user_signins SET remembered = 0, token = NULL;');

  /// Forgets [username] on this device altogether (its password changed
  /// or the account was switched off), so it can't sign in offline.
  void forgetUser(String username) => _db.raw.execute(
    'DELETE FROM user_signins WHERE username = ?;',
    [username.trim().toLowerCase()],
  );

  /// Without internet: the account, if [username] signed in on this device
  /// before with this [password]; null otherwise.
  AppUser? verifyOffline(String username, String password) {
    final rows = _db.raw.select(
      'SELECT user_json, password_hash, salt FROM user_signins '
      'WHERE username = ?;',
      [username.trim().toLowerCase()],
    );
    if (rows.isEmpty) return null;
    final hash = rows.first['password_hash'] as String?;
    final salt = rows.first['salt'] as String?;
    if (hash == null || salt == null) return null;
    if (!_constantTimeEquals(_hash(password, base64Decode(salt)), hash)) {
      return null;
    }
    final user = AppUser.fromJson(
      (jsonDecode(rows.first['user_json']! as String) as Map)
          .cast<String, Object?>(),
    );
    return user.active ? user : null;
  }

  /// Whether [username] has signed in on this device before.
  bool knowsUser(String username) => _db.raw.select(
    'SELECT 1 FROM user_signins WHERE username = ?;',
    [username.trim().toLowerCase()],
  ).isNotEmpty;

  static Uint8List _randomSalt() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
  }

  /// PBKDF2-HMAC-SHA256, one 32-byte block (all we need for a 256-bit key).
  static String _hash(String password, List<int> salt) {
    final hmac = Hmac(sha256, utf8.encode(password));
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return base64Encode(out);
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
