import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/account_services.dart';
import '../../services/app_info.dart';
import '../../state/app_state.dart';
import '../../widgets/clarity.dart';
import '../../widgets/panels.dart';
import '../quick_search/shortcuts_dialog.dart';

String _when(DateTime? t) {
  if (t == null) return '—';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final time = DateFormat('HH:mm').format(t);
  if (day == today) return 'today, $time';
  if (day == today.subtract(const Duration(days: 1))) return 'yesterday, $time';
  return '${DateFormat(t.year == now.year ? 'd MMM' : 'd MMM y').format(t)}, $time';
}

// ------------------------------------------------------------ what's new --

/// After an update, once: what changed in this version.
Future<void> maybeShowWhatsNew(BuildContext context, WidgetRef ref) async {
  if (!AppInfo.showWhatsNew) return;
  final prefs = ref.read(uiPrefProvider);
  if (prefs.get('seen_version') == AppInfo.version) return;
  prefs.set('seen_version', AppInfo.version);
  if (!context.mounted) return;
  await showWhatsNew(context);
}

Future<void> showWhatsNew(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    return AlertDialog(
      key: const ValueKey('whats-new'),
      title: Text('What’s new in ${Dt.appName} ${AppInfo.version}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, r) in AppInfo.releases.indexed) ...[
                if (i > 0) const SizedBox(height: 18),
                Text(
                  '${r.version} · ${r.date}',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                for (final item in r.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 7, right: 10),
                          child: MeaningDot(c.accent),
                        ),
                        Expanded(
                          child: Text(item, style: theme.textTheme.bodyMedium),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
    );
  },
);

// ------------------------------------------------------------- text size --

/// Normal / Large / Larger.
class TextSizePicker extends ConsumerWidget {
  const TextSizePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(textScaleProvider);
    return SegmentedButton<double>(
      key: const ValueKey('text-size'),
      segments: [
        for (final (v, label) in TextScaleNotifier.sizes)
          ButtonSegment(value: v, label: Text(label)),
      ],
      selected: {scale},
      showSelectedIcon: false,
      onSelectionChanged: (s) =>
          ref.read(textScaleProvider.notifier).set(s.first),
    );
  }
}

Future<void> showTextSize(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Text size'),
    content: const Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('For this device. Larger text may show fewer items at once.'),
        SizedBox(height: 14),
        TextSizePicker(),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Done'),
      ),
    ],
  ),
);

// -------------------------------------------------------------- sessions --

/// Where you're signed in, with sign out for each other device.
Future<void> showSessions(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _SessionsDialog());

class _SessionsDialog extends ConsumerStatefulWidget {
  const _SessionsDialog();

  @override
  ConsumerState<_SessionsDialog> createState() => _SessionsDialogState();
}

