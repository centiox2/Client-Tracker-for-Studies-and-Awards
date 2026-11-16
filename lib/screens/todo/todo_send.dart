import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../services/daily_reports_service.dart';
import '../../services/todo_service.dart';
import '../../state/app_state.dart';
import '../daily_reports/report_editor.dart' show showReportDetails;

/// Whether this person can send to-dos to Daily reports (signed in, with
/// the Daily reports page).
bool canSendTodos(WidgetRef ref) {
  if (!ref.watch(accountsEnabledProvider)) return false;
  final user = ref.watch(currentUserProvider);
  return user != null && user.mayOpen(AppTab.dailyReports.name);
}

/// "Awaiting review", "Approved"… for an item sent to Daily reports.
String? sentLabel(TodoItem t) {
  if (!t.sent) return null;
  if (t.sentId! <= 0) return 'Waiting to send';
  return switch (t.reportReview) {
    'submitted' => 'Awaiting review',
    'approved' => 'Approved',
    'returned' => 'Returned',
    _ => t.reportStatus == null ? 'In Daily reports' : 'On your Daily list',
  };
}

/// Opens the Daily reports task a to-do was sent as.
Future<void> openSentTask(BuildContext context, WidgetRef ref, int id) async {
  final messenger = ScaffoldMessenger.of(context);
  final service = ref.read(dailyReportsProvider);
  try {
    final meta = ref.read(reportStartProvider)?.meta ?? await service.meta();
    final found = await service.list(ReportFilter(search: '#$id', limit: 1));
    final task = found.where((t) => t.id == id).firstOrNull;
    if (!context.mounted) return;
    if (task == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('That task has been deleted.')),
      );
      return;
    }
    await showReportDetails(context, meta: meta, report: task);
    ref.read(todoListProvider.notifier).refresh();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(describeReportError(e))));
  }
}

/// Chooses which to-dos go to Daily reports: ticked-off ones are submitted
/// for today (with their notes and counts); the rest go on the Daily
/// reports list as To do. Returns how many were sent.
Future<int?> showSendTodos(BuildContext context, List<TodoItem> items) =>
    showDialog<int>(
      context: context,
      builder: (_) => _SendDialog(items: items),
    );

class _SendDialog extends ConsumerStatefulWidget {
  const _SendDialog({required this.items});
  final List<TodoItem> items;

  @override
  ConsumerState<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends ConsumerState<_SendDialog> {
  late final Set<String> _chosen = {
    for (final t in widget.items)
      if (widget.items.length == 1 || t.done) t.key,
  };
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    if (_busy || _chosen.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outbox = ref.read(reportOutboxProvider.notifier);
    final list = ref.read(todoListProvider.notifier);
    var sent = 0;
    for (final t in widget.items) {
      if (!_chosen.contains(t.key)) continue;
      try {
        final o = await outbox.save(
          ActivityReport(
            description: t.title,
            details: [
              if (t.notes.isNotEmpty) t.notes,
              for (final s in t.steps)
                if (s.done) '✓ ${s.title}',
            ].join('\n'),
            outputs: t.done ? t.outputs : const {},
            status: t.done ? ReportStatus.done : ReportStatus.toDo,
            dueDate: t.done || t.due == null ? null : dateOnly(t.due!),
          ),
          submit: t.done,
        );
        list.markSent(t.key, o.task.id ?? -1);
        _chosen.remove(t.key);
        sent++;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error =
              '“${t.title}”: ${describeReportError(e)}'
              '${sent == 0 ? '' : ' The others were sent.'}';
        });
        return;
      }
    }
    if (mounted) Navigator.pop(context, sent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final n = _chosen.length;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _go,
      },
      child: AlertDialog(
        title: const Text('Send to Daily reports'),
        scrollable: true,
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Done items are submitted for today and go for review, '
                'with their notes and counts. The others go on your Daily '
                'reports list as To do.',
                style: muted,
              ),
              const SizedBox(height: 8),
              for (final t in widget.items)
                CheckboxListTile(
                  key: ValueKey('todo-send-${t.id}'),
                  value: _chosen.contains(t.key),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: _busy
                      ? null
                      : (on) => setState(
                          () => on == true
                              ? _chosen.add(t.key)
                              : _chosen.remove(t.key),
                        ),
                  title: Text(t.title),
                  subtitle: Text(
                    t.done ? 'Done · submitted for review' : 'To do',
                    style: muted?.copyWith(
                      color: t.done ? Dt.statusGreen(theme.brightness) : null,
                    ),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const ValueKey('todo-send-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            key: const ValueKey('todo-send-confirm'),
            onPressed: _busy || n == 0 ? null : _go,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send, size: 16),
            label: Text(n == 0 ? 'Send' : 'Send $n'),
          ),
        ],
      ),
    );
  }
}
