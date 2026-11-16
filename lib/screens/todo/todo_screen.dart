import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/todo_service.dart';
import '../../state/app_state.dart';
import '../../widgets/clarity.dart';
import '../../widgets/empty_state.dart';
import '../applications/applications_screen.dart' show showApplicationDetails;
import '../daily_reports/report_editor.dart' show reportSnack;
import '../daily_reports/task_composer.dart' show LinesFormatter;
import 'todo_editor.dart';
import 'todo_row.dart';
import 'todo_send.dart';

export 'todo_send.dart' show canSendTodos;

/// The to-do page: your own list (the same on all your devices when signed
/// in) and your department's shared list. Items go to Daily reports only
/// when you send them.
class TodoScreen extends ConsumerStatefulWidget {
  const TodoScreen({super.key});

  @override
  ConsumerState<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends ConsumerState<TodoScreen> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode(debugLabel: 'todo input');
  final _pageFocus = FocusNode(debugLabel: 'todo page');
  Timer? _live;
  Timer? _seen;
  bool _history = false;
  bool _toTeam = false;

  // Chosen beside the box for what's added next (typed words win).
  DateTime? _optDay;
  bool _optLater = false;
  DateTime? _optDue;
  bool _optDueTime = false;
  TodoRepeat _optRepeat = TodoRepeat.none;
  bool _optStar = false;
  bool _optNotesOpen = false;
  final _optNotes = TextEditingController();
  bool _showLater = false;
  final _selected = <String>{};
  bool _selecting = false;
  String? _cursor;

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
    _inputFocus.addListener(() => setState(() {}));
    _optNotes.addListener(() => setState(() {}));
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
    _seen?.cancel();
    _input.dispose();
    _optNotes.dispose();
    _inputFocus.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  TodoListNotifier get _list => ref.read(todoListProvider.notifier);

  // ------------------------------------------------------------ Actions ---

  void _addInput() {
    _addLines([_input.text]);
    _inputFocus.requestFocus();
  }

  void _addLines(List<String> lines) {
    final added = _list.addLines(lines, team: _toTeam, shape: _shape);
    _input.clear();
    if (added.isNotEmpty) _resetOptions();
  }

  bool get _optionsSet =>
      _optDay != null ||
      _optLater ||
      _optDue != null ||
      _optRepeat != TodoRepeat.none ||
      _optStar ||
      _optNotes.text.trim().isNotEmpty;

  void _resetOptions() => setState(() {
    _optDay = null;
    _optLater = false;
    _optDue = null;
    _optDueTime = false;
    _optRepeat = TodoRepeat.none;
    _optStar = false;
    _optNotesOpen = false;
    _optNotes.clear();
  });

  /// Adds what was chosen beside the box; words typed in the line win.
  TodoItem _shape(TodoItem t, TodoDraft typed) {
    final typedDay = typed.later || typed.day != null;
    final notes = _optNotes.text.trim();
    return t.copyWith(
      day: typedDay ? t.day : (_optLater ? null : (_optDay ?? t.day)),
      later: typedDay ? t.later : _optLater,
      due: typed.due ?? _optDue,
      dueTime: typed.due != null ? typed.dueTime : _optDueTime,
      repeat: typed.repeat != TodoRepeat.none ? typed.repeat : _optRepeat,
      starred: typed.starred || _optStar,
      notes: notes.isEmpty ? t.notes : notes,
    );
  }

  Future<void> _pickOptDay() async {
    final today = todoToday();
    final d = await showDatePicker(
      context: context,
      initialDate: _optDay ?? today,
      firstDate: today,
      lastDate: DateTime(today.year + 2),
    );
    if (d != null) {
      setState(() {
        _optDay = d;
        _optLater = false;
      });
    }
    _inputFocus.requestFocus();
  }

