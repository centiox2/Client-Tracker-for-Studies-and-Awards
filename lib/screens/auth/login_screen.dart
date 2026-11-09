import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../services/cloud/cloud_api.dart';
import '../../state/app_state.dart';
import '../../state/cloud_sync.dart';

/// The first screen when nobody is signed in: username, password and
/// "Remember me". A brand-new online database (no accounts yet) asks for the
/// first admin account instead; someone signing in with a temporary password
/// chooses their own before going on.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

enum _Stage { checking, signIn, setup, newPassword }

class _LoginScreenState extends ConsumerState<LoginScreen> {
  var _stage = _Stage.checking;

  /// Signed in with a temporary password: kept until they choose their own.
  UserSignIn? _temporary;
  String _temporaryPassword = '';
  bool _remember = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkStatus());
  }

  Future<void> _checkStatus() async {
    final sync = ref.read(cloudSyncProvider.notifier);
    unawaited(sync.start());
    final status = await sync.usersStatus().timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
    if (!mounted) return;
    setState(() => _stage = status == 'empty' ? _Stage.setup : _Stage.signIn);
  }

  void _needsNewPassword(UserSignIn signIn, String temporary, bool remember) {
    setState(() {
      _temporary = signIn;
      _temporaryPassword = temporary;
      _remember = remember;
      _stage = _Stage.newPassword;
    });
  }

  @override
  Widget build(BuildContext context) {
    final notice = ref.watch(signInNoticeProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Dt.s24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Brand(),
                  const SizedBox(height: Dt.s24),
                  if (notice != null && _stage != _Stage.newPassword) ...[
                    _Notice(notice),
                    const SizedBox(height: Dt.s12),
                  ],
                  switch (_stage) {
                    _Stage.checking => const Padding(
                      padding: EdgeInsets.all(Dt.s24),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    _Stage.signIn => _SignInForm(
                      onTemporaryPassword: _needsNewPassword,
                    ),
                    _Stage.setup => const _SetupForm(),
                    _Stage.newPassword => _NewPasswordForm(
                      signIn: _temporary!,
                      temporary: _temporaryPassword,
                      remember: _remember,
                      onCancel: () => setState(() {
                        _temporary = null;
                        _temporaryPassword = '';
                        _stage = _Stage.signIn;
                      }),
                    ),
                  },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Dt.rLg),
          child: Image.asset(
            Dt.logoAsset,
            width: 64,
            height: 64,
            filterQuality: FilterQuality.medium,
            semanticLabel: '${Dt.companyName} logo',
          ),
        ),
        const SizedBox(height: Dt.s12),
        Text(
          'Client Tracker',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          Dt.companyName,
          style: theme.textTheme.bodySmall?.copyWith(
            color: Dt.textMuted(theme),
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const ValueKey('signin-notice'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// Card chrome shared by the forms.
class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A Material (not a coloured box), so "Remember me" shows its ripple.
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rLg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Dt.s20),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

Widget _spinnerOr(bool busy, String label) => busy
    ? const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      )
    : Text(label);

/// A password field with a show/hide button.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    required this.label,
    this.errorText,
    this.autofocus = false,
    this.enabled = true,
    this.newPassword = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? errorText;
  final bool autofocus;
  final bool enabled;

  /// A password being chosen (not typed in to sign in).
  final bool newPassword;
  final ValueChanged<String>? onSubmitted;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _show = false;

  @override
  Widget build(BuildContext context) => TextField(
    controller: widget.controller,
    autofocus: widget.autofocus,
    enabled: widget.enabled,
    obscureText: !_show,
    autocorrect: false,
    enableSuggestions: false,
    autofillHints: [
      widget.newPassword ? AutofillHints.newPassword : AutofillHints.password,
    ],
    onSubmitted: widget.onSubmitted,
    decoration: InputDecoration(
      labelText: widget.label,
      errorText: widget.errorText,
      errorMaxLines: 4,
      suffixIcon: IconButton(
        tooltip: _show ? 'Hide password' : 'Show password',
        icon: Icon(
          _show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 18,
        ),
        onPressed: () => setState(() => _show = !_show),
      ),
    ),
  );
}

/// Usernames are typed in lower case.
final _usernameFormatter = TextInputFormatter.withFunction(
  (old, value) => value.copyWith(text: value.text.toLowerCase()),
);

class _SignInForm extends ConsumerStatefulWidget {
  const _SignInForm({required this.onTemporaryPassword});

  final void Function(UserSignIn signIn, String temporary, bool remember)
  onTemporaryPassword;

  @override
  ConsumerState<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends ConsumerState<_SignInForm> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _remember = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _username.text.trim().toLowerCase();
    final password = _password.text;
    if (_busy) return;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final sync = ref.read(cloudSyncProvider.notifier);
    String? error;
    try {
      final signIn = await sync
          .checkSignIn(username, password, remember: _remember)
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      TextInput.finishAutofillContext();
      if (signIn.user.mustChange) {
        widget.onTemporaryPassword(signIn, password, _remember);
        return;
      }
      sync.completeSignIn(signIn, password, remember: _remember);
      return;
    } on CloudException catch (e) {
      error = switch (e.code) {
        'wrong_password' => 'Username or password is incorrect.',
        'locked' =>
          'Too many wrong passwords. Try again in 15 minutes, or ask an '
              'admin to reset your password.',
        'deactivated' =>
          'This account has been switched off. Ask an admin if you need '
              'it again.',
        'needs_update' =>
          'The online database hasn’t been set up for personal accounts '
              'yet. Ask the admin to apply the update.',
        _ => 'Couldn’t sign in (${e.code}). Try again.',
      };
      if (e.code == 'deactivated') {
        ref.read(authRepositoryProvider).forgetUser(username);
      }
    } catch (_) {
      // No internet: someone who signed in on this device before can still
      // get in, and is signed in online once the connection is back.
      if (!mounted) return;
      final auth = ref.read(authRepositoryProvider);
      final user = auth.verifyOffline(username, password);
      if (user != null) {
        sync.signInOffline(user, password, remember: _remember);
        return;
      }
      error = auth.knowsUser(username)
          ? 'Username or password is incorrect.'
          : 'No internet connection. Without internet you can only sign in '
                'on a device you’ve signed in on before.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
      _password.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    return _Card(
      children: [
        Text('Sign in', style: theme.textTheme.titleMedium),
        const SizedBox(height: Dt.s16),
        TextField(
          key: const ValueKey('login-username'),
          controller: _username,
          autofocus: true,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.username],
          inputFormatters: [_usernameFormatter],
          decoration: const InputDecoration(
            labelText: 'Username',
            hintText: 'e.g. mary.wanjiku',
          ),
        ),
        const SizedBox(height: Dt.s12),
        PasswordField(
          key: const ValueKey('login-password'),
          controller: _password,
          label: 'Password',
          enabled: !_busy,
          errorText: _error,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: Dt.s4),
        CheckboxListTile(
          key: const ValueKey('login-remember'),
          value: _remember,
          onChanged: _busy
              ? null
              : (v) => setState(() => _remember = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: const Text('Remember me'),
          subtitle: const Text(
            'Stay signed in on this device for 30 days. Leave unticked on a '
            'shared computer.',
          ),
        ),
        const SizedBox(height: Dt.s8),
        FilledButton(
          key: const ValueKey('login-submit'),
          onPressed: _busy ? null : _submit,
          child: _spinnerOr(_busy, 'Sign in'),
        ),
        const SizedBox(height: Dt.s12),
        Text(
          'Forgot your password? Ask an admin to reset it.',
          textAlign: TextAlign.center,
          style: muted,
        ),
      ],
    );
  }
}

/// A brand-new online database: the first account, an admin.
class _SetupForm extends ConsumerStatefulWidget {
  const _SetupForm();

  @override
  ConsumerState<_SetupForm> createState() => _SetupFormState();
}

class _SetupFormState extends ConsumerState<_SetupForm> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _usernameEdited = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final username = _username.text.trim().toLowerCase();
    String? error;
    if (name.isEmpty) {
      error = 'Enter your name.';
    } else if (!AppUser.usernamePattern.hasMatch(username)) {
      error = _usernameRules;
    } else if (_password.text.length < AppUser.minPasswordLength) {
      error = 'Use at least ${AppUser.minPasswordLength} characters.';
    } else if (_password.text != _confirm.text) {
      error = 'The passwords don’t match.';
    }
    setState(() => _error = error);
    if (error != null || _busy) return;
    setState(() => _busy = true);
    final sync = ref.read(cloudSyncProvider.notifier);
    try {
      final signIn = await sync.setupFirstAdmin(username, name, _password.text);
      sync.completeSignIn(signIn, _password.text, remember: false);
      return;
    } on CloudException catch (e) {
      error = e.code == 'already_claimed'
          ? 'An admin account already exists. Close and reopen the app to '
                'sign in.'
          : 'Couldn’t create the account (${e.code}).';
    } catch (_) {
      error = 'Couldn’t reach the online database. Check the connection.';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Card(
      children: [
        Text(
          'Create the first admin account',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: Dt.s4),
        Text(
          'There are no accounts yet. This one is an admin: it can add '
          'everyone else in Settings › Users.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Dt.textMuted(theme),
          ),
        ),
        const SizedBox(height: Dt.s16),
        TextField(
          key: const ValueKey('setup-name'),
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Your name'),
          onChanged: (v) {
            if (!_usernameEdited) {
              _username.text = AppUser.suggestUsername(v);
            }
          },
        ),
        const SizedBox(height: Dt.s12),
        TextField(
          key: const ValueKey('setup-username'),
          controller: _username,
          autocorrect: false,
          inputFormatters: [_usernameFormatter],
          onChanged: (_) => _usernameEdited = true,
          decoration: const InputDecoration(labelText: 'Username'),
        ),
        const SizedBox(height: Dt.s12),
        PasswordField(
          key: const ValueKey('setup-password'),
          controller: _password,
          label: 'Password',
          newPassword: true,
        ),
        const SizedBox(height: Dt.s12),
        PasswordField(
          key: const ValueKey('setup-confirm'),
          controller: _confirm,
          label: 'Password again',
          newPassword: true,
          errorText: _error,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: Dt.s16),
        FilledButton(
          key: const ValueKey('setup-submit'),
          onPressed: _busy ? null : _submit,
          child: _spinnerOr(_busy, 'Create account and sign in'),
        ),
      ],
    );
  }
}

