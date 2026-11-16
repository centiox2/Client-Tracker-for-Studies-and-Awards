import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../models/daily_report.dart' show OutputField;
import '../../services/daily_reports_service.dart';
import '../../services/todo_service.dart';
import '../daily_reports/report_editor.dart' show reportSnack, taskDay;
import 'todo_send.dart';

/// "Today", "Tomorrow", "Wed 18 Nov".
String todoDayLabel(DateTime d) {
  final today = todoToday();
  final day = dateOnly(d);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  return taskDay(day, today: today);
}

/// Opens an item to change anything about it.
Future<void> showTodoEditor(
  BuildContext context,
  WidgetRef ref,
  TodoItem item,
) => showDialog<void>(
  context: context,
  builder: (_) => _TodoEditor(item: item),
);

class _TodoEditor extends ConsumerStatefulWidget {
  const _TodoEditor({required this.item});
  final TodoItem item;

  @override
  ConsumerState<_TodoEditor> createState() => _TodoEditorState();
}

enum _DayChoice { today, tomorrow, pick, later }

class _TodoEditorState extends ConsumerState<_TodoEditor> {
  late final _title = TextEditingController(text: widget.item.title);
  late final _notes = TextEditingController(text: widget.item.notes);
  final _step = TextEditingController();
  late DateTime? _day = widget.item.later
      ? null
      : (widget.item.day ?? todoToday());
  late bool _later = widget.item.later;
  late DateTime? _due = widget.item.due;
  late bool _dueTime = widget.item.dueTime;
  late bool _starred = widget.item.starred;
  late TodoRepeat _repeat = widget.item.repeat;
  late List<TodoStep> _steps = [...widget.item.steps];
  late final Map<String, int> _outputs = {...widget.item.outputs};
  late String? _clientKey = widget.item.clientKey;
  late final _countControllers = <String, TextEditingController>{};
  String? _error;

  TodoItem get t => widget.item;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _step.dispose();
    for (final c in _countControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  _DayChoice get _dayChoice {
    if (_later || _day == null) return _DayChoice.later;
    final diff = dateOnly(_day!).difference(todoToday()).inDays;
    return diff <= 0
        ? _DayChoice.today
        : diff == 1
        ? _DayChoice.tomorrow
        : _DayChoice.pick;
  }

  Future<void> _pickDay() async {
    final today = todoToday();
    final d = await showDatePicker(
      context: context,
      initialDate: _day != null && !_day!.isBefore(today) ? _day! : today,
      firstDate: today,
      lastDate: DateTime(today.year + 2),
    );
    if (d != null) {
      setState(() {
        _day = d;
        _later = false;
      });
    }
  }

  Future<void> _pickDue() async {
    final today = todoToday();
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? _day ?? today,
      firstDate: DateTime(today.year - 1),
      lastDate: DateTime(today.year + 2),
    );
    if (d == null) return;
    setState(() {
      _due = _dueTime && _due != null
          ? DateTime(d.year, d.month, d.day, _due!.hour, _due!.minute)
          : d;
    });
  }

  Future<void> _pickTime() async {
    final base = _due ?? _day ?? todoToday();
    final time = await showTimePicker(
      context: context,
      initialTime: _dueTime && _due != null
          ? TimeOfDay.fromDateTime(_due!)
          : const TimeOfDay(hour: 17, minute: 0),
    );
    if (time == null) return;
    setState(() {
      _due = DateTime(base.year, base.month, base.day, time.hour, time.minute);
      _dueTime = true;
    });
  }