class _SessionsDialogState extends ConsumerState<_SessionsDialog> {
  List<AccountSession>? _sessions;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await ref.read(sessionsServiceProvider).list();
      if (mounted) setState(() => (_sessions = s, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = describeAccountError(e));
    }
  }

  Future<void> _run(Future<int> Function() action) async {
    setState(() => _busy = true);
    try {
      final n = await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              n == 0
                  ? 'Nothing to sign out.'
                  : 'Signed out of $n ${n == 1 ? 'device' : 'devices'}.',
            ),
          ),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = describeAccountError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final sessions = _sessions;
    final others = sessions?.where((s) => !s.current).length ?? 0;
    return AlertDialog(
      key: const ValueKey('sessions-dialog'),
      title: const Text('Where you’re signed in'),
      content: SizedBox(
        width: 520,
        child: _error != null
            ? Text(_error!, style: TextStyle(color: c.negativeFg))
            : sessions == null
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Lost a phone, or signed in on a shared computer? Sign '
                    'that device out here.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  for (final s in sessions)
                    Container(
                      key: ValueKey('session-${s.id}'),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.borderSubtle)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            s.device.contains('phone')
                                ? Icons.phone_android
                                : s.device.contains('Web')
                                ? Icons.language
                                : Icons.computer,
                            size: 20,
                            color: c.textMuted,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        s.device,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                    if (s.current) ...[
                                      const SizedBox(width: 8),
                                      const StatusPill(
                                        'This device',
                                        tone: PillTone.positive,
                                      ),
                                    ],
                                  ],
                                ),
                                Text(
                                  'Last used ${_when(s.lastSeen)} · signed '
                                  'in ${_when(s.signedIn)}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          if (!s.current)
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(
                                      () => ref
                                          .read(sessionsServiceProvider)
                                          .signOut(s.id),
                                    ),
                              style: TextButton.styleFrom(
                                foregroundColor: c.negativeFg,
                              ),
                              child: const Text('Sign out'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        if (others > 0)
          OutlinedButton(
            key: const ValueKey('sign-out-others'),
            onPressed: _busy
                ? null
                : () => _run(
                    () => ref.read(sessionsServiceProvider).signOutOthers(),
                  ),
            child: Text('Sign out all other devices ($others)'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------- activity log --

Future<void> showActivityLog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _ActivityLogDialog(),
);

class _ActivityLogDialog extends ConsumerStatefulWidget {
  const _ActivityLogDialog();

  @override
  ConsumerState<_ActivityLogDialog> createState() => _ActivityLogDialogState();
}

class _ActivityLogDialogState extends ConsumerState<_ActivityLogDialog> {
  final _entries = <AuditEntry>[];
  bool _more = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || !_more) return;
    setState(() => _loading = true);
    try {
      final page = await ref
          .read(auditServiceProvider)
          .list(before: _entries.isEmpty ? null : _entries.last.id);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page);
        _more = page.length >= 100;
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeAccountError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final currency = ref.watch(currencyProvider);
    return AlertDialog(
      key: const ValueKey('activity-log'),
      title: const Text('Activity log'),
      content: SizedBox(
        width: 640,
        height: 520,
        child: _error != null
            ? Text(_error!, style: TextStyle(color: c.negativeFg))
            : _entries.isEmpty && _loading
            ? const Center(child: CircularProgressIndicator())
            : _entries.isEmpty
            ? Center(
                child: Text(
                  'Nothing yet. Changes to payments, weeks, staff, settings, '
                  'reports and accounts appear here.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: c.textMuted,
                  ),
                ),
              )
            : ListView.builder(
                itemCount: _entries.length + (_more ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i == _entries.length) {
                    return Center(
                      child: TextButton(
                        onPressed: _loading ? null : _load,
                        child: Text(_loading ? 'Loading…' : 'Load older'),
                      ),
                    );
                  }
                  final e = _entries[i];
                  final what = e.describe(currency: currency);
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.borderSubtle)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 110,
                          child: Text(
                            _when(e.at),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    e.actor,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  StatusPill(
                                    '${e.action} ${e.thing.toLowerCase()}',
                                    tone: switch (e.action) {
                                      'added' => PillTone.positive,
                                      'deleted' => PillTone.negative,
                                      _ => PillTone.neutral,
                                    },
                                  ),
                                ],
                              ),
                              if (what.isNotEmpty)
                                Text(
                                  what,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: c.textSecondary,
                                  ),
                                ),
                              for (final d in e.differences.take(4))
                                Text(d, style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

// ---------------------------------------------- About (version, problems) --

/// Settings › About: the version, what's new, and (admins) recent problems
/// the app reported.
class AboutSection extends ConsumerStatefulWidget {
  const AboutSection({super.key, required this.online, this.admin = true});

  /// The admin also sees the activity log and the problems reported.
  final bool admin;

  /// Personal accounts with the online database: problems and the activity
  /// log can be shown.
  final bool online;

  @override
  ConsumerState<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<AboutSection> {
  List<ErrorReport>? _errors;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.online && widget.admin) _load();
  }

  Future<void> _load() async {
    try {
      final list = await ref.read(errorsServiceProvider).list();
      if (mounted) setState(() => (_errors = list, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = describeAccountError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.clarity;
    final errors = _errors;
    return AppPanel(
      key: const ValueKey('about-section'),
      title: 'About',
      subtitle:
          '${Dt.appName} ${AppInfo.version} · ${Dt.companyName}. Totals are '
          'always calculated from the numbers entered.',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('show-whats-new'),
                  onPressed: () => showWhatsNew(context),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('What’s new'),
                ),
                OutlinedButton.icon(
                  onPressed: () => showShortcutsDialog(context),
                  icon: const Icon(Icons.keyboard_outlined),
                  label: const Text('Keyboard shortcuts'),
                ),
                if (widget.online && widget.admin)
                  OutlinedButton.icon(
                    key: const ValueKey('open-activity-log'),
                    onPressed: () => showActivityLog(context),
                    icon: const Icon(Icons.manage_search),
                    label: const Text('Activity log'),
                  ),
              ],
            ),
            if (widget.online && widget.admin) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  Text('PROBLEMS REPORTED', style: microLabel(theme)),
                  const Spacer(),
                  if (errors != null && errors.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        await ref.read(errorsServiceProvider).clear();
                        await _load();
                      },
                      child: const Text('Clear'),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (_error != null)
                Text(_error!, style: theme.textTheme.bodySmall)
              else if (errors == null)
                const LinearProgressIndicator()
              else if (errors.isEmpty)
                Text(
                  'None. Unexpected errors on any device are sent here '
                  'automatically.',
                  style: theme.textTheme.bodySmall,
                )
              else
                for (final e in errors.take(10))
                  Tooltip(
                    message: e.stack,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.borderSubtle)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          StatusPill(
                            '×${e.count}',
                            tone: e.count > 5
                                ? PillTone.negative
                                : PillTone.warning,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.message,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium,
                                ),
                                Text(
                                  [
                                    _when(e.lastSeen),
                                    if (e.version.isNotEmpty) 'v${e.version}',
                                    if (e.platform.isNotEmpty) e.platform,
                                    if (e.who.isNotEmpty) e.who,
                                  ].join(' · '),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}