  Future<void> _pickOptDue() async {
    final today = todoToday();
    final d = await showDatePicker(
      context: context,
      initialDate: _optDue ?? _optDay ?? today,
      firstDate: today,
      lastDate: DateTime(today.year + 2),
      helpText: 'Deadline',
    );
    if (d == null || !mounted) {
      _inputFocus.requestFocus();
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 17, minute: 0),
      helpText: 'Deadline time (Cancel for none)',
    );
    setState(() {
      _optDue = time == null
          ? d
          : DateTime(d.year, d.month, d.day, time.hour, time.minute);
      _optDueTime = time != null;
    });
    _inputFocus.requestFocus();
  }

  /// The full form for a new item, with what's typed and chosen so far.
  Future<void> _addWithForm() async {
    final line = _input.text.trim();
    final d = parseTodoLine(line, allowTeam: _list.teamName != null);
    final today = todoToday();
    final draft = _shape(
      TodoItem(
        id: 0,
        title: line.isEmpty ? '' : d.title,
        team: _toTeam || d.team,
        day: d.later ? null : (d.day ?? today),
        later: d.later,
        due: d.due,
        dueTime: d.dueTime,
        starred: d.starred,
        repeat: d.repeat,
      ),
      d,
    );
    final added = await showTodoEditor(context, ref, draft, isNew: true);
    if (!mounted) return;
    if (added) {
      _input.clear();
      _resetOptions();
    }
    _inputFocus.requestFocus();
  }

  void _delete(Iterable<String> keys) {
    final gone = _list.remove(keys);
    if (gone.isEmpty) return;
    reportSnack(
      ScaffoldMessenger.of(context),
      gone.length == 1
          ? 'Deleted “${gone.single.$2.title}”'
          : 'Deleted ${gone.length}',
      onUndo: () => _list.restore(gone),
    );
  }

  void _clearDone(List<TodoItem> done) {
    final gone = _list.archive([for (final t in done) t.key]);
    reportSnack(
      ScaffoldMessenger.of(context),
      'Cleared ${gone.length} done (still in History)',
      onUndo: () => _list.restore(gone),
    );
  }

  Future<void> _send(List<TodoItem> items) async {
    final sent = await showSendTodos(context, items);
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

  void _openClient(TodoItem t) {
    final app = ref
        .read(applicationRepositoryProvider)
        .all()
        .where((a) => a.key == t.clientKey)
        .firstOrNull;
    if (app == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${t.clientName} isn’t in Applications now.')),
      );
      return;
    }
    showApplicationDetails(context, ref, app);
  }

  Future<void> _giveOne(TodoItem t) => giveTodo(context, ref, t);

  void _act(TodoItem t, TodoAction a) {
    switch (a) {
      case TodoAction.edit:
        showTodoEditor(context, ref, t);
      case TodoAction.star:
        _list.star(t.key);
      case TodoAction.today:
        _list.moveToToday([t.key]);
      case TodoAction.later:
        _list.moveToLater([t.key]);
      case TodoAction.send:
        _send([t]);
      case TodoAction.give:
        _giveOne(t);
      case TodoAction.select:
        setState(() {
          _selecting = true;
          _selected.add(t.key);
        });
      case TodoAction.delete:
        _delete([t.key]);
    }
  }

  void _endSelect() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  // ---------------------------------------------------------- Keyboard ---

  /// Up/Down move, Space ticks, Enter or E opens, S stars, Delete deletes,
  /// X selects, N or / goes to the box at the top.
  KeyEventResult _key(KeyEvent e, List<TodoItem> visible) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.keyN || k == LogicalKeyboardKey.slash) {
      _inputFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (visible.isEmpty) return KeyEventResult.ignored;
    final i = visible.indexWhere((t) => t.key == _cursor);
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final down = k == LogicalKeyboardKey.arrowDown;
      final next = i < 0
          ? (down ? 0 : visible.length - 1)
          : (i + (down ? 1 : -1)).clamp(0, visible.length - 1);
      setState(() => _cursor = visible[next].key);
      return KeyEventResult.handled;
    }
    if (i < 0) return KeyEventResult.ignored;
    final t = visible[i];
    if (k == LogicalKeyboardKey.space) {
      if (_selecting) {
        setState(
          () => _selected.contains(t.key)
              ? _selected.remove(t.key)
              : _selected.add(t.key),
        );
      } else {
        _list.toggle(t.key);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.keyE) {
      showTodoEditor(context, ref, t);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyS) {
      _list.star(t.key);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyX) {
      setState(() {
        _selecting = true;
        _selected.contains(t.key)
            ? _selected.remove(t.key)
            : _selected.add(t.key);
      });
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      final after = i + 1 < visible.length
          ? visible[i + 1].key
          : (i > 0 ? visible[i - 1].key : null);
      _delete([t.key]);
      setState(() => _cursor = after);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && _selecting) {
      _endSelect();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // -------------------------------------------------------------- Build ---

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final all = ref.watch(todoListProvider);
    ref.watch(todoPrefsProvider);
    final list = ref.read(todoListProvider.notifier);
    final sync = list.sync;
    final teamName = list.teamName;
    final canSend = canSendTodos(ref);
    final online = sync != TodoSync.device;
    final pad = clarityHPad(context);
    final today = todoToday();
    final yesterday = DateTime(today.year, today.month, today.day - 1);

    // The end-of-day reminder's Review: open Send with today's done items.
    if (ref.watch(todoSendRequestProvider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !ref.read(todoSendRequestProvider.notifier).take()) {
          return;
        }
        final ready = [
          for (final t in ref.read(todoListProvider))
            if (!t.team && t.done && !t.sent) t,
        ];
        if (ready.isNotEmpty) _send(ready);
      });
    }

    // Given to you: marked seen a moment after you've looked.
    if (all.any((t) => t.isNew) && _seen == null) {
      _seen = Timer(const Duration(seconds: 4), () {
        _seen = null;
        if (mounted) list.markSeen();
      });
    }

    // Order: starred first, then where it was put.
    int byPlace(TodoItem a, TodoItem b) {
      if (a.starred != b.starred) return a.starred ? -1 : 1;
      return a.order.compareTo(b.order);
    }

    final live = [
      for (final t in all)
        if (!t.archived) t,
    ];
    final mine = [
      for (final t in live)
        if (!t.team) t,
    ];
    final team = [
      for (final t in live)
        if (t.team && (!t.done || dateOnly(t.doneAt ?? today) == today)) t,
    ]..sort(byPlace);
    final overdue = [
      for (final t in mine)
        if (t.overdue) t,
    ]..sort((a, b) => a.due!.compareTo(b.due!));
    final open = [
      for (final t in mine)
        if (!t.done && !t.overdue) t,
    ];
    final earlier = [
      for (final t in open)
        if (t.planned != null && t.planned!.isBefore(today)) t,
    ]..sort(byPlace);
    final todayItems = [
      for (final t in open)
        if (t.planned != null && t.planned == today) t,
    ]..sort(byPlace);
    final later =
        [
          for (final t in open)
            if (t.planned == null || t.planned!.isAfter(today)) t,
        ]..sort((a, b) {
          final x = a.planned, y = b.planned;
          if (x != y) {
            if (x == null) return 1;
            if (y == null) return -1;
            return x.compareTo(y);
          }
          return byPlace(a, b);
        });
    final done = [
      for (final t in mine)
        if (t.done) t,
    ]..sort((a, b) => (b.doneAt ?? today).compareTo(a.doneAt ?? today));
    final doneToday = [
      for (final t in done)
        if (t.doneAt != null && dateOnly(t.doneAt!) == today) t,
    ];
    final unsent = [
      for (final t in mine)
        if (!t.sent && (t.done ? dateOnly(t.doneAt ?? today) == today : true))
          t,
    ];
    final planned = doneToday.length + todayItems.length + overdue.length;

    // What the keyboard moves through, top to bottom.
    final visible = [
      ...earlier,
      ...overdue,
      ...todayItems,
      ...team,
      if (_showLater) ...later,
      ...done,
    ];
    if (_cursor != null && !visible.any((t) => t.key == _cursor)) {
      _cursor = null;
    }
    _selected.removeWhere((k) => !all.any((t) => t.key == k));

    Set<TodoAction> actionsFor(TodoItem t) => {
      TodoAction.edit,
      if (!t.done && (t.later || (t.planned ?? today) != today))
        TodoAction.today,
      if (!t.done && !t.later) TodoAction.later,
      if (canSend && !t.team && !t.sent) TodoAction.send,
      if (online && !t.team) TodoAction.give,
      TodoAction.select,
      TodoAction.delete,
    };

    Widget row(TodoItem t, {bool showDay = false, int? dragIndex}) => TodoRow(
      key: ValueKey('row-${t.key}'),
      item: t,
      actions: actionsFor(t),
      selecting: _selecting,
      selected: _selected.contains(t.key),
      focused: _cursor == t.key,
      showDay: showDay,
      dragIndex: dragIndex,
      onToggle: () => _list.toggle(t.key),
      onOpen: () {
        if (_selecting) {
          setState(
            () => _selected.contains(t.key)
                ? _selected.remove(t.key)
                : _selected.add(t.key),
          );
        } else {
          setState(() => _cursor = t.key);
          showTodoEditor(context, ref, t);
        }
      },
      onAction: (a) => _act(t, a),
      onClient: t.clientKey == null ? null : () => _openClient(t),
      onSent: canSend && t.sentId != null && t.sentId! > 0
          ? () => openSentTask(context, ref, t.sentId!)
          : null,
    );

    Widget card(List<Widget> rows) => Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) Divider(height: 1, color: c.border),
            r,
          ],
        ],
      ),
    );

    Widget heading(
      String text, {
      Key? key,
      Color? color,
      IconData? icon,
      List<Widget> trailing = const [],
    }) => Padding(
      padding: const EdgeInsets.only(top: 18, left: 2, bottom: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: color ?? c.textSecondary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              text,
              key: key,
              style: theme.textTheme.titleSmall?.copyWith(
                color: color ?? c.textSecondary,
              ),
            ),
          ),
          ...trailing,
        ],
      ),
    );

    // Today: drag the handle to put things in order.
    final todayList = ReorderableListView.builder(
      key: const ValueKey('todo-today-list'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: todayItems.length,
      proxyDecorator: (child, _, _) =>
          Material(elevation: 4, color: c.surface, child: child),
      onReorderItem: (from, to) {
        final keys = [for (final t in todayItems) t.key];
        final moved = keys.removeAt(from);
        keys.insert(to, moved);
        _list.place(
          moved,
          before: to > 0 ? keys[to - 1] : null,
          after: to + 1 < keys.length ? keys[to + 1] : null,
        );
      },
      itemBuilder: (context, i) => Column(
        key: ValueKey('drag-${todayItems[i].key}'),
        children: [
          if (i > 0) Divider(height: 1, color: c.border),
          row(todayItems[i], dragIndex: i),
        ],
      ),
    );

    final syncLine = Row(
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
                'Kept on this device. Sign in to have it on all your devices.',
              TodoSync.saved => 'The same on all your devices.',
              TodoSync.pending => 'Saving…',
              TodoSync.offline =>
                'Offline: changes are kept here and saved when you’re back '
                    'online.',
            },
            key: const ValueKey('todo-sync'),
            style: muted?.copyWith(
              color: sync == TodoSync.offline ? c.warningFg : null,
            ),
          ),
        ),
        SegmentedButton<bool>(
          key: const ValueKey('todo-view'),
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: false, label: Text('List')),
            ButtonSegment(
              value: true,
              label: Text('History', key: ValueKey('todo-history')),
            ),
          ],
          selected: {_history},
          onSelectionChanged: (v) => setState(() => _history = v.first),
        ),
        PopupMenuButton<String>(
          key: const ValueKey('todo-page-menu'),
          tooltip: 'More',
          onSelected: (v) {
            if (v == 'select') {
              setState(() => _selecting = true);
            } else if (v == 'settings') {
              showTodoSettings(context);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'select', child: Text('Select items')),
            PopupMenuItem(value: 'settings', child: Text('To-do settings')),
          ],
        ),
      ],
    );

    final parsed = _input.text.trim().isEmpty
        ? null
        : parseTodoLine(_input.text, allowTeam: teamName != null);
    final today0 = todoToday();
    final tomorrow = DateTime(today0.year, today0.month, today0.day + 1);
    final showOptions =
        _inputFocus.hasFocus ||
        _input.text.isNotEmpty ||
        _optionsSet ||
        _optNotesOpen;
    Widget chip(
      String key,
      String text, {
      required bool selected,
      required VoidCallback onTap,
      IconData? icon,
    }) => ChoiceChip(
      key: ValueKey(key),
      label: Text(text),
      avatar: icon == null ? null : Icon(icon, size: 16),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (_) {
        onTap();
        _inputFocus.requestFocus();
      },
    );
    final dayIsToday = !_optLater && (_optDay == null || _optDay == today0);
    final options = Padding(
      key: const ValueKey('todo-options'),
      padding: const EdgeInsets.fromLTRB(2, 6, 0, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              chip(
                'todo-opt-today',
                'Today',
                selected: dayIsToday,
                onTap: () => setState(() {
                  _optDay = null;
                  _optLater = false;
                }),
              ),
              chip(
                'todo-opt-tomorrow',
                'Tomorrow',
                selected: !_optLater && _optDay == tomorrow,
                onTap: () => setState(() {
                  _optDay = tomorrow;
                  _optLater = false;
                }),
              ),
              chip(
                'todo-opt-pick',
                !_optLater &&
                        _optDay != null &&
                        _optDay != today0 &&
                        _optDay != tomorrow
                    ? todoDayLabel(_optDay!)
                    : 'Pick a day…',
                selected:
                    !_optLater &&
                    _optDay != null &&
                    _optDay != today0 &&
                    _optDay != tomorrow,
                onTap: _pickOptDay,
              ),
              chip(
                'todo-opt-later',
                'Later',
                selected: _optLater,
                onTap: () => setState(() {
                  _optLater = true;
                  _optDay = null;
                }),
              ),
              Container(width: 1, height: 20, color: c.border),
              InputChip(
                key: const ValueKey('todo-opt-due'),
                avatar: const Icon(Icons.schedule, size: 16),
                label: Text(
                  _optDue == null
                      ? 'Deadline'
                      : 'Due ${todoDayLabel(_optDue!)}'
                            '${_optDueTime ? ' ${DateFormat('HH:mm').format(_optDue!)}' : ''}',
                ),
                selected: _optDue != null,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onPressed: _pickOptDue,
                onDeleted: _optDue == null
                    ? null
                    : () => setState(() {
                        _optDue = null;
                        _optDueTime = false;
                      }),
              ),
              PopupMenuButton<TodoRepeat>(
                key: const ValueKey('todo-opt-repeat'),
                tooltip: 'Repeat',
                onSelected: (r) {
                  setState(() => _optRepeat = r);
                  _inputFocus.requestFocus();
                },
                itemBuilder: (_) => [
                  for (final r in TodoRepeat.values)
                    PopupMenuItem(
                      key: ValueKey('todo-opt-repeat-${r.name}'),
                      value: r,
                      child: Text(r == TodoRepeat.none ? 'Never' : r.label),
                    ),
                ],
                child: IgnorePointer(
                  child: ChoiceChip(
                    avatar: const Icon(Icons.repeat, size: 16),
                    label: Text(
                      _optRepeat == TodoRepeat.none
                          ? 'Repeat'
                          : _optRepeat.label,
                    ),
                    selected: _optRepeat != TodoRepeat.none,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onSelected: (_) {},
                  ),
                ),
              ),
              chip(
                'todo-opt-star',
                _optStar ? 'Starred' : 'Star',
                icon: _optStar ? Icons.star : Icons.star_border,
                selected: _optStar,
                onTap: () => setState(() => _optStar = !_optStar),
              ),
              chip(
                'todo-opt-notes',
                'Notes',
                icon: Icons.notes,
                selected: _optNotesOpen || _optNotes.text.trim().isNotEmpty,
                onTap: () => setState(() => _optNotesOpen = !_optNotesOpen),
              ),
              TextButton(
                key: const ValueKey('todo-opt-more'),
                onPressed: _addWithForm,
                child: const Text('More…'),
              ),
              if (_optionsSet)
                IconButton(
                  key: const ValueKey('todo-opt-clear'),
                  tooltip: 'Clear the choices',
                  visualDensity: VisualDensity.compact,
                  onPressed: _resetOptions,
                  icon: Icon(Icons.close, size: 16, color: c.textMuted),
                ),
            ],
          ),
          if (_optNotesOpen || _optNotes.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                key: const ValueKey('todo-opt-notes-field'),
                controller: _optNotes,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Notes for this to-do',
                ),
              ),
            ),
        ],
      ),
    );
    final input = Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (teamName != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: SegmentedButton<bool>(
                    key: const ValueKey('todo-target'),
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity(
                        horizontal: -3,
                        vertical: -3,
                      ),
                    ),
                    segments: const [
                      ButtonSegment(value: false, label: Text('Mine')),
                      ButtonSegment(
                        value: true,
                        label: Text('Team', key: ValueKey('todo-to-team')),
                      ),
                    ],
                    selected: {_toTeam},
                    onSelectionChanged: (v) =>
                        setState(() => _toTeam = v.first),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.add, size: 18, color: c.textMuted),
                ),
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
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: _toTeam
                        ? 'Add to the team list'
                        : 'Add a to-do, e.g. Call the embassy tomorrow 3pm !',
                    hintMaxLines: 1,
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
          if (parsed != null && parsed.understood)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                [
                  if (parsed.team) 'Team list',
                  if (parsed.later) 'Later',
                  if (parsed.day != null) todoDayLabel(parsed.day!),
                  if (parsed.due != null)
                    'due ${parsed.dueTime ? DateFormat('EEE HH:mm').format(parsed.due!) : todoDayLabel(parsed.due!)}',
                  if (parsed.repeat != TodoRepeat.none) parsed.repeat.label,
                  if (parsed.starred) '★ starred',
                ].join(' · '),
                key: const ValueKey('todo-understood'),
                style: muted?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
          if (showOptions) ...[
            Divider(height: 1, color: c.border),
            // Taps here keep the box focused, so the choices stay open.
            TextFieldTapRegion(child: options),
          ],
        ],
      ),
    );

    final progress = planned == 0
        ? null
        : Row(
            children: [
              Text(
                '${doneToday.length} of $planned done today',
                key: const ValueKey('todo-summary'),
                style: muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Dt.rPill),
                  child: LinearProgressIndicator(
                    value: doneToday.length / planned,
                    minHeight: 6,
                    backgroundColor: c.track,
                    color: Dt.statusGreen(theme.brightness),
                  ),
                ),
              ),
            ],
          );

    final selectBar = Container(
      key: const ValueKey('todo-select-bar'),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Dt.rMd),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(
            _selected.isEmpty
                ? 'Tap items to select them'
                : '${_selected.length} selected',
            style: theme.textTheme.labelLarge,
          ),
          TextButton(
            key: const ValueKey('todo-bulk-done'),
            onPressed: _selected.isEmpty
                ? null
                : () {
                    _list.setDone(_selected, true);
                    _endSelect();
                  },
            child: const Text('Done'),
          ),
          TextButton(
            key: const ValueKey('todo-bulk-today'),
            onPressed: _selected.isEmpty
                ? null
                : () {
                    _list.moveToToday(_selected);
                    _endSelect();
                  },
            child: const Text('Today'),
          ),
          TextButton(
            key: const ValueKey('todo-bulk-later'),
            onPressed: _selected.isEmpty
                ? null
                : () {
                    _list.moveToLater(_selected);
                    _endSelect();
                  },
            child: const Text('Later'),
          ),
          if (canSend)
            TextButton(
              key: const ValueKey('todo-bulk-send'),
              onPressed: _selected.isEmpty
                  ? null
                  : () {
                      final items = [
                        for (final t in all)
                          if (_selected.contains(t.key) && !t.team && !t.sent)
                            t,
                      ];
                      _endSelect();
                      if (items.isNotEmpty) _send(items);
                    },
              child: const Text('Send'),
            ),
          TextButton(
            key: const ValueKey('todo-bulk-delete'),
            onPressed: _selected.isEmpty
                ? null
                : () {
                    _delete({..._selected});
                    _endSelect();
                  },
            child: Text(
              'Delete',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          IconButton(
            key: const ValueKey('todo-select-end'),
            tooltip: 'Stop selecting (Esc)',
            visualDensity: VisualDensity.compact,
            onPressed: _endSelect,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );

    final listView = <Widget>[
      if (progress != null || (canSend && unsent.isNotEmpty))
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: LayoutBuilder(
            builder: (context, box) {
              final send = canSend && unsent.isNotEmpty
                  ? OutlinedButton.icon(
                      key: const ValueKey('todo-send'),
                      onPressed: () => _send(unsent),
                      icon: const Icon(Icons.outbox_outlined, size: 16),
                      label: const Text('Send to Daily reports'),
                    )
                  : null;
              // Narrow: the bar gets the whole width, the button goes below.
              if (box.maxWidth < 560 && progress != null && send != null) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    progress,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: send),
                  ],
                );
              }
              return Row(
                children: [
                  if (progress != null)
                    Expanded(child: progress)
                  else
                    const Spacer(),
                  if (send != null) ...[const SizedBox(width: 12), send],
                ],
              );
            },
          ),
        ),
      if (_selecting)
        Padding(padding: const EdgeInsets.only(top: 10), child: selectBar),
      if (earlier.isNotEmpty) ...[
        heading(
          '${earlier.every((t) => t.planned == yesterday) ? 'Yesterday’s unfinished' : 'Unfinished from earlier'} (${earlier.length})',
          key: const ValueKey('todo-earlier'),
          icon: Icons.history_toggle_off,
          color: c.warningFg,
          trailing: [
            TextButton(
              key: const ValueKey('todo-carry-today'),
              onPressed: () =>
                  _list.moveToToday([for (final t in earlier) t.key]),
              child: const Text('Bring to today'),
            ),
            TextButton(
              key: const ValueKey('todo-carry-later'),
              onPressed: () =>
                  _list.moveToLater([for (final t in earlier) t.key]),
              child: const Text('Later'),
            ),
          ],
        ),
        card([for (final t in earlier) row(t, showDay: true)]),
      ],
      if (overdue.isNotEmpty) ...[
        heading(
          'Overdue (${overdue.length})',
          key: const ValueKey('todo-overdue'),
          icon: Icons.error_outline,
          color: theme.colorScheme.error,
        ),
        card([for (final t in overdue) row(t)]),
      ],
      if (todayItems.isNotEmpty) ...[
        heading(
          'Today (${todayItems.length})',
          key: const ValueKey('todo-today'),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(Dt.rMd),
          ),
          child: todayList,
        ),
      ],
      if (teamName != null && team.isNotEmpty) ...[
        heading(
          'Team list · $teamName (${team.where((t) => !t.done).length})',
          key: const ValueKey('todo-team'),
          icon: Icons.groups_2_outlined,
        ),
        card([for (final t in team) row(t)]),
      ],
      if (later.isNotEmpty) ...[
        heading(
          'Later (${later.length})',
          key: const ValueKey('todo-later'),
          trailing: [
            TextButton.icon(
              key: const ValueKey('todo-later-toggle'),
              onPressed: () => setState(() => _showLater = !_showLater),
              icon: Icon(
                _showLater ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(_showLater ? 'Hide' : 'Show'),
            ),
          ],
        ),
        if (_showLater) card([for (final t in later) row(t, showDay: true)]),
      ],
      if (done.isNotEmpty) ...[
        heading(
          'Done (${done.length})',
          key: const ValueKey('todo-done'),
          trailing: [
            TextButton(
              key: const ValueKey('todo-clear-done'),
              onPressed: () => _clearDone(done),
              child: const Text('Clear done'),
            ),
          ],
        ),
        card([for (final t in done) row(t)]),
      ],
      if (live.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 24),
          child: PanelEmpty(
            icon: Icons.checklist_outlined,
            title: 'Nothing on your list',
            message:
                'Write down what you plan to do today. Tick things off as '
                'you go.',
          ),
        ),
    ];

    return Focus(
      focusNode: _pageFocus,
      onKeyEvent: (_, e) => _key(e, visible),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (!_inputFocus.hasFocus) _pageFocus.requestFocus();
        },
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(pad, 14, pad, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  syncLine,
                  const SizedBox(height: 10),
                  if (_history)
                    _History(
                      items: all,
                      onOpen: (t) => showTodoEditor(context, ref, t),
                    )
                  else ...[
                    input,
                    ...listView,
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

/// What got done, day by day (the last two weeks).
class _History extends StatelessWidget {
  const _History({required this.items, required this.onOpen});
  final List<TodoItem> items;
  final ValueChanged<TodoItem> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final today = todoToday();
    final from = today.subtract(const Duration(days: 13));
    final monday = today.subtract(Duration(days: today.weekday - 1));
    final done = [
      for (final t in items)
        if (t.done &&
            t.doneAt != null &&
            !dateOnly(t.doneAt!).isBefore(from) &&
            (!t.team || t.doneBy != null))
          t,
    ]..sort((a, b) => b.doneAt!.compareTo(a.doneAt!));
    final byDay = <DateTime, List<TodoItem>>{};
    for (final t in done) {
      byDay.putIfAbsent(dateOnly(t.doneAt!), () => []).add(t);
    }
    final week = done.where((t) => !dateOnly(t.doneAt!).isBefore(monday));
    if (done.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 24),
        child: PanelEmpty(
          icon: Icons.history,
          title: 'Nothing done in the last two weeks',
          message: 'Ticked items show here, day by day.',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${week.length} done this week · ${done.length} in the last two '
          'weeks',
          key: const ValueKey('todo-history-summary'),
          style: muted,
        ),
        for (final e in byDay.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 6, left: 2),
            child: Text(
              '${todoDayLabel(e.key)} (${e.value.length})',
              key: ValueKey(
                'todo-history-${e.key.toIso8601String().substring(0, 10)}',
              ),
              style: theme.textTheme.titleSmall?.copyWith(
                color: c.textSecondary,
              ),
            ),
          ),
          Material(
            color: c.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: c.border),
              borderRadius: BorderRadius.circular(Dt.rMd),
            ),
            child: Column(
              children: [
                for (final (i, t) in e.value.indexed) ...[
                  if (i > 0) Divider(height: 1, color: c.border),
                  ListTile(
                    dense: true,
                    onTap: () => onOpen(t),
                    leading: Icon(
                      Icons.check_circle,
                      size: 18,
                      color: Dt.statusGreen(theme.brightness),
                    ),
                    title: Text(t.title),
                    subtitle: Text(
                      [
                        DateFormat('HH:mm').format(t.doneAt!),
                        if (t.team) 'Team list · ${t.doneBy}',
                        if (t.sent) 'Sent to Daily reports',
                      ].join(' · '),
                      style: muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
