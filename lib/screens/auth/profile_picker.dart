import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../state/app_state.dart';
import '../../state/cloud_sync.dart';
import 'sign_in_screen.dart';

/// The first screen at every launch: who is using the app. Admin opens the
/// admin portal (its password); the other profiles open straight away, or
/// with the password the admin gave them.
class ProfilePickerScreen extends ConsumerStatefulWidget {
  const ProfilePickerScreen({super.key});

  @override
  ConsumerState<ProfilePickerScreen> createState() =>
      _ProfilePickerScreenState();
}

class _ProfilePickerScreenState extends ConsumerState<ProfilePickerScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshLocks());
  }

  /// Asks online which profiles have a password (the admin may have set one
  /// on another device) and remembers the answer for offline use.
  Future<void> _refreshLocks() async {
    final sync = ref.read(cloudSyncProvider.notifier);
    unawaited(sync.start());
    final status = await sync.profileStatus();
    if (status == null || !mounted) return;
    final auth = ref.read(authRepositoryProvider);
    for (final MapEntry(key: role, value: locked) in status.entries) {
      auth.markProfile(role, locked: locked);
    }
    setState(() {});
  }

  Future<void> _choose(UserRole role) async {
    if (role == UserRole.admin) {
      await showAdminSignIn(context);
      return;
    }
    final auth = ref.read(authRepositoryProvider);
    final sync = ref.read(cloudSyncProvider.notifier);
    if (!auth.isLocked(role)) {
      // Open: still signs in online (no password), so this device can
      // read the data (and the admin team send theirs). It doesn't hold
      // the app up.
      unawaited(sync.openProfile(role, ''));
      // The director's device opens straight into Director next time.
      if (role == UserRole.director) auth.rememberProfile(role);
      ref.read(sessionProvider.notifier).open(role);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _PasswordDialog(role: role),
    );
    if (ok == true && mounted) ref.read(sessionProvider.notifier).open(role);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final auth = ref.read(authRepositoryProvider);
    final width = MediaQuery.sizeOf(context).width;
    final twoColumns = width >= 640;

    Widget card(UserRole role) {
      final locked = role == UserRole.admin || auth.isLocked(role);
      return _ProfileCard(
        key: ValueKey('profile-${role.name}'),
        role: role,
        locked: locked,
        onTap: () => _choose(role),
      );
    }

    final roles = UserRole.values;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Dt.s24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: twoColumns ? 640 : 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Dt.rLg),
                      child: Image.asset(
                        Dt.logoAsset,
                        width: 56,
                        height: 56,
                        filterQuality: FilterQuality.medium,
                        semanticLabel: '${Dt.companyName} logo',
                      ),
                    ),
                  ),
                  const SizedBox(height: Dt.s12),
                  Text(
                    Dt.appName,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    Dt.companyName,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                  const SizedBox(height: Dt.s24),
                  Text(
                    'Who’s using the app?',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: Dt.s16),
                  if (twoColumns)
                    for (var i = 0; i < roles.length; i += 2) ...[
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: card(roles[i])),
                            const SizedBox(width: 12),
                            Expanded(child: card(roles[i + 1])),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ]
                  else
                    for (final r in roles) ...[
                      card(r),
                      const SizedBox(height: 10),
                    ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    super.key,
    required this.role,
    required this.locked,
    required this.onTap,
  });

  final UserRole role;
  final bool locked;
  final VoidCallback onTap;

  static IconData _icon(UserRole r) => switch (r) {
    UserRole.admin => Icons.admin_panel_settings_outlined,
    UserRole.adminTeam => Icons.edit_note,
    UserRole.director => Icons.visibility_outlined,
    UserRole.team => Icons.groups_2_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = Dt.textMuted(theme);
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rLg),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Dt.s16),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Dt.brand(theme.brightness).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(Dt.rMd),
                ),
                child: Icon(_icon(role), color: Dt.brand(theme.brightness)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      role.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: locked ? 'Needs a password' : 'Open',
                child: Icon(
                  locked ? Icons.lock_outline : Icons.chevron_right,
                  size: 18,
                  color: muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A locked profile's password: checked online (so a password the admin
/// changed elsewhere works), or on this device when offline.
class _PasswordDialog extends ConsumerStatefulWidget {
  const _PasswordDialog({required this.role});
  final UserRole role;

  @override
  ConsumerState<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends ConsumerState<_PasswordDialog> {
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _show = false;

  /// "Keep me signed in on this device" — on for the director.
  late bool _stay = widget.role == UserRole.director;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    if (password.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final role = widget.role;
    final auth = ref.read(authRepositoryProvider);
    final online = await ref
        .read(cloudSyncProvider.notifier)
        .openProfile(role, password)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => CloudLink.offline,
        );
    if (!mounted) return;
    bool ok;
    String? error;
    switch (online) {
      case CloudLink.linked:
        // Remember it here, so it also opens without internet.
        auth.setProfilePassword(role, password);
        ok = true;
      case CloudLink.wrongPassword:
        ok = false;
        error = 'Wrong password. Try again.';
      case CloudLink.offline || CloudLink.off:
        final here = auth.verifyProfile(role, password);
        ok = here ?? false;
        error = here == null
            ? 'No internet, and this profile hasn’t been opened on this '
                  'device before, so the password can’t be checked. Try '
                  'again when online.'
            : 'Wrong password. Try again.';
    }
    if (ok) {
      if (_stay) {
        final version = await ref
            .read(cloudSyncProvider.notifier)
            .profileVersion(role)
            .timeout(const Duration(seconds: 5), onTimeout: () => null);
        auth.rememberProfile(role, version: version);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
      _password.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.role.label),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('profile-password'),
              controller: _password,
              autofocus: true,
              obscureText: !_show,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                errorText: _error,
                errorMaxLines: 4,
                suffixIcon: IconButton(
                  tooltip: _show ? 'Hide password' : 'Show password',
                  icon: Icon(
                    _show
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
            CheckboxListTile(
              key: const ValueKey('profile-stay'),
              value: _stay,
              onChanged: (v) => setState(() => _stay = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: const Text('Keep me signed in on this device'),
              subtitle: const Text(
                'Opens straight into this profile. Switch profile signs out.',
              ),
            ),
            Text(
              'Ask the admin if you don’t know it.',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Dt.textMuted(Theme.of(context))),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('profile-open'),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Open'),
        ),
      ],
    );
  }
}