const _usernameRules =
    'Usernames are 3 to 32 characters: lower case letters, numbers, dots, '
    'dashes or underscores, starting and ending with a letter or number.';

/// Signed in with the temporary password an admin gave: choose your own.
class _NewPasswordForm extends ConsumerStatefulWidget {
  const _NewPasswordForm({
    required this.signIn,
    required this.temporary,
    required this.remember,
    required this.onCancel,
  });

  final UserSignIn signIn;
  final String temporary;
  final bool remember;
  final VoidCallback onCancel;

  @override
  ConsumerState<_NewPasswordForm> createState() => _NewPasswordFormState();
}

class _NewPasswordFormState extends ConsumerState<_NewPasswordForm> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final next = _password.text;
    String? error = newPasswordProblem(next, _confirm.text);
    if (error == null && next == widget.temporary) {
      error = 'Choose a password different from the temporary one.';
    }
    setState(() => _error = error);
    if (error != null || _busy) return;
    setState(() => _busy = true);
    final sync = ref.read(cloudSyncProvider.notifier);
    try {
      final signIn = await sync.replaceTemporaryPassword(
        widget.signIn,
        widget.temporary,
        next,
      );
      TextInput.finishAutofillContext();
      sync.completeSignIn(signIn, next, remember: widget.remember);
      return;
    } on CloudException catch (e) {
      error = e.code == 'not_signed_in'
          ? 'This took too long. Go back and sign in again.'
          : 'Couldn’t save the password (${e.code}).';
    } catch (_) {
      error = 'Couldn’t reach the online database. Check the connection.';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Card(
      children: [
        Text(
          'Welcome, ${widget.signIn.user.fullName}',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: Dt.s4),
        Text(
          'You signed in with a temporary password. Choose your own to '
          'continue — at least ${AppUser.minPasswordLength} characters, and '
          'don’t share it.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Dt.textMuted(theme),
          ),
        ),
        const SizedBox(height: Dt.s16),
        PasswordField(
          key: const ValueKey('new-password'),
          controller: _password,
          label: 'New password',
          autofocus: true,
          newPassword: true,
        ),
        const SizedBox(height: Dt.s12),
        PasswordField(
          key: const ValueKey('new-password-again'),
          controller: _confirm,
          label: 'New password again',
          newPassword: true,
          errorText: _error,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: Dt.s16),
        FilledButton(
          key: const ValueKey('new-password-save'),
          onPressed: _busy ? null : _submit,
          child: _spinnerOr(_busy, 'Save password and continue'),
        ),
        const SizedBox(height: Dt.s8),
        TextButton(
          onPressed: _busy ? null : widget.onCancel,
          child: const Text('Back'),
        ),
      ],
    );
  }
}

