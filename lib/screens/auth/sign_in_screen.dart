import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../repositories/auth_repository.dart';
import '../../state/app_state.dart';
import '../../state/cloud_sync.dart';

/// Opens the admin sign-in over the Reports view. Returns when the admin
/// signs in (the workspace then shows) or goes back.
Future<void> showAdminSignIn(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SignInScreen()));

/// Admin sign-in for the workspace. The first time (no admin password yet)
/// it asks you to create one instead.
class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A new device whose admin password already exists online signs in
    // with it rather than creating another one.
    final firstRun =
        !ref.read(authRepositoryProvider).hasAdminPassword &&
        ref.watch(cloudSyncProvider).claimed != true;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        title: const Text('Back to reports'),
        titleTextStyle: Theme.of(context).textTheme.labelLarge,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Dt.s24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Brand(),
                const SizedBox(height: Dt.s24),
                firstRun ? const _SetupForm() : const _SignInForm(),
              ],
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

/// Card chrome shared by both forms.
class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Dt.s20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(Dt.rLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
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

class _SignInForm extends ConsumerStatefulWidget {
  const _SignInForm();

  @override
  ConsumerState<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends ConsumerState<_SignInForm> {
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_password.text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Let the spinner paint before the (synchronous) password check.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    final password = _password.text;
    final auth = ref.read(authRepositoryProvider);
    final local = auth.verifyAdmin(password);
    // Also online, so this device can send its changes (and so a new device
    // can sign in with the password set on another one).
    final online = await ref
        .read(cloudSyncProvider.notifier)
        .linkAdmin(password)
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () => CloudLink.offline,
        );
    if (!mounted) return;
    final ok = local || online == CloudLink.linked;
    if (ok) {
      // Keep this device's password the same as the online one.
      if (!local) auth.setAdminPassword(password);
      ref.read(adminSessionProvider.notifier).signInAfterSetup();
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      if (online == CloudLink.wrongPassword) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Signed in on this device. The online admin password is '
              'different, so changes stay here until you sign in with it.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      }
    } else {
      setState(() {
        _busy = false;
        _error = 'Wrong password. Try again.';
        _password.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Card(
      children: [
        Text('Admin sign in', style: theme.textTheme.titleMedium),
        const SizedBox(height: Dt.s4),
        Text(
          ref.read(authRepositoryProvider).hasAdminPassword
              ? 'Opens the workspace, where client numbers are entered and '
                    'edited.'
              : 'Use the admin password you set up on your other device.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Dt.textMuted(theme),
          ),
        ),
        const SizedBox(height: Dt.s16),
        TextField(
          controller: _password,
          autofocus: true,
          obscureText: true,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: 'Admin password',
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: Dt.s16),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _spinnerOr(_busy, 'Sign in to workspace'),
        ),
      ],
    );
  }
}

class _SetupForm extends ConsumerStatefulWidget {
  const _SetupForm();

  @override
  ConsumerState<_SetupForm> createState() => _SetupFormState();
}

class _SetupFormState extends ConsumerState<_SetupForm> {
  final _admin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _admin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    const min = AuthRepository.minPasswordLength;
    String? error;
    if (_admin.text.length < min) {
      error = 'Use at least $min characters.';
    } else if (_admin.text != _confirm.text) {
      error = 'The passwords don’t match.';
    }
    setState(() => _error = error);
    if (error != null) return;

    setState(() => _busy = true);
    await Future<void>.delayed(const Duration(milliseconds: 16));
    ref.read(authRepositoryProvider).setAdminPassword(_admin.text);
    // The first admin sign-in anywhere also sets the online password.
    ref.read(cloudSyncProvider.notifier).linkAdmin(_admin.text);
    ref.read(adminSessionProvider.notifier).signInAfterSetup();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Card(
      children: [
        Text('Create the admin password', style: theme.textTheme.titleMedium),
        const SizedBox(height: Dt.s4),
        Text(
          'Only the workspace (entering and editing numbers) needs this '
          'password. Reports stay open to anyone using the app.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: Dt.textMuted(theme),
          ),
        ),
        const SizedBox(height: Dt.s16),
        TextField(
          controller: _admin,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Admin password'),
        ),
        const SizedBox(height: Dt.s12),
        TextField(
          controller: _confirm,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'Confirm password',
            errorText: _error,
            errorMaxLines: 2,
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: Dt.s16),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _spinnerOr(_busy, 'Create password and sign in'),
        ),
      ],
    );
  }
}
