import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../design/app_theme.dart';
import '../../services/todo_service.dart';
import '../../state/app_state.dart';
import 'todo_editor.dart' show todoDayLabel;
import 'todo_send.dart' show canSendTodos;

/// Adds a to-do from anywhere (the + in the top bar, the T key, a client's
/// card). [title] starts the box; [clientKey]/[clientName] link a client.
Future<void> showQuickTodo(
  BuildContext context, {
  String title = '',
  String? clientKey,
  String? clientName,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _QuickTodo(title: title, clientKey: clientKey, clientName: clientName),
);

class _QuickTodo extends ConsumerStatefulWidget {
  const _QuickTodo({required this.title, this.clientKey, this.clientName});
  final String title;
  final String? clientKey;
  final String? clientName;

  @override
  ConsumerState<_QuickTodo> createState() => _QuickTodoState();
}

class _QuickTodoState extends ConsumerState<_QuickTodo> {
  late final _text = TextEditingController(text: widget.title);

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _add() {
    final line = _text.text.trim();
    if (line.isEmpty) return;
    final list = ref.read(todoListProvider.notifier);
    final d = parseTodoLine(line, allowTeam: list.teamName != null);
    final item = list.add(
      TodoItem(
        id: 0,
        title: d.title.length > 300 ? d.title.substring(0, 300) : d.title,
        team: d.team,
        day: d.day,
        later: d.later,
        due: d.due,
        dueTime: d.dueTime,
        starred: d.starred,
        repeat: d.repeat,
        clientKey: widget.clientKey,
        clientName: widget.clientName,
      ),
    );
    final messenger = ScaffoldMessenger.of(context);
    final actions = ref.read(appActionsProvider);
    final onTodo = ref.read(navTabProvider) == AppTab.todo;
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Added “${item.title}” to your to-do list'),
        persist: false,
        action: onTodo
            ? null
            : SnackBarAction(
                key: const ValueKey('quick-todo-open'),
                label: 'Open',
                onPressed: () => actions.selectTab(AppTab.todo),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final list = ref.read(todoListProvider.notifier);
    final d = _text.text.trim().isEmpty
        ? null
        : parseTodoLine(_text.text, allowTeam: list.teamName != null);
    return AlertDialog(
      title: const Text('Add a to-do'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.clientName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(Icons.school_outlined, size: 16, color: c.textMuted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Linked to ${widget.clientName}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: c.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            TextField(
              key: const ValueKey('quick-todo-input'),
              controller: _text,
              autofocus: true,
              maxLength: 300,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'e.g. Call the embassy tomorrow 3pm !',
                counterText: '',
              ),
              onSubmitted: (_) => _add(),
            ),
            const SizedBox(height: 6),
            Text(
              d != null && d.understood
                  ? [
                      if (d.team) 'Team list',
                      if (d.later) 'Later',
                      if (d.day != null) todoDayLabel(d.day!),
                      if (d.due != null) 'with a deadline',
                      if (d.repeat != TodoRepeat.none) d.repeat.label,
                      if (d.starred) 'starred',
                    ].join(' · ')
                  : 'Words like tomorrow, friday, 3pm, by monday, daily, '
                        'later and ! are understood.',
              key: const ValueKey('quick-todo-understood'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: d != null && d.understood
                    ? theme.colorScheme.primary
                    : c.textMuted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('quick-todo-add'),
          onPressed: _text.text.trim().isEmpty ? null : _add,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// The + in the top bar: add a to-do from any page.
class QuickTodoButton extends StatelessWidget {
  const QuickTodoButton({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('quick-todo'),
    tooltip: 'Add a to-do (T)',
    visualDensity: compact ? VisualDensity.compact : null,
    onPressed: () => showQuickTodo(context),
    icon: Icon(Icons.add_task, size: compact ? 21 : 20),
  );
}

/// Once a day, at the time the person chose, offers to send what they
/// finished to Daily reports. [show] puts the message up.
class TodoReminder {
  TodoReminder(this.ref, this.show);
  final WidgetRef ref;
  final void Function(String text, VoidCallback onSend) show;
  Timer? _timer;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => check());
  }

  void stop() => _timer?.cancel();

  Future<void> check() async {
    if (!canSendTodos(ref)) return;
    final minutes = ref.read(todoPrefsProvider).reminderMinutes;
    if (minutes == null) return;
    final now = todoClock();
    if (now.hour * 60 + now.minute < minutes) return;
    final today = todoToday();
    final ready = [
      for (final t in ref.read(todoListProvider))
        if (!t.team &&
            t.done &&
            !t.sent &&
            t.doneAt != null &&
            dateOnly(t.doneAt!) == today)
          t,
    ];
    if (ready.isEmpty) return;
    final user = ref.read(currentUserProvider)?.id;
    final key = 'todo_reminded_${user ?? 'device'}';
    final prefs = await SharedPreferences.getInstance();
    final stamp = today.toIso8601String().substring(0, 10);
    if (prefs.getString(key) == stamp) return;
    await prefs.setString(key, stamp);
    show(
      'You finished ${ready.length} thing${ready.length == 1 ? '' : 's'} '
      'today. Send ${ready.length == 1 ? 'it' : 'them'} to Daily reports?',
      () {
        ref.read(appActionsProvider).selectTab(AppTab.todo);
        ref.read(todoSendRequestProvider.notifier).request();
      },
    );
  }
}

/// How many to-dos colleagues gave you that you haven't looked at: a count
/// on [child] (or alone, beside a menu label).
class TodoNewBadge extends ConsumerWidget {
  const TodoNewBadge({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(
      todoListProvider.select((l) => l.where((t) => t.isNew).length),
    );
    if (child != null) {
      return Badge.count(
        key: n > 0 ? const ValueKey('todo-new-count') : null,
        count: n,
        isLabelVisible: n > 0,
        child: child,
      );
    }
    if (n == 0) return const SizedBox.shrink();
    return Tooltip(
      message: 'Given to you by a colleague',
      child: Badge.count(key: const ValueKey('todo-new-count'), count: n),
    );
  }
}
