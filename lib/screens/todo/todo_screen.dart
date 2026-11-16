import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../services/daily_reports_service.dart';
import '../../services/todo_service.dart';
import '../../state/app_state.dart';
import '../../widgets/clarity.dart';
import '../../widgets/empty_state.dart';
import '../daily_reports/report_editor.dart' show reportSnack;
import '../daily_reports/task_composer.dart' show LinesFormatter;

/// Whether this person can send to-dos to Daily reports (signed in, with
/// the Daily reports page).
bool canSendTodos(WidgetRef ref) {
  if (!ref.watch(accountsEnabledProvider)) return false;
  final user = ref.watch(currentUserProvider);
  return user != null && user.mayOpen(AppTab.dailyReports.name);
}

/// A personal to-do list for the day: saved with the person's account (the
/// same on all their devices), or on this device when not signed in. Items
/// go to Daily reports only when the person sends them.
class TodoScreen extends ConsumerStatefulWidget {
  const TodoScreen({super.key});

  @override
  ConsumerState<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends ConsumerState<TodoScreen> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode(debugLabel: 'todo input');
  Timer? _live;

  @override
  void initState() {
    super.initState();
    // Changes made on another device show up while the page is open.
    Future.microtask(() {
      if (mounted) ref.read(todoListProvider.notifier).refresh();
    });
    _live = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) ref.read(todoListProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _live?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  TodoListNotifier get _list => ref.read(todoListProvider.notifier);

  void _addInput() {
    _addLines([_input.text]);
    _inputFocus.requestFocus();
  }

  void _addLines(List<String> lines) {
    _list.add(lines);
    _input.clear();
  }

  void _delete(TodoItem t) {
    final gone = _list.remove([t.id]);
    reportSnack(
      ScaffoldMessenger.of(context),
      'Deleted “${t.title}”',
      onUndo: () => _list.restore(gone),
    );
  }

  void _clearDone() {
    final done = [
      for (final t in ref.read(todoListProvider))
        if (t.done) t.id,
    ];
    final gone = _list.remove(done);
    reportSnack(
      ScaffoldMessenger.of(context),
      'Cleared ${gone.length} done',
      onUndo: () => _list.restore(gone),
    );
  }

  Future<void> _rename(TodoItem t) async {
    final controller = TextEditingController(text: t.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit to-do'),
        content: SizedBox(
          width: 420,
          child: TextField(
            key: const ValueKey('todo-edit-field'),
            controller: controller,
            autofocus: true,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(counterText: ''),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('todo-edit-save'),
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title != null) _list.rename(t.id, title);
  }

  Future<void> _send(List<TodoItem> preselected) async {
    final sent = await showDialog<int>(
      context: context,
      builder: (_) => _SendDialog(preselected: preselected),
    );
    if (sent == null || sent == 0 || !mounted) return;
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Sent $sent to Daily reports. They stay on this list too, '
          'marked as sent.',
        ),
        persist: false,
        action: SnackBarAction(
          key: const ValueKey('todo-open-reports'),
          label: 'Open',
          onPressed: () =>
              ref.read(appActionsProvider).selectTab(AppTab.dailyReports),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final items = ref.watch(todoListProvider);
    final sync = ref.read(todoListProvider.notifier).sync;
    final canSend = canSendTodos(ref);
    final open = [
      for (final t in items)
        if (!t.done) t,
    ];
    final done = [
      for (final t in items)
        if (t.done) t,
    ];
    final unsent = items.where((t) => !t.sent).toList();
    final pad = clarityHPad(context);

    final input = Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Row(
        children: [
          Icon(Icons.add, size: 18, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('todo-input'),
              controller: _input,
              focusNode: _inputFocus,
              minLines: 1,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              inputFormatters: [
                LinesFormatter(onEnter: _addInput, onLines: _addLines),
              ],
              onSubmitted: (_) => _addInput(),
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: 'Add a to-do and press Enter',
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('todo-add'),
            tooltip: 'Add (Enter)',
            visualDensity: VisualDensity.compact,
            onPressed: _addInput,
            icon: const Icon(Icons.keyboard_return, size: 18),
          ),
        ],
      ),
    );

    Widget section(String title, List<TodoItem> list, {Widget? trailing}) =>
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border.all(color: c.border),
                  borderRadius: BorderRadius.circular(Dt.rMd),
                ),
                child: Column(
                  children: [
                    for (final (i, t) in list.indexed) ...[
                      if (i > 0) Divider(height: 1, color: c.border),
                      _TodoRow(
                        item: t,
                        canSend: canSend,
                        onToggle: () => _list.toggle(t.id),
                        onEdit: () => _rename(t),
                        onDelete: () => _delete(t),
                        onSend: () => _send([t]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(pad, 14, pad, 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    switch (sync) {
                      TodoSync.device => Icons.smartphone_outlined,
                      TodoSync.saved => Icons.cloud_done_outlined,
                      TodoSync.pending => Icons.cloud_upload_outlined,
                      TodoSync.offline => Icons.cloud_off_outlined,
                    },
                    size: 15,
                    color: sync == TodoSync.offline ? c.warningFg : c.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      switch (sync) {
                        TodoSync.device =>
                          'Kept on this device. Sign in to have it on all '
                              'your devices.',
                        TodoSync.saved =>
                          'Your own list, the same on all your devices.',
                        TodoSync.pending => 'Saving…',
                        TodoSync.offline =>
                          'Offline: changes are kept here and saved when '
                              'you’re back online.',
                      },
                      key: const ValueKey('todo-sync'),
                      style: muted?.copyWith(
                        color: sync == TodoSync.offline ? c.warningFg : null,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              input,
              if (items.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${open.length} to do · ${done.length} done',
                      key: const ValueKey('todo-summary'),
                      style: muted,
                    ),
                    if (canSend && unsent.isNotEmpty)
                      OutlinedButton.icon(
                        key: const ValueKey('todo-send'),
                        onPressed: () => _send(unsent),
                        icon: const Icon(Icons.outbox_outlined, size: 16),
                        label: const Text('Send to Daily reports'),
                      ),
                  ],
                ),
              ],
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: PanelEmpty(
                    icon: Icons.checklist_outlined,
                    title: 'Nothing on your list',
                    message:
                        'Write down what you plan to do today. Tick things '
                        'off as you go.',
                  ),
                ),
              if (open.isNotEmpty) section('To do (${open.length})', open),
              if (done.isNotEmpty)
                section(
                  'Done (${done.length})',
                  done,
                  trailing: TextButton(
                    key: const ValueKey('todo-clear-done'),
                    onPressed: _clearDone,
                    child: const Text('Clear done'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({
    required this.item,
    required this.canSend,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onSend,
  });

  final TodoItem item;
  final bool canSend;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final t = item;
    return Dismissible(
      key: ValueKey('todo-${t.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 18),
        color: theme.colorScheme.error.withValues(alpha: 0.12),
        child: Icon(Icons.delete_outline, color: theme.colorScheme.error),
      ),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 2, 2),
          child: Row(
            children: [
              Checkbox(
                key: ValueKey('todo-tick-${t.id}'),
                value: t.done,
                semanticLabel: t.title,
                onChanged: (_) => onToggle(),
              ),
              Expanded(
                child: Text(
                  t.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: t.done ? c.textMuted : null,
                    decoration: t.done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              if (t.sent)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Tooltip(
                    message: t.sentId! > 0
                        ? 'Sent to Daily reports as #${t.sentId}'
                        : 'Sent to Daily reports (waiting for the internet)',
                    child: Row(
                      key: ValueKey('todo-sent-${t.id}'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.outbox_outlined,
                          size: 14,
                          color: c.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          t.sentId! > 0 ? '#${t.sentId}' : 'Sent',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: c.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              PopupMenuButton<String>(
                key: ValueKey('todo-menu-${t.id}'),
                tooltip: 'More',
                icon: Icon(Icons.more_vert, size: 18, color: c.textMuted),
                onSelected: (v) => switch (v) {
                  'edit' => onEdit(),
                  'send' => onSend(),
                  _ => onDelete(),
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  if (canSend && !t.sent)
                    const PopupMenuItem(
                      value: 'send',
                      child: Text('Send to Daily reports'),
                    ),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chooses which to-dos go to Daily reports: ticked-off ones are submitted
/// as done today; the rest go on the Daily reports list as To do. Returns
/// how many were sent.
class _SendDialog extends ConsumerStatefulWidget {
  const _SendDialog({required this.preselected});
  final List<TodoItem> preselected;

  @override
  ConsumerState<_SendDialog> createState() => _SendDialogState();
}

class _SendDialogState extends ConsumerState<_SendDialog> {
  late final Set<int> _chosen = {
    for (final t in widget.preselected)
      if (widget.preselected.length == 1 || t.done) t.id,
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
    for (final t in widget.preselected) {
      if (!_chosen.contains(t.id)) continue;
      try {
        final o = await outbox.save(
          ActivityReport(
            description: t.title,
            status: t.done ? ReportStatus.done : ReportStatus.toDo,
          ),
          submit: t.done,
        );
        list.markSent(t.id, o.task.id ?? -1);
        sent++;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error =
              '“${t.title}”: ${describeReportError(e)}'
              '${sent == 0 ? '' : ' The others were sent.'}';
          _chosen.removeWhere(
            (id) => ref.read(todoListProvider).any((x) => x.id == id && x.sent),
          );
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
                'Done items are submitted for today and go for review. '
                'The others go on your Daily reports list as To do.',
                style: muted,
              ),
              const SizedBox(height: 8),
              for (final t in widget.preselected)
                CheckboxListTile(
                  key: ValueKey('todo-send-${t.id}'),
                  value: _chosen.contains(t.id),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: _busy
                      ? null
                      : (on) => setState(
                          () => on == true
                              ? _chosen.add(t.id)
                              : _chosen.remove(t.id),
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
