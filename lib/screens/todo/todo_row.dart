import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/todo_service.dart';
import 'todo_editor.dart' show todoDayLabel;
import 'todo_send.dart' show sentLabel;

/// "Due today 15:00", "Due Wed 18 Nov".
String todoDueLabel(TodoItem t) {
  final d = t.due!;
  var day = todoDayLabel(d);
  if (const {'Today', 'Tomorrow', 'Yesterday'}.contains(day)) {
    day = day.toLowerCase();
  }
  final time = t.dueTime ? ' ${DateFormat('HH:mm').format(d)}' : '';
  return 'Due $day$time';
}

/// What a row's menu can do.
enum TodoAction { edit, star, today, later, send, give, select, delete }

/// One to-do on the page.
class TodoRow extends StatelessWidget {
  const TodoRow({
    super.key,
    required this.item,
    required this.onToggle,
    required this.onOpen,
    required this.onAction,
    this.actions = const {},
    this.selecting = false,
    this.selected = false,
    this.focused = false,
    this.showDay = false,
    this.dragIndex,
    this.onClient,
    this.onSent,
  });

  final TodoItem item;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final ValueChanged<TodoAction> onAction;

  /// The menu's choices for this item.
  final Set<TodoAction> actions;
  final bool selecting;
  final bool selected;

  /// The keyboard cursor is on it.
  final bool focused;

  /// Says which day it's planned for (Later, From earlier).
  final bool showDay;

  /// Set: a handle to drag it to a new place (its index in the list).
  final int? dragIndex;
  final VoidCallback? onClient;
  final VoidCallback? onSent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final t = item;
    final small = theme.textTheme.labelSmall;
    final muted = small?.copyWith(color: c.textMuted);

    Widget meta(IconData icon, String text, {Color? color, Key? key}) => Row(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color ?? c.textMuted),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: small?.copyWith(color: color ?? c.textMuted),
          ),
        ),
      ],
    );

    Widget link(Widget child, VoidCallback? onTap, {Key? key}) => onTap == null
        ? child
        : InkWell(
            key: key,
            borderRadius: BorderRadius.circular(Dt.rPill),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: child,
            ),
          );

    final sent = sentLabel(t);
    final stepsDone = t.steps.where((s) => s.done).length;
    final details = <Widget>[
      if (t.isNew)
        Container(
          key: ValueKey('todo-new-${t.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(Dt.rPill),
          ),
          child: Text(
            'New',
            style: small?.copyWith(color: theme.colorScheme.onPrimary),
          ),
        ),
      if (t.fromName != null) meta(Icons.person_outline, 'From ${t.fromName}'),
      if (t.due != null)
        meta(
          t.overdue ? Icons.error_outline : Icons.schedule,
          todoDueLabel(t),
          color: t.overdue ? theme.colorScheme.error : null,
          key: ValueKey('todo-due-${t.id}'),
        ),
      if (showDay && t.planned != null && !t.done)
        meta(Icons.event_outlined, todoDayLabel(t.planned!)),
      if (showDay && t.later) meta(Icons.event_outlined, 'Some day'),
      if (t.repeat != TodoRepeat.none) meta(Icons.repeat, t.repeat.label),
      if (t.steps.isNotEmpty)
        meta(Icons.checklist, '$stepsDone/${t.steps.length}'),
      if (t.notes.isNotEmpty) meta(Icons.notes, 'Notes'),
      if (t.clientName != null)
        link(
          meta(
            Icons.school_outlined,
            t.clientName!,
            color: theme.colorScheme.primary,
          ),
          onClient,
          key: ValueKey('todo-client-${t.id}'),
        ),
      if (t.team && t.done && t.doneBy != null)
        meta(Icons.check, 'Done by ${t.doneBy}'),
      if (sent != null)
        link(
          meta(
            Icons.outbox_outlined,
            t.sentId! > 0 ? '#${t.sentId} · $sent' : sent,
            color: switch (t.reportReview) {
              'approved' => Dt.statusGreen(theme.brightness),
              'returned' => theme.colorScheme.error,
              _ => null,
            },
          ),
          t.sentId! > 0 ? onSent : null,
          key: ValueKey('todo-sent-${t.id}'),
        ),
    ];

    final tick = selecting
        ? Checkbox(
            key: ValueKey('todo-select-${t.id}'),
            value: selected,
            onChanged: (_) => onOpen(),
          )
        : Checkbox(
            key: ValueKey('todo-tick-${t.id}'),
            value: t.done,
            semanticLabel: t.title,
            shape: const CircleBorder(),
            onChanged: (_) => onToggle(),
          );

    final row = Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : focused
          ? c.track
          : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        onLongPress: selecting ? null : () => onAction(TodoAction.select),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
          child: Row(
            children: [
              if (dragIndex != null && !selecting)
                ReorderableDragStartListener(
                  index: dragIndex!,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Icon(
                      Icons.drag_indicator,
                      size: 16,
                      color: c.textMuted.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              tick,
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: t.done
                              ? c.textMuted
                              : t.overdue
                              ? theme.colorScheme.error
                              : null,
                          decoration: t.done
                              ? TextDecoration.lineThrough
                              : null,
                          fontWeight: t.isNew ? FontWeight.w600 : null,
                        ),
                      ),
                      if (details.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: details,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (!selecting)
                IconButton(
                  key: ValueKey('todo-star-${t.id}'),
                  tooltip: t.starred ? 'Unstar' : 'Star (keeps it at the top)',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onAction(TodoAction.star),
                  icon: Icon(
                    t.starred ? Icons.star : Icons.star_border,
                    size: 18,
                    color: t.starred
                        ? c.warningFg
                        : c.textMuted.withValues(alpha: 0.6),
                  ),
                ),
              if (!selecting)
                PopupMenuButton<TodoAction>(
                  key: ValueKey('todo-menu-${t.id}'),
                  tooltip: 'More',
                  icon: Icon(Icons.more_vert, size: 18, color: c.textMuted),
                  onSelected: onAction,
                  itemBuilder: (_) => [
                    for (final (a, text) in const [
                      (TodoAction.edit, 'Open'),
                      (TodoAction.today, 'Move to today'),
                      (TodoAction.later, 'Move to later'),
                      (TodoAction.send, 'Send to Daily reports'),
                      (TodoAction.give, 'Give to a colleague'),
                      (TodoAction.select, 'Select'),
                      (TodoAction.delete, 'Delete'),
                    ])
                      if (actions.contains(a))
                        PopupMenuItem(value: a, child: Text(text)),
                  ],
                ),
            ],
          ),
        ),
      ),
    );

    return Dismissible(
      key: ValueKey('todo-${t.key}'),
      direction: selecting
          ? DismissDirection.none
          : DismissDirection.horizontal,
      // Right: tick (it stays, ticked); left: delete.
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          onToggle();
          return false;
        }
        return true;
      },
      onDismissed: (_) => onAction(TodoAction.delete),
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 18),
        color: Dt.statusGreen(theme.brightness).withValues(alpha: 0.14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              t.done ? Icons.undo : Icons.check,
              color: Dt.statusGreen(theme.brightness),
            ),
            const SizedBox(width: 6),
            Text(
              t.done ? 'Not done' : 'Done',
              style: muted?.copyWith(color: Dt.statusGreen(theme.brightness)),
            ),
          ],
        ),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 18),
        color: theme.colorScheme.error.withValues(alpha: 0.12),
        child: Icon(Icons.delete_outline, color: theme.colorScheme.error),
      ),
      child: row,
    );
  }
}
