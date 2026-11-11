import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../models/staff.dart';
import '../../repositories/auth_repository.dart';
import '../../services/auto_backup.dart';
import '../../services/export_actions.dart';
import '../../services/file_delivery.dart';
import '../../state/app_state.dart';
import '../../state/cloud_sync.dart';
import '../../widgets/clarity.dart';
import '../../widgets/panels.dart';
import '../../widgets/sync_status.dart';
import '../history/change_history_dialog.dart';
import 'about_section.dart';
import 'airtable_section.dart';
import 'import_dialog.dart';
import 'departments_section.dart';
import 'users_section.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int? _exportWeekId;
  bool _busy = false;

  final _target = TextEditingController();
  final _currency = TextEditingController();
  final _purposes = TextEditingController();

  // Shared by the Scrollbar and the list: on desktop a list doesn't attach
  // to the primary controller, so a scrollbar without one can't paint.
  final _scroll = ScrollController();
  bool _targetSeeded = false;

  @override
  void dispose() {
    _target.dispose();
    _currency.dispose();
    _purposes.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _saveTarget() {
    final v = int.tryParse(_target.text.trim());
    ref.read(appActionsProvider).setDailyTarget(v);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          v == null || v <= 0
              ? 'Daily target cleared'
              : 'Daily target set to $v clients',
        ),
      ),
    );
  }

  void _savePurposes() {
    ref.read(appActionsProvider).setRevenuePurposes(_purposes.text.split('\n'));
    final saved = ref.read(revenuePurposesProvider);
    _purposes.text = saved.join('\n');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${saved.length} payment purposes saved')),
    );
  }

  void _saveCurrency() {
    ref.read(appActionsProvider).setCurrency(_currency.text);
    final saved = ref.read(currencyProvider);
    _currency.text = saved;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Revenue shown in $saved')));
  }

  @override
  Widget build(BuildContext context) {
    final weeks = ref.watch(historyProvider);
    final themeMode = ref.watch(themeModeProvider);
    final target = ref.watch(dailyTargetProvider);
    final lastBackup = ref.watch(lastBackupProvider);
    final theme = Theme.of(context);
    if (!_targetSeeded) {
      _target.text = target?.toString() ?? '';
      _currency.text = ref.read(currencyProvider);
      _purposes.text = ref.read(revenuePurposesProvider).join('\n');
      _targetSeeded = true;
    }
    // The export dropdown follows the week list until the user picks one.
    final effectiveWeekId =
        _exportWeekId ?? (weeks.isNotEmpty ? weeks.first.week.id : null);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
      height: 1.45,
    );
    Widget spinnerOr(IconData icon) => _busy
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 16);

    final accounts = ref.watch(accountsEnabledProvider);
    final sections = <Widget>[
      _Section(
        title: 'Appearance',
        icon: Icons.palette_outlined,
        description:
            'Choose a theme, or follow your computer’s setting, and the text '
            'size on this device.',
        child: Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {themeMode},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  ref.read(themeModeProvider.notifier).set(s.first),
            ),
            const TextSizePicker(),
          ],
        ),
      ),
      _Section(
        title: 'Daily target',
        icon: Icons.flag_outlined,
        description:
            'How many clients a day the team aims for. Reports and Quick view '
            'show progress toward it. Leave empty for no target.',
        child: Row(
          children: [
            SizedBox(
              width: 140,
              child: TextField(
                controller: _target,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Clients per day',
                  isDense: true,
                ),
                onSubmitted: (_) => _saveTarget(),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(onPressed: _saveTarget, child: const Text('Save')),
          ],
        ),
      ),
      _Section(
        title: 'Revenue currency',
        icon: Icons.payments_outlined,
        description:
            'Shown before every revenue amount, e.g. KSh, USD or €. Leave '
            'empty for KSh.',
        child: Row(
          children: [
            SizedBox(
              width: 140,
              child: TextField(
                key: const ValueKey('currency-field'),
                controller: _currency,
                maxLength: 8,
                decoration: const InputDecoration(
                  labelText: 'Currency',
                  isDense: true,
                  counterText: '',
                ),
                onSubmitted: (_) => _saveCurrency(),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(onPressed: _saveCurrency, child: const Text('Save')),
          ],
        ),
      ),
      _Section(
        title: 'Payment purposes',
        icon: Icons.sell_outlined,
        description:
            'What payments can be for, one per line. Chosen when adding '
            'revenue; Insights shows the money by purpose.',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: TextField(
                  key: const ValueKey('purposes-field'),
                  controller: _purposes,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Purposes',
                    isDense: true,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(onPressed: _savePurposes, child: const Text('Save')),
          ],
        ),
      ),
      _Section(
        title: 'Backup & restore',
        icon: Icons.backup_outlined,
        description:
            'A backup is one .json file with all staff, weeks, numbers, notes '
            'and settings. Keep a copy off this device, and use Restore on '
            'another computer to move the data there.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: Dt.s8,
              runSpacing: Dt.s8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _busyWrap(() => backupToFile(context, ref)),
                  icon: spinnerOr(Icons.download_outlined),
                  label: const Text('Back up data'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: spinnerOr(Icons.restore),
                  label: const Text('Restore data'),
                ),
              ],
            ),
            const SizedBox(height: Dt.s8),
            Text(
              lastBackup == null
                  ? 'No backup saved from this device yet.'
                  : 'Last backup: '
                        '${DateFormat('d MMM y, HH:mm').format(lastBackup)}',
              style: muted,
            ),
          ],
        ),
      ),
      const _OnlineSyncSection(),
      _AutoBackupSection(onRestore: _restoreJson),
      _Section(
        title: 'Import from Excel',
        icon: Icons.upload_file_outlined,
        description:
            'Bring in past weeks from the old weekly spreadsheets (.xlsx): a '
            'section per day with Staff, New and Existing. You’ll see what was '
            'found and match names to staff before anything is saved.',
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _busyWrap(() => importFromExcel(context, ref)),
            icon: spinnerOr(Icons.upload_file_outlined),
            label: const Text('Choose .xlsx file'),
          ),
        ),
      ),
      _Section(
        title: 'Export a week to Excel',
        icon: Icons.table_view_outlined,
        description:
            'In the old spreadsheet layout: Monday–Friday sections with '
            'Staff / New / Existing, daily and weekly totals. Reports can also '
            'export any day, week or month.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              initialValue: effectiveWeekId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Week to export'),
              items: [
                for (final w in weeks)
                  DropdownMenuItem(
                    value: w.week.id,
                    child: Text(
                      _weekLabel(w.week),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _exportWeekId = v),
            ),
            const SizedBox(height: Dt.s12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: effectiveWeekId == null || _busy
                    ? null
                    : _exportWeek,
                icon: spinnerOr(Icons.download_outlined),
                label: const Text('Export .xlsx'),
              ),
            ),
          ],
        ),
      ),
      _Section(
        title: 'Change history',
        icon: Icons.manage_history,
        description:
            'Every change to a client number: whose day, from what to what, '
            'and when. Useful when a number looks wrong.',
        child: Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => showChangeHistory(context),
            icon: const Icon(Icons.manage_history, size: 16),
            label: const Text('View change history'),
          ),
        ),
      ),
      // Personal accounts replace the shared profiles and their passwords.
      if (accounts) const AirtableSection(),
      if (accounts) ...[
        const UsersSection(),
        const DepartmentsSection(),
      ] else ...[
        const _ProfilesSection(),
        _Section(
          title: 'Admin password',
          icon: Icons.key_outlined,
          description:
              'Needed to open the Admin profile (the admin portal: revenue '
              'and settings).',
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _changePassword,
              icon: const Icon(Icons.key_outlined, size: 16),
              label: const Text('Change admin password'),
            ),
          ),
        ),
      ],
      AboutSection(online: accounts),
    ];

    return LayoutBuilder(
      builder: (context, viewport) {
        final pad = clarityHPad(context);
        final twoColumns = viewport.maxWidth >= 900;
        return Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(pad, 18, pad, 28),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: Dt.contentMaxWidth,
                  ),
                  child: twoColumns
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _column(sections, even: true)),
                            const SizedBox(width: 12),
                            Expanded(child: _column(sections, even: false)),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final section in sections) ...[
                              section,
                              const SizedBox(height: 12),
                            ],
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Every other section, for the two-column layout.
  Widget _column(List<Widget> sections, {required bool even}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = even ? 0 : 1; i < sections.length; i += 2) ...[
        sections[i],
        const SizedBox(height: 12),
      ],
    ],
  );

  /// "October 5 – 9, 2026 (05/10 – 09/10)" — the mockup's dropdown label.
  String _weekLabel(Week w) =>
      '${DateFormat('MMMM d').format(w.startDate)} – '
      '${DateFormat('MMMM d, y').format(w.endDate)} '
      '(${DateFormat('dd/MM').format(w.startDate)} – '
      '${DateFormat('dd/MM').format(w.endDate)})';

  Future<void> _changePassword() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => const _PasswordDialog(),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Admin password changed')));
    }
  }

  Future<void> _busyWrap(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportWeek() => _busyWrap(() async {
    final weekId =
        _exportWeekId ??
        (ref.read(historyProvider).isNotEmpty
            ? ref.read(historyProvider).first.week.id
            : null);
    if (weekId == null) return;
    final week = ref.read(weekRepositoryProvider).getWeek(weekId);
    if (week == null) return;

    final result = ref.read(exportServiceProvider).exportWeek(week);
    final defaultName =
        'weekly_clients_${DateFormat('yyyyMMdd').format(week.startDate)}.xlsx';
    final saved = await saveFileBytes(
      dialogTitle: 'Export week to Excel',
      defaultName: defaultName,
      extensions: ['xlsx'],
      bytes: result.bytes,
    );
    if (saved == null) return; // user cancelled
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Exported to $saved')));
    }
  });

  Future<void> _restore() => _busyWrap(() async {
    final bytes = await openFileBytes(
      dialogTitle: 'Restore from backup',
      extensions: ['json'],
    );
    if (bytes == null) return;
    await _restoreJson(utf8.decode(bytes));
  });

  /// Confirms, then replaces all data with [json] (a backup's contents).
  Future<void> _restoreJson(String json, {String? from}) async {
    if (!mounted) return;

    // Double-confirm: restore replaces everything.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Replace all data?'),
        content: Text(
          '${from == null ? '' : 'Restore the backup from $from?\n\n'}'
          'Restoring will overwrite ALL current staff, weeks and counts '
          'with the backup contents. A safety copy of the current data '
          'is saved first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    ref.read(backupServiceProvider).restoreJson(json);
    ref.read(dataVersionProvider.notifier).bump();
    // The restored database has different week ids — clear the selection
    // so the dashboard/tracker fall back to the newest week instead of
    // pointing at an id that may no longer exist.
    ref.read(currentWeekIdProvider.notifier).set(null);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Data restored.')));
    }
  }
}