  void _addStep() {
    final text = _step.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _steps = [..._steps, TodoStep(text)];
      _step.clear();
    });
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Write what it is.');
      return;
    }
    for (final e in _countControllers.entries) {
      final n = int.tryParse(e.value.text.trim());
      if (n == null || n <= 0) {
        _outputs.remove(e.key);
      } else {
        _outputs[e.key] = n;
      }
    }
    final keepClient = _clientKey != null;
    ref.read(todoListProvider.notifier).edit([t.key], (x) {
      final today = todoToday();
      return x.copyWith(
        title: title.length > 300 ? title.substring(0, 300) : title,
        notes: _notes.text.trim(),
        day: _later || _day == null || !dateOnly(_day!).isAfter(today)
            ? null
            : dateOnly(_day!),
        later: _later,
        due: _due,
        dueTime: _due != null && _dueTime,
        starred: _starred,
        repeat: _repeat,
        steps: _steps,
        outputs: Map.of(_outputs),
        clientKey: keepClient ? x.clientKey : null,
        clientName: keepClient ? x.clientName : null,
        isNew: false,
      );
    });
    Navigator.pop(context);
  }

  void _delete() {
    final messenger = ScaffoldMessenger.of(context);
    final list = ref.read(todoListProvider.notifier);
    final gone = list.remove([t.key]);
    Navigator.pop(context);
    reportSnack(
      messenger,
      'Deleted “${t.title}”',
      onUndo: () => list.restore(gone),
    );
  }

  Future<void> _give() => giveTodo(
    context,
    ref,
    t.copyWith(
      title: _title.text.trim().isEmpty ? t.title : _title.text.trim(),
      notes: _notes.text.trim(),
      steps: _steps,
      starred: _starred,
      due: _due,
      dueTime: _dueTime,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final label = theme.textTheme.labelMedium?.copyWith(
      color: c.textSecondary,
      fontWeight: FontWeight.w600,
    );
    final online = ref.read(todoListProvider.notifier).sync != TodoSync.device;
    final department = ref.watch(reportStartProvider)?.meta.myDepartment;
    final outputs = !t.team && canSendTodos(ref)
        ? department?.outputs ?? const []
        : const <OutputField>[];
    for (final o in outputs) {
      _countControllers.putIfAbsent(
        o.key,
        () => TextEditingController(text: _outputs[o.key]?.toString() ?? ''),
      );
    }

    Widget section(String text, Widget child) => Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: label),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );

    ChoiceChip choice(
      String key,
      String text,
      bool selected,
      VoidCallback onTap,
    ) => ChoiceChip(
      key: ValueKey(key),
      label: Text(text),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
    );

    final dayChoice = _dayChoice;
    final dayRow = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        choice(
          'todo-day-today',
          'Today',
          dayChoice == _DayChoice.today,
          () => setState(() {
            _day = todoToday();
            _later = false;
          }),
        ),
        choice(
          'todo-day-tomorrow',
          'Tomorrow',
          dayChoice == _DayChoice.tomorrow,
          () => setState(() {
            final d = todoToday();
            _day = DateTime(d.year, d.month, d.day + 1);
            _later = false;
          }),
        ),
        choice(
          'todo-day-pick',
          dayChoice == _DayChoice.pick ? todoDayLabel(_day!) : 'Pick a day…',
          dayChoice == _DayChoice.pick,
          _pickDay,
        ),
        choice(
          'todo-day-later',
          'Later',
          dayChoice == _DayChoice.later,
          () => setState(() {
            _later = true;
            _day = null;
          }),
        ),
      ],
    );

    final dueRow = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('todo-due-date'),
          onPressed: _pickDue,
          icon: const Icon(Icons.event_outlined, size: 16),
          label: Text(_due == null ? 'No deadline' : todoDayLabel(_due!)),
        ),
        OutlinedButton.icon(
          key: const ValueKey('todo-due-time'),
          onPressed: _pickTime,
          icon: const Icon(Icons.schedule, size: 16),
          label: Text(
            _due != null && _dueTime
                ? DateFormat('HH:mm').format(_due!)
                : 'Add a time',
          ),
        ),
        if (_due != null)
          IconButton(
            key: const ValueKey('todo-due-clear'),
            tooltip: 'No deadline',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() {
              _due = null;
              _dueTime = false;
            }),
            icon: const Icon(Icons.close, size: 16),
          ),
      ],
    );

    final repeatRow = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final r in TodoRepeat.values)
          choice(
            'todo-repeat-${r.name}',
            r.label,
            _repeat == r,
            () => setState(() => _repeat = r),
          ),
      ],
    );

    final steps = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, s) in _steps.indexed)
          Row(
            children: [
              Checkbox(
                value: s.done,
                visualDensity: VisualDensity.compact,
                onChanged: (v) => setState(() {
                  _steps = [..._steps]..[i] = s.copyWith(done: v ?? false);
                }),
              ),
              Expanded(
                child: Text(
                  s.title,
                  style: TextStyle(
                    decoration: s.done ? TextDecoration.lineThrough : null,
                    color: s.done ? c.textMuted : null,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Remove step',
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    setState(() => _steps = [..._steps]..removeAt(i)),
                icon: Icon(Icons.close, size: 16, color: c.textMuted),
              ),
            ],
          ),
        TextField(
          key: const ValueKey('todo-step-input'),
          controller: _step,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => _addStep(),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Add a step and press Enter',
            prefixIcon: const Icon(Icons.add, size: 18),
            suffixIcon: IconButton(
              tooltip: 'Add step',
              onPressed: _addStep,
              icon: const Icon(Icons.keyboard_return, size: 16),
            ),
          ),
        ),
      ],
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
      },
      child: AlertDialog(
        scrollable: true,
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
        title: Row(
          children: [
            Expanded(
              child: Text(
                t.team ? 'Team to-do' : 'To-do',
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              key: const ValueKey('todo-edit-star'),
              tooltip: _starred ? 'Unstar' : 'Star (keeps it at the top)',
              onPressed: () => setState(() => _starred = !_starred),
              icon: Icon(
                _starred ? Icons.star : Icons.star_border,
                color: _starred ? c.warningFg : c.textMuted,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (t.fromName != null || t.team && t.changedBy != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    [
                      if (t.fromName != null) 'From ${t.fromName}',
                      if (t.team && t.doneBy != null) 'Done by ${t.doneBy}',
                      if (t.team && t.changedBy != null)
                        'Last changed by ${t.changedBy}',
                    ].join(' · '),
                    style: muted,
                  ),
                ),
              TextField(
                key: const ValueKey('todo-edit-field'),
                controller: _title,
                autofocus: true,
                maxLength: 300,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'To-do',
                  counterText: '',
                  errorText: _error,
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('todo-edit-notes'),
                controller: _notes,
                minLines: 2,
                maxLines: 6,
                maxLength: 2000,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  counterText: '',
                  alignLabelWithHint: true,
                ),
              ),
              if (_clientKey != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: InputChip(
                      key: const ValueKey('todo-edit-client'),
                      avatar: const Icon(Icons.school_outlined, size: 16),
                      label: Text(t.clientName ?? _clientKey!),
                      onDeleted: () => setState(() => _clientKey = null),
                      deleteButtonTooltipMessage: 'Unlink the client',
                    ),
                  ),
                ),
              section('When', dayRow),
              section('Deadline', dueRow),
              section('Repeat', repeatRow),
              section('Steps', steps),
              if (outputs.isNotEmpty)
                section(
                  'Counts (sent with it to Daily reports)',
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      for (final o in outputs)
                        SizedBox(
                          width: 150,
                          child: TextField(
                            key: ValueKey('todo-count-${o.key}'),
                            controller: _countControllers[o.key],
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: InputDecoration(
                              isDense: true,
                              labelText: o.label,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          Wrap(
            children: [
              IconButton(
                key: const ValueKey('todo-edit-delete'),
                tooltip: 'Delete',
                onPressed: _delete,
                icon: Icon(
                  Icons.delete_outline,
                  color: theme.colorScheme.error,
                ),
              ),
              if (online && !t.team)
                IconButton(
                  key: const ValueKey('todo-edit-give'),
                  tooltip: 'Give to a colleague',
                  onPressed: _give,
                  icon: const Icon(Icons.person_add_alt),
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('todo-edit-save'),
                onPressed: _save,
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Gives a copy of [t] to a colleague the person picks.
Future<void> giveTodo(BuildContext context, WidgetRef ref, TodoItem t) async {
  final messenger = ScaffoldMessenger.of(context);
  final person = await showDialog<TodoPerson>(
    context: context,
    builder: (_) => const _PeoplePicker(),
  );
  if (person == null) return;
  try {
    await ref.read(todoListProvider.notifier).give(t, person);
    messenger.showSnackBar(
      SnackBar(content: Text('Sent to ${person.name}’s to-do list')),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(describeReportError(e))));
  }
}

/// Picks a colleague to give a to-do to.
class _PeoplePicker extends ConsumerStatefulWidget {
  const _PeoplePicker();

  @override
  ConsumerState<_PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends ConsumerState<_PeoplePicker> {
  List<TodoPerson>? _people;
  Object? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    ref
        .read(todoListProvider.notifier)
        .people()
        .then(
          (p) {
            if (mounted) setState(() => _people = p);
          },
          onError: (Object e) {
            if (mounted) setState(() => _error = e);
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Clarity.of(theme).textMuted,
    );
    final q = _query.toLowerCase();
    final people = [
      for (final p in _people ?? const <TodoPerson>[])
        if (q.isEmpty ||
            p.name.toLowerCase().contains(q) ||
            (p.department ?? '').toLowerCase().contains(q))
          p,
    ];
    return AlertDialog(
      title: const Text('Give to a colleague'),
      content: SizedBox(
        width: 420,
        height: 380,
        child: Column(
          children: [
            Text(
              'A copy goes on their to-do list, marked as from you.',
              style: muted,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('todo-people-search'),
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Name or department',
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _error != null
                  ? Center(child: Text(describeReportError(_error!)))
                  : _people == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        for (final p in people)
                          ListTile(
                            key: ValueKey('todo-person-${p.id}'),
                            dense: true,
                            leading: CircleAvatar(
                              radius: 14,
                              child: Text(
                                p.name.isEmpty ? '?' : p.name[0].toUpperCase(),
                              ),
                            ),
                            title: Text(p.name),
                            subtitle: p.department == null
                                ? null
                                : Text(p.department!),
                            onTap: () => Navigator.pop(context, p),
                          ),
                      ],
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
      ],
    );
  }
}

/// The person's to-do choices: the end-of-day reminder and when done
/// items leave the list.
Future<void> showTodoSettings(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _TodoSettings());

class _TodoSettings extends ConsumerWidget {
  const _TodoSettings();

  static String _time(int m) =>
      DateFormat('HH:mm').format(DateTime(2000, 1, 1, m ~/ 60, m % 60));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final p = ref.watch(todoPrefsProvider);
    final set = ref.read(todoPrefsProvider.notifier).set;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Clarity.of(theme).textMuted,
    );
    ChoiceChip chip(String key, String text, bool on, VoidCallback onTap) =>
        ChoiceChip(
          key: ValueKey(key),
          label: Text(text),
          selected: on,
          showCheckmark: false,
          onSelected: (_) => onTap(),
        );
    return AlertDialog(
      title: const Text('To-do settings'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('End-of-day reminder', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Offers to send what you finished to Daily reports.',
              style: muted,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                chip(
                  'todo-reminder-off',
                  'Off',
                  p.reminderMinutes == null,
                  () => set(
                    TodoPrefs(
                      reminderMinutes: null,
                      clearAfterDays: p.clearAfterDays,
                    ),
                  ),
                ),
                for (final m in const [960, 990, 1020, 1050, 1080])
                  chip(
                    'todo-reminder-$m',
                    _time(m),
                    p.reminderMinutes == m,
                    () => set(
                      TodoPrefs(
                        reminderMinutes: m,
                        clearAfterDays: p.clearAfterDays,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text('Clear done items', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text('They stay in History either way.', style: muted),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (key, text, days) in const [
                  ('todo-clear-1', 'The next day', 1),
                  ('todo-clear-7', 'After a week', 7),
                  ('todo-clear-never', 'Never', null),
                ])
                  chip(
                    key,
                    text,
                    p.clearAfterDays == days,
                    () => set(
                      TodoPrefs(
                        reminderMinutes: p.reminderMinutes,
                        clearAfterDays: days,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
