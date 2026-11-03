import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../database/database.dart';

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