/// The online database: status, waiting changes, sync now, and the way out
/// when something can't be sent.
class _OnlineSyncSection extends ConsumerWidget {
  const _OnlineSyncSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(cloudSyncProvider);
    if (s.phase == SyncPhase.off) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final sync = ref.read(cloudSyncProvider.notifier);
    final (icon, color, label, tip) = describeSync(s, theme);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
      height: 1.45,
    );
    return _Section(
      title: 'Online sync',
      icon: Icons.cloud_outlined,
      description:
          'Numbers are saved on this device and sent to the online database '
          'within seconds, so every device — and your boss — sees them live. '
          'Without a connection everything keeps working and catches up '
          'later.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color ?? Dt.textMuted(theme)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(tip, style: muted),
          if (!s.adminLinked && !ref.watch(accountsEnabledProvider)) ...[
            const SizedBox(height: 4),
            Text(
              'This device isn’t signed in online yet — sign out and in '
              'again as admin to send changes.',
              style: muted,
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: Dt.s8,
            runSpacing: Dt.s8,
            children: [
              OutlinedButton.icon(
                onPressed: sync.syncNow,
                icon: const Icon(Icons.sync, size: 16),
                label: const Text('Sync now'),
              ),
              if (s.adminLinked && !ref.watch(accountsEnabledProvider))
                OutlinedButton.icon(
                  key: const ValueKey('create-recovery'),
                  onPressed: () => _createRecoveryCode(context, ref),
                  icon: const Icon(Icons.key_outlined, size: 16),
                  label: const Text('Recovery code'),
                ),
              if (s.phase == SyncPhase.error || s.pending > 0)
                TextButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Download a fresh copy?'),
                        content: Text(
                          s.pending == 0
                              ? 'This device’s data is replaced with the '
                                    'online data.'
                              : 'The ${s.pending} change(s) on this device '
                                    'that haven’t been sent will be lost, '
                                    'and the online data used instead.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Download'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) await sync.resetFromCloud();
                  },
                  child: const Text('Download fresh copy'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Makes a recovery code for a forgotten admin password and shows it once.
Future<void> _createRecoveryCode(BuildContext context, WidgetRef ref) async {
  final sync = ref.read(cloudSyncProvider.notifier);
  final had = await sync.hasRecoveryCode();
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Recovery code'),
      content: SizedBox(
        width: 420,
        child: Text(
          'If the admin password is ever forgotten, a recovery code lets you '
          'set a new one from the sign-in screen ("Forgot password?").\n\n'
          'The code is shown once. Write it down or keep it somewhere safe '
          'and private — anyone with it can set the admin password. Each '
          'code works once.'
          '${had == true ? '\n\nA code already exists: making a new one '
                    'replaces it.' : ''}',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(had == true ? 'Make a new code' : 'Make a code'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  final code = await sync.createRecoveryCode();
  if (!context.mounted) return;
  if (code == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Couldn’t make a code — check the connection, or sign in again.',
        ),
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Your recovery code'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(
              code,
              key: const ValueKey('recovery-code'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Write it down now. It won’t be shown again.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Clipboard.setData(ClipboardData(text: code)),
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('I’ve saved it'),
        ),
      ],
    ),
  );
}

/// Daily automatic backups: where they go, the latest ones, and Restore.
class _AutoBackupSection extends ConsumerWidget {
  const _AutoBackupSection({required this.onRestore});

  final Future<void> Function(String json, {String? from}) onRestore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(autoBackupProvider);
    final controller = ref.read(autoBackupProvider.notifier);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
      height: 1.45,
    );
    final browser = state.location == 'this browser';
    String when(DateTime t) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final day = DateTime(t.year, t.month, t.day);
      final time = DateFormat('HH:mm').format(t);
      if (day == today) return 'Today, $time';
      if (day == today.subtract(const Duration(days: 1))) {
        return 'Yesterday, $time';
      }
      return DateFormat('EEE d MMM y, HH:mm').format(t);
    }

    return _Section(
      title: 'Automatic backups',
      icon: Icons.schedule,
      description: browser
          ? 'A copy is kept inside this browser every day the app is used '
                '(the last ${state.keep}). It protects against mistakes, not '
                'against clearing the browser — keep saving backup files too.'
          : 'A backup is saved automatically every day the app is used, '
                'keeping the last ${state.keep} days.',
      child: !state.loaded
          ? const SizedBox(height: 20)
          : !state.enabled
          ? Text('Automatic backups are off on this device.', style: muted)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!browser) ...[
                  Text('Saved to', style: microLabel(theme)),
                  const SizedBox(height: 2),
                  SelectableText(
                    state.location,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                ],
                Wrap(
                  spacing: Dt.s8,
                  runSpacing: Dt.s8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await controller.backupNow();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              ok
                                  ? 'Backup saved'
                                  : 'Couldn’t save the backup here',
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.save_outlined, size: 16),
                      label: const Text('Back up now'),
                    ),
                    if (state.canChooseFolder)
                      OutlinedButton.icon(
                        onPressed: controller.chooseFolder,
                        icon: const Icon(Icons.folder_open_outlined, size: 16),
                        label: const Text('Change folder'),
                      ),
                    if (state.customFolder)
                      TextButton(
                        onPressed: controller.useDefaultFolder,
                        child: const Text('Use default folder'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (state.entries.isEmpty)
                  Text('No automatic backups yet.', style: muted)
                else ...[
                  Text('Latest', style: microLabel(theme)),
                  for (final e in state.entries.take(7))
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 15,
                            color: Dt.textMuted(theme),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              when(e.savedAt),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          Text('${(e.bytes / 1024).ceil()} KB', style: muted),
                          const SizedBox(width: 6),
                          TextButton(
                            onPressed: () async {
                              final json = await controller.read(e.id);
                              if (json == null) return;
                              await onRestore(json, from: when(e.savedAt));
                            },
                            child: const Text('Restore'),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}

/// One settings section: a panel with a short explanation and its control.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.description,
    this.child,
  });

  final String title;
  final IconData icon;
  final String description;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // Clarity: the description sits under the title, in the card head.
    return AppPanel(
      title: title,
      icon: icon,
      subtitle: description,
      child: child == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
              child: child!,
            ),
    );
  }
}

