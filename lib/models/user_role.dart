/// Who is using the app, chosen on the profile screen at launch.
enum UserRole {
  /// Everything, including Settings and revenue (the admin portal).
  admin('Admin', 'admin'),

  /// Enters and edits client numbers, staff and history; no revenue.
  adminTeam('Admin team', 'admin_team'),

  /// Sees every figure, revenue included; changes nothing.
  director('Director', 'director'),

  /// Sees every figure except revenue; changes nothing.
  team('Team', 'team');

  const UserRole(this.label, this.serverName);

  final String label;

  /// The role the online database calls [name]; Team for anything unknown.
  static UserRole fromServerName(String name) => UserRole.values.firstWhere(
    (r) => r.serverName == name,
    orElse: () => UserRole.team,
  );

  /// What each role may do, in a few words (for the admin giving it).
  String get summary => switch (this) {
    UserRole.admin => 'Everything, including revenue, settings and accounts',
    UserRole.adminTeam => 'Enters and edits numbers; no revenue',
    UserRole.director => 'Sees everything, revenue included; changes nothing',
    UserRole.team => 'Sees everything except revenue; changes nothing',
  };

  /// The name the online database knows the profile by.
  final String serverName;

  /// Can enter and change client numbers, staff and history.
  bool get canEdit => this == admin || this == adminTeam;

  /// Can see revenue anywhere in the app.
  bool get seesRevenue => this == admin || this == director;

  bool get isAdmin => this == admin;

  /// The profiles whose password the admin sets (or leaves open).
  static const others = [adminTeam, director, team];
}
