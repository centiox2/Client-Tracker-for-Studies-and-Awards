import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../models/staff.dart';
import '../../services/cloud/cloud_api.dart';
import '../../services/daily_reports_service.dart';
import '../../state/app_state.dart';
import '../../state/cloud_sync.dart';
import '../../widgets/panels.dart';

/// Settings › Users (admins only): everyone's account. The admin adds
/// people with a temporary password, gives out roles, resets forgotten
/// passwords and switches accounts off when someone leaves.
class UsersSection extends ConsumerStatefulWidget {
  const UsersSection({super.key});

  @override
  ConsumerState<UsersSection> createState() => _UsersSectionState();
}

class _UsersSectionState extends ConsumerState<UsersSection> {
  List<AppUser>? _users;

  /// For each person's department (empty until loaded, or if daily
  /// reports aren't set up online yet).
  List<Department> _departments = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final users = await ref.read(cloudSyncProvider.notifier).listUsers();
      List<Department>? departments;
      try {
        departments = (await ref.read(dailyReportsProvider).meta()).departments;
      } catch (_) {
        // Daily reports not set up online yet: accounts still work.
      }
      if (!mounted) return;
      setState(() {
        _users = users;
        if (departments != null) _departments = departments;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeAccountError(e);
      });
    }
  }

  Future<void> _edit([AppUser? user]) async {
    final result = await showDialog<({AppUser user, String? password})>(
      context: context,
      builder: (_) => _UserDialog(
        user: user,
        existing: _users ?? const [],
        departments: _departments,
      ),
    );
    if (result == null || !mounted) return;
    await _load();
    if (!mounted) return;
    if (result.password != null) {
      await _showCredentials(
        context,
        title: 'Account created',
        user: result.user,
        password: result.password!,
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${result.user.fullName} saved')));
    }
  }

  Future<void> _resetPassword(AppUser user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reset ${user.fullName}’s password?'),
        content: const Text(
          'They get a temporary password to sign in with, then choose their '
          'own. Until then they’re signed out on every device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-reset'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset password'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final password = generateTemporaryPassword();
    try {
      await ref
          .read(cloudSyncProvider.notifier)
          .resetUserPassword(user.id, password);
    } catch (e) {
      if (mounted) _snack(describeAccountError(e));
      return;
    }
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    await _showCredentials(
      context,
      title: 'Password reset',
      user: user,
      password: password,
    );
  }

  Future<void> _setActive(AppUser user, bool active) async {
    if (!active) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Switch off ${user.fullName}’s account?'),
          content: const Text(
            'They’re signed out everywhere and can’t sign in. Everything '
            'they entered stays. You can switch it back on any time.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('confirm-deactivate'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Switch off'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    try {
      await ref
          .read(cloudSyncProvider.notifier)
          .saveUser(
            id: user.id,
            username: user.username,
            fullName: user.fullName,
            role: user.role,
            staffId: user.staffId,
            active: active,
            departmentId: user.departmentId,
            reportAccess: user.reportAccess,
          );
    } catch (e) {
      if (mounted) _snack(describeAccountError(e));
      return;
    }
    if (!mounted) return;
    _snack(
      active
          ? '${user.fullName} can sign in again'
          : '${user.fullName}’s account is switched off',
    );
    await _load();
  }

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
      height: 1.45,
    );
    final users = _users;
    final me = ref.watch(currentUserProvider);
    final staff = {for (final s in ref.watch(staffListProvider)) s.id: s};
    return AppPanel(
      title: 'Users',
      icon: Icons.manage_accounts_outlined,
      trailing: users == null
          ? null
          : '${users.where((u) => u.active).length} active',
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Everyone signs in with their own username and password. Add '
              'people here with a temporary password; they choose their own '
              'the first time they sign in. Forgot a password? Reset it here.',
              style: muted,
            ),
            const SizedBox(height: 12),
            if (_loading && users == null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && users == null)
              Text(_error!, style: muted)
            else if (users != null)
              for (final u in users)
                _UserRow(
                  key: ValueKey('user-${u.username}'),
                  user: u,
                  staff: u.staffId == null ? null : staff[u.staffId],
                  department: _departments
                      .where((d) => d.id == u.departmentId)
                      .firstOrNull,
                  isMe: u.id == me?.id,
                  onEdit: () => _edit(u),
                  onReset: () => _resetPassword(u),
                  onActive: (v) => _setActive(u, v),
                ),
            const SizedBox(height: 12),
            Wrap(
              spacing: Dt.s8,
              runSpacing: Dt.s8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('add-user'),
                  onPressed: users == null ? null : () => _edit(),
                  icon: const Icon(Icons.person_add_alt_1_outlined, size: 16),
                  label: const Text('Add user'),
                ),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    super.key,
    required this.user,
    required this.staff,
    this.department,
    required this.isMe,
    required this.onEdit,
    required this.onReset,
    required this.onActive,
  });

  final AppUser user;
  final Staff? staff;
  final Department? department;
  final bool isMe;
  final VoidCallback onEdit;
  final VoidCallback onReset;
  final ValueChanged<bool> onActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    final last = user.lastSignIn;
    final details = [
      '@${user.username}',
      user.role.label,
      if (department != null) department!.name,
      if (user.reportAccess != ReportAccess.employee) user.reportAccess.label,
      if (staff != null) 'Staff: ${staff!.name}',
      last == null
          ? 'Never signed in'
          : 'Last signed in ${DateFormat('dd/MM/yyyy HH:mm').format(last)}',
    ].join(' · ');
    Widget chip(String text) => Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
    return Opacity(
      opacity: user.active ? 1 : 0.55,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              user.role == UserRole.admin
                  ? Icons.admin_panel_settings_outlined
                  : Icons.person_outline,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    runSpacing: 4,
                    children: [
                      Text(
                        user.fullName,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (isMe) chip('You'),
                      if (!user.active) chip('Switched off'),
                      if (user.locked) chip('Locked for now'),
                      if (user.active && user.mustChange)
                        chip('Temporary password'),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(details, style: muted),
                ],
              ),
            ),
            PopupMenuButton<String>(
              key: ValueKey('user-menu-${user.username}'),
              tooltip: 'Account options',
              onSelected: (v) => switch (v) {
                'edit' => onEdit(),
                'reset' => onReset(),
                'off' => onActive(false),
                'on' => onActive(true),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                const PopupMenuItem(
                  value: 'reset',
                  child: Text('Reset password'),
                ),
                if (!isMe)
                  PopupMenuItem(
                    value: user.active ? 'off' : 'on',
                    child: Text(
                      user.active ? 'Switch off account' : 'Switch back on',
                    ),
                  ),
              ],
              icon: const Icon(Icons.more_vert, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// Add or edit one account. Returns the saved account, with the temporary
/// password for a new one.
class _UserDialog extends ConsumerStatefulWidget {
  const _UserDialog({
    required this.user,
    required this.existing,
    required this.departments,
  });

  final AppUser? user;
  final List<AppUser> existing;
  final List<Department> departments;

  @override
  ConsumerState<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends ConsumerState<_UserDialog> {
  late final _name = TextEditingController(text: widget.user?.fullName);
  late final _username = TextEditingController(text: widget.user?.username);
  late final _password = TextEditingController(
    text: widget.user == null ? generateTemporaryPassword() : '',
  );
  late UserRole _role = widget.user?.role ?? UserRole.team;
  late int? _staffId = widget.user?.staffId;
  late int? _departmentId = widget.user?.departmentId;
  late ReportAccess _access =
      widget.user?.reportAccess ?? ReportAccess.employee;
  late bool _usernameEdited = widget.user != null;
  bool _busy = false;
  String? _error;

  bool get _isNew => widget.user == null;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Iterable<String> get _taken => widget.existing
      .where((u) => u.id != widget.user?.id)
      .map((u) => u.username);

  void _nameChanged(String name) {
    if (_usernameEdited) return;
    _username.text = AppUser.suggestUsername(name, taken: _taken);
  }

  void _pickStaff(int? id, List<Staff> staff) {
    setState(() => _staffId = id);
    if (id == null || _name.text.trim().isNotEmpty) return;
    final person = staff.where((s) => s.id == id).firstOrNull;
    if (person == null) return;
    _name.text = person.name;
    _nameChanged(person.name);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final username = _username.text.trim().toLowerCase();
    String? error;
    if (name.isEmpty) {
      error = 'Enter the person’s name.';
    } else if (!AppUser.usernamePattern.hasMatch(username)) {
      error =
          'Usernames are 3 to 32 characters: lower case letters, numbers, '
          'dots, dashes or underscores, starting and ending with a letter '
          'or number.';
    } else if (_taken.contains(username)) {
      error = 'Someone already has that username.';
    } else if (_isNew && _password.text.length < AppUser.minPasswordLength) {
      error =
          'The temporary password needs at least '
          '${AppUser.minPasswordLength} characters.';
    }
    setState(() => _error = error);
    if (error != null || _busy) return;
    setState(() => _busy = true);
    try {
      final saved = await ref
          .read(cloudSyncProvider.notifier)
          .saveUser(
            id: widget.user?.id,
            username: username,
            fullName: name,
            role: _role,
            staffId: _staffId,
            departmentId: _departmentId,
            reportAccess: _access,
            active: widget.user?.active ?? true,
            password: _isNew ? _password.text : null,
          );
      if (!mounted) return;
      Navigator.of(context)
          .pop((user: saved, password: _isNew ? _password.text : null));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeAccountError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    final staff = ref.watch(staffListProvider);
    final staffChoices = [
      for (final s in staff)
        if (s.active || s.id == _staffId) s,
    ];
    final roleNote = widget.user != null && widget.user!.role != _role
        ? ' A new role signs them out, so it takes effect at once.'
        : '';
    return AlertDialog(
      title: Text(_isNew ? 'Add user' : 'Edit ${widget.user!.fullName}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int?>(
                key: const ValueKey('user-staff'),
                initialValue: _staffId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Staff member (optional)',
                ),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('Not linked to a staff member'),
                  ),
                  for (final s in staffChoices)
                    DropdownMenuItem<int?>(value: s.id, child: Text(s.name)),
                ],
                onChanged: _busy ? null : (v) => _pickStaff(v, staff),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('user-name'),
                controller: _name,
                autofocus: _isNew,
                enabled: !_busy,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Full name'),
                onChanged: _nameChanged,
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('user-username'),
                controller: _username,
                enabled: !_busy,
                autocorrect: false,
                inputFormatters: [
                  TextInputFormatter.withFunction(
                    (old, value) =>
                        value.copyWith(text: value.text.toLowerCase()),
                  ),
                ],
                onChanged: (_) => _usernameEdited = true,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  helperText: 'What they type to sign in, e.g. mary.wanjiku',
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<UserRole>(
                key: const ValueKey('user-role'),
                initialValue: _role,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  for (final r in UserRole.values)
                    DropdownMenuItem(value: r, child: Text(r.label)),
                ],
                onChanged: _busy
                    ? null
                    : (r) => setState(() => _role = r ?? _role),
              ),
              const SizedBox(height: 4),
              Text('${_role.summary}.$roleNote', style: muted),
              if (widget.departments.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('DAILY REPORTS', style: microLabel(theme)),
                const SizedBox(height: 4),
                DropdownButtonFormField<int?>(
                  key: const ValueKey('user-department'),
                  initialValue: _departmentId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Department'),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('No department'),
                    ),
                    for (final d in widget.departments)
                      if (d.active || d.id == _departmentId)
                        DropdownMenuItem<int?>(
                          value: d.id,
                          child: Text(d.name),
                        ),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _departmentId = v),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<ReportAccess>(
                  key: const ValueKey('user-access'),
                  initialValue: _access,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Report access'),
                  items: [
                    for (final a in ReportAccess.values)
                      DropdownMenuItem(value: a, child: Text(a.label)),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _access = v ?? _access),
                ),
                const SizedBox(height: 4),
                Text(
                  _role == UserRole.admin || _role == UserRole.director
                      ? '${_role.label}s always see every department.'
                      : '${_access.summary}.',
                  style: muted,
                ),
              ],
              if (_isNew) ...[
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('user-password'),
                  controller: _password,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Temporary password',
                    helperText: 'They choose their own at first sign-in.',
                    suffixIcon: IconButton(
                      tooltip: 'Make another',
                      icon: const Icon(Icons.casino_outlined, size: 18),
                      onPressed: () => setState(
                        () => _password.text = generateTemporaryPassword(),
                      ),
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  key: const ValueKey('user-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('user-save'),
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isNew ? 'Create account' : 'Save'),
        ),
      ],
    );
  }
}