/// Changes the admin password. Asks for the current one first, so an
/// unattended signed-in screen can't be used to lock the owner out.
class _PasswordDialog extends ConsumerStatefulWidget {
  const _PasswordDialog();

  @override
  ConsumerState<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends ConsumerState<_PasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _save() {
    final auth = ref.read(authRepositoryProvider);
    const min = AuthRepository.minPasswordLength;
    String? error;
    if (!auth.verifyAdmin(_current.text)) {
      error = 'Current admin password is wrong.';
    } else if (_next.text.length < min) {
      error = 'Use at least $min characters.';
    } else if (_next.text != _confirm.text) {
      error = 'The passwords don’t match.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    auth.setAdminPassword(_next.text);
    // Same password online, so other devices keep working with it.
    ref.read(cloudSyncProvider.notifier).changePassword(_next.text);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change admin password'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _current,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Current admin password',
              ),
            ),
            const SizedBox(height: Dt.s12),
            TextField(
              controller: _next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            const SizedBox(height: Dt.s12),
            TextField(
              controller: _confirm,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Confirm new password',
                errorText: _error,
                errorMaxLines: 2,
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// Settings › Profiles: the admin gives Admin team, Director and Team a
/// password, or leaves them open (anyone can choose them at launch).
class _ProfilesSection extends ConsumerStatefulWidget {
  const _ProfilesSection();

  @override
  ConsumerState<_ProfilesSection> createState() => _ProfilesSectionState();
}

class _ProfilesSectionState extends ConsumerState<_ProfilesSection> {
  UserRole? _saving;

  /// Saves online first (so every device gets it), then on this device.
  Future<void> _save(UserRole role, String password) async {
    final messenger = ScaffoldMessenger.of(context);
    final sync = ref.read(cloudSyncProvider.notifier);
    setState(() => _saving = role);
    final online =
        !sync.enabled || await sync.setProfilePassword(role, password);
    if (!mounted) return;
    setState(() => _saving = null);
    if (!online) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Couldn’t save it online, so nothing was changed. Check the '
            'internet connection (and that the admin is signed in online), '
            'then try again.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
      return;
    }
    ref.read(authRepositoryProvider).setProfilePassword(role, password);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          password.isEmpty
              ? '${role.label} is open — no password needed'
              : '${role.label} password set',
        ),
      ),
    );
  }

  Future<void> _setPassword(UserRole role) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _ProfilePasswordDialog(role: role),
    );
    if (password != null && mounted) await _save(role, password);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = Dt.textMuted(theme);
    final auth = ref.read(authRepositoryProvider);
    return _Section(
      title: 'Profiles',
      icon: Icons.switch_account_outlined,
      description:
          'Everyone picks a profile when the app opens. Admin team enters '
          'and edits everything except revenue; Director views everything; '
          'Team views everything except revenue. Give a profile a password, '
          'or leave it open.',
      child: Column(
        children: [
          for (final role in UserRole.others) ...[
            if (role != UserRole.others.first)
              Divider(height: 1, color: theme.colorScheme.outline),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(
                    auth.isLocked(role)
                        ? Icons.lock_outline
                        : Icons.lock_open_outlined,
                    size: 18,
                    color: muted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(role.label, style: theme.textTheme.titleSmall),
                        Text(
                          auth.isLocked(role)
                              ? 'Password set'
                              : 'Open — no password',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_saving == role)
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else ...[
                    if (auth.isLocked(role))
                      TextButton(
                        key: ValueKey('profile-open-${role.name}'),
                        onPressed: _saving != null
                            ? null
                            : () => _save(role, ''),
                        child: const Text('Make open'),
                      ),
                    OutlinedButton(
                      key: ValueKey('profile-set-${role.name}'),
                      onPressed: _saving != null
                          ? null
                          : () => _setPassword(role),
                      child: Text(
                        auth.isLocked(role) ? 'Change' : 'Set password',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A new password for one profile, typed twice. Returns it.
class _ProfilePasswordDialog extends StatefulWidget {
  const _ProfilePasswordDialog({required this.role});
  final UserRole role;

  @override
  State<_ProfilePasswordDialog> createState() => _ProfilePasswordDialogState();
}

class _ProfilePasswordDialogState extends State<_ProfilePasswordDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final p = _first.text;
    if (p.length < AuthRepository.minPasswordLength) {
      setState(
        () => _error =
            'Use at least ${AuthRepository.minPasswordLength} characters.',
      );
      return;
    }
    if (p != _second.text) {
      setState(() => _error = 'The two passwords don’t match.');
      return;
    }
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.role.label} password'),
    content: SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('profile-new-password'),
            controller: _first,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password'),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('profile-new-password-again'),
            controller: _second,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Type it again',
              errorText: _error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('profile-save-password'),
        onPressed: _submit,
        child: const Text('Save'),
      ),
    ],
  );
}
