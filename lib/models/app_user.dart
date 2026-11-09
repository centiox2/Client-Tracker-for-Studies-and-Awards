import 'daily_report.dart';
import 'user_role.dart';

/// One person's account: they sign in with [username] and their own
/// password. Accounts live in the online database; only an admin creates
/// them, resets passwords and gives out roles.
class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
    this.staffId,
    this.active = true,
    this.mustChange = false,
    this.lastSignIn,
    this.locked = false,
    this.departmentId,
    this.reportAccess = ReportAccess.employee,
  });

  final int id;
  final String username;
  final String fullName;
  final UserRole role;

  /// The staff member this account belongs to, if linked.
  final int? staffId;
  final bool active;

  /// Signed in with a temporary password: must choose their own first.
  final bool mustChange;
  final DateTime? lastSignIn;

  /// Too many wrong passwords: refused for a few minutes.
  final bool locked;

  /// Their department, for daily reports (null: none yet).
  final int? departmentId;

  /// What they see in daily reports: own, their department, or all.
  final ReportAccess reportAccess;

  factory AppUser.fromJson(Map<String, Object?> json) => AppUser(
    id: (json['id'] as num).toInt(),
    username: json['username'] as String,
    fullName: json['full_name'] as String,
    role: UserRole.fromServerName(json['role'] as String),
    staffId: (json['staff_id'] as num?)?.toInt(),
    active: json['active'] as bool? ?? true,
    mustChange: json['must_change'] as bool? ?? false,
    lastSignIn: DateTime.tryParse('${json['last_sign_in'] ?? ''}')?.toLocal(),
    locked: json['locked'] as bool? ?? false,
    departmentId: (json['department_id'] as num?)?.toInt(),
    reportAccess: ReportAccess.fromCode(json['report_access'] as String?),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'full_name': fullName,
    'role': role.serverName,
    'staff_id': staffId,
    'active': active,
    'must_change': mustChange,
    'last_sign_in': lastSignIn?.toUtc().toIso8601String(),
    'locked': locked,
    'department_id': departmentId,
    'report_access': reportAccess.code,
  };

  AppUser copyWith({bool? mustChange}) => AppUser(
    id: id,
    username: username,
    fullName: fullName,
    role: role,
    staffId: staffId,
    active: active,
    mustChange: mustChange ?? this.mustChange,
    lastSignIn: lastSignIn,
    locked: locked,
    departmentId: departmentId,
    reportAccess: reportAccess,
  );

  /// The rules the online database enforces: 3 to 32 characters, lower case
  /// letters, digits, dots, dashes and underscores, starting and ending
  /// with a letter or digit.
  static final usernamePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{1,30}[a-z0-9]$');

  static const minPasswordLength = 8;

  /// A sensible username from a person's name: "Mary Wanjiku" →
  /// "mary.wanjiku", "Director/Eve" → "director.eve". Adds 2, 3… when
  /// [taken] already has it.
  static String suggestUsername(
    String name, {
    Iterable<String> taken = const [],
  }) {
    const accents = {
      'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', //
      'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', //
      'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', //
      'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', //
      'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', //
      'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y',
    };
    final plain = [
      for (final ch in name.trim().toLowerCase().split('')) accents[ch] ?? ch,
    ].join();
    var base = plain
        .replaceAll(RegExp(r"['’]"), '')
        .replaceAll(RegExp('[^a-z0-9]+'), '.')
        .replaceAll(RegExp(r'^\.+|\.+$'), '');
    if (base.length > 28) {
      base = base.substring(0, 28).replaceAll(RegExp(r'\.+$'), '');
    }
    if (base.isEmpty) base = 'user';
    while (base.length < 3) {
      base = '${base}1';
    }
    final used = taken.toSet();
    if (!used.contains(base)) return base;
    for (var i = 2; ; i++) {
      final candidate = '$base$i';
      if (!used.contains(candidate)) return candidate;
    }
  }
}