/// Shows a username and temporary password once, to pass on in person.
Future<void> _showCredentials(
  BuildContext context, {
  required String title,
  required AppUser user,
  required String password,
}) {
  final text = 'Username: ${user.username}\nTemporary password: $password';
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Give these to ${user.fullName}. They’ll choose their own '
                'password when they sign in. This is the only time the '
                'temporary password is shown.',
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(Dt.rMd),
                ),
                child: SelectableText(
                  text,
                  key: const ValueKey('credentials'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );
}

/// A temporary password that's easy to read out and type: no 0/O or 1/l.
String generateTemporaryPassword() {
  const letters = 'abcdefghjkmnpqrstuvwxyz';
  const digits = '23456789';
  final rng = Random.secure();
  String pick(String from, int n) =>
      List.generate(n, (_) => from[rng.nextInt(from.length)]).join();
  return '${pick(letters, 4)}-${pick(digits, 4)}-${pick(letters, 4)}';
}

/// A short, plain message for an account action that didn't work.
String describeAccountError(Object e) {
  if (e is! CloudException) {
    return 'Couldn’t reach the online database. Check the connection and '
        'try again.';
  }
  return switch (e.code) {
    'username_taken' => 'Someone already has that username.',
    'bad_username' =>
      'That username isn’t allowed: use 3 to 32 lower case letters, numbers, '
          'dots, dashes or underscores.',
    'bad_name' => 'Enter the person’s name.',
    'password_too_short' =>
      'Passwords need at least ${AppUser.minPasswordLength} characters.',
    'last_admin' => 'There must always be at least one admin who can sign in.',
    'own_account' =>
      'You can’t switch off your own account or remove your own admin '
          'role. Ask another admin.',
    'not_signed_in' =>
      'Only an admin can manage accounts, and your sign-in may have ended. '
          'Sign out and in again.',
    _ => 'That didn’t work (${e.code}).',
  };
}