/// What's wrong with a new password typed twice; null when it's fine.
String? newPasswordProblem(String password, String again) {
  if (password.length < AppUser.minPasswordLength) {
    return 'Use at least ${AppUser.minPasswordLength} characters.';
  }
  if (password != again) return 'The two passwords don’t match.';
  return null;
}

/// The signed-in person changes their own password (account menu).
Future<void> showChangeOwnPassword(BuildContext context) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => const _ChangeOwnPasswordDialog(),
  );
  if (changed == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Password changed. Other devices signed in as you will need to '
          'sign in again.',
        ),
      ),
    );
  }
}

class _ChangeOwnPasswordDialog extends ConsumerStatefulWidget {
  const _ChangeOwnPasswordDialog();

  @override
  ConsumerState<_ChangeOwnPasswordDialog> createState() =>
      _ChangeOwnPasswordDialogState();
}

class _ChangeOwnPasswordDialogState
    extends ConsumerState<_ChangeOwnPasswordDialog> {
  final _current = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    var error = _current.text.isEmpty
        ? 'Enter your current password.'
        : newPasswordProblem(_password.text, _confirm.text);
    setState(() => _error = error);
    if (error != null || _busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(cloudSyncProvider.notifier)
          .changeOwnPassword(_current.text, _password.text);
      if (mounted) Navigator.of(context).pop(true);
      return;
    } on CloudException catch (e) {
      error = switch (e.code) {
        'wrong_password' => 'Your current password is wrong.',
        'same_password' => 'The new password is the same as the current one.',
        'not_signed_in' => 'Your sign-in has ended. Sign out and in again.',
        _ => 'Couldn’t change it (${e.code}).',
      };
    } catch (_) {
      error = 'Changing your password needs an internet connection.';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Change your password'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PasswordField(
            key: const ValueKey('own-current'),
            controller: _current,
            label: 'Current password',
            autofocus: true,
          ),
          const SizedBox(height: 10),
          PasswordField(
            key: const ValueKey('own-new'),
            controller: _password,
            label: 'New password',
            newPassword: true,
          ),
          const SizedBox(height: 10),
          PasswordField(
            key: const ValueKey('own-new-again'),
            controller: _confirm,
            label: 'New password again',
            newPassword: true,
            errorText: _error,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('own-save'),
        onPressed: _busy ? null : _submit,
        child: _spinnerOr(_busy, 'Change password'),
      ),
    ],
  );
}
