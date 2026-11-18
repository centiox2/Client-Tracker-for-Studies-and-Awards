import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../design/app_theme.dart';
import '../../services/daily_reports_service.dart';
import '../../state/app_state.dart';
import 'quick_entry.dart';
import 'report_editor.dart';

/// One line on the list being put together.
class _Item {
  _Item({
    required this.id,
    required String title,
    required this.mode,
    required this.urgency,
    this.due,
    Map<String, int>? outputs,
  }) : title = TextEditingController(text: title),
       outputs = {...?outputs};

  final int id;
  final TextEditingController title;
  TaskMode mode;
  TaskUrgency urgency;
  DateTime? due;
  final Map<String, int> outputs;
  String? error;

  bool get done => mode == TaskMode.done;

  ActivityReport toReport() => ActivityReport(
    description: title.text.trim(),
    status: statusOf(mode),
    urgency: urgency,
    dueDate: done ? null : due,
    outputs: done
        ? {
            for (final e in outputs.entries)
              if (e.value > 0) e.key: e.value,
          }
        : const {},
  );

  Map<String, Object?> toJson() => {
    'title': title.text,
    'mode': mode.name,
    'urgency': urgency.code,
    if (due != null) 'due': dateKey(due!),
    if (outputs.isNotEmpty) 'outputs': outputs,
  };
}

/// Where the day's work is written down: type an item and press Enter, as
/// many as you like (or paste a list). Each one is Done or To do (two buttons),
/// with its urgency and due day. Nothing is
/// sent until Submit, which saves them all together; done items go for
/// review, the rest go on your list. Kept on this device until then.
class TaskComposer extends ConsumerStatefulWidget {
  const TaskComposer({
    super.key,
    required this.meta,
    required this.inputFocus,
    this.onDown,
    this.onEscape,
  });

  final ReportsMeta meta;

  /// The line items are typed into (the N key and the reminder come here).
  final FocusNode inputFocus;

  /// Down from the line: to the first task card.
  final VoidCallback? onDown;
  final VoidCallback? onEscape;

  @override
  ConsumerState<TaskComposer> createState() => _TaskComposerState();
}

class _TaskComposerState extends ConsumerState<TaskComposer> {
  final _input = TextEditingController();
  final List<_Item> _items = [];
  int _next = 1;
  TaskMode? _mode;
  bool _busy = false;
  int? _me;
  Timer? _saveTimer;

  ReportsMeta get meta => widget.meta;
  DateTime get _today => meta.today;
  Department? get _dept => meta.myDepartment;

  /// Status new items get: the one chosen here, else the one used last.
  TaskMode get _defaultMode =>
      _mode ?? TaskMode.named(ref.read(reportChoicesProvider).mode);

  static String _key(int user) => 'daily_reports_draft_$user';

  @override
  void initState() {
    super.initState();
    _me = ref.read(currentUserProvider)?.id;
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _persist();
    _input.dispose();
    for (final i in _items) {
      i.title.dispose();
    }
    super.dispose();
  }

  // -------------------------------------------------------- Keeping it ---

  Future<void> _load() async {
    final me = _me;
    if (me == null) return;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key(me));
      if (raw == null || !mounted) return;
      final list = (jsonDecode(raw) as List).cast<Map>();
      setState(() {
        for (final j in list) {
          _items.add(_fromJson(j.cast<String, Object?>()));
        }
      });
    } catch (_) {}
  }

  _Item _fromJson(Map<String, Object?> j) => _Item(
    id: _next++,
    title: j['title'] as String? ?? '',
    mode: TaskMode.named(j['mode'] as String?),
    urgency: TaskUrgency.fromCode(j['urgency'] as String?),
    due: DateTime.tryParse(j['due'] as String? ?? ''),
    outputs: {
      for (final e in ((j['outputs'] as Map?) ?? const {}).entries)
        '${e.key}': (e.value as num).toInt(),
    },
  );

  void _changed() {
    setState(() {});
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _persist);
  }

  void _persist() {
    final me = _me;
    if (me == null) return;
    final data = [for (final i in _items) i.toJson()];
    unawaited(
      SharedPreferences.getInstance().then(
        (p) => data.isEmpty
            ? p.remove(_key(me))
            : p.setString(_key(me), jsonEncode(data)),
      ),
    );
  }

  // ----------------------------------------------------------- Adding ---

  _Item _fromLine(String line) {
    final e = parseQuickEntry(
      line.replaceFirst(RegExp(r'^\s*([-*•]|\d+[.)])\s+'), ''),
      today: _today,
      department: _dept,
    );
    return _Item(
      id: _next++,
      title: e.title,
      mode: e.done ? TaskMode.done : _defaultMode,
      urgency: e.urgency ?? ref.read(reportChoicesProvider).urgency,
      due: e.due,
      outputs: e.outputs,
    );
  }

  void _addLines(List<String> lines) {
    final add = [
      for (final l in lines)
        if (l.trim().isNotEmpty) _fromLine(l.trim()),
    ];
    if (add.isEmpty) return;
    _items.addAll(add);
    _input.clear();
    _changed();
  }

  void _addInput() {
    if (_busy) return;
    _addLines([_input.text]);
    widget.inputFocus.requestFocus();
  }

  void _remove(_Item i) {
    final at = _items.indexOf(i);
    _items.remove(i);
    _changed();
    final json = i.toJson();
    i.title.dispose();
    reportSnack(
      ScaffoldMessenger.of(context),
      'Removed “${json['title']}” from the list',
      onUndo: () {
        if (!mounted) return;
        _items.insert(at.clamp(0, _items.length), _fromJson(json));
        _changed();
      },
    );
  }

  void _clear() {
    if (_items.isEmpty) return;
    final json = [for (final i in _items) i.toJson()];
    for (final i in _items) {
      i.title.dispose();
    }
    _items.clear();
    _changed();
    reportSnack(
      ScaffoldMessenger.of(context),
      'Cleared ${json.length} item${json.length == 1 ? '' : 's'}',
      onUndo: () {
        if (!mounted) return;
        _items.addAll([for (final j in json) _fromJson(j)]);
        _changed();
      },
    );
  }

  // ----------------------------------------------------------- Saving ---

  Future<void> _saveAll() async {
    if (_busy) return;
    if (_input.text.trim().isNotEmpty) _addLines([_input.text]);
    if (_items.isEmpty) return;
    var missing = false;
    for (final i in _items) {
      i.error = i.title.text.trim().isEmpty ? 'Give it a title.' : null;
      missing |= i.error != null;
    }
    if (missing) {
      setState(() {});
      return;
    }
    setState(() => _busy = true);
    final actions = TaskActions(context, ref);
    final saved = <SaveOutcome>[];
    for (final i in [..._items]) {
      try {
        saved.add(await actions.save(i.toReport(), submit: i.done));
        _items.remove(i);
        i.title.dispose();
      } catch (e) {
        i.error = describeReportError(e);
      }
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _changed();
    if (saved.isEmpty) return;
    final modes = {for (final i in saved) i.task.status == ReportStatus.done};
    unawaited(
      ref
          .read(reportChoicesProvider.notifier)
          .remember(mode: _defaultMode.name),
    );
    if (saved.length == 1) {
      final o = saved.single;
      modes.contains(true)
          ? actions.submitted(o, created: true)
          : actions.added(o);
      return;
    }
    final sent = saved.where((o) => o.task.status == ReportStatus.done).length;
    final listed = saved.length - sent;
    final queued = saved.where((o) => o.queued).length;
    actions.snack(
      [
            if (sent > 0) 'Submitted $sent',
            if (listed > 0)
              '${sent > 0 ? 'added' : 'Added'} $listed to your list',
          ].join(', ') +
          (queued == 0 ? '' : ' ($queued waiting to send)'),
      onUndo: () => actions.undoAll(saved, created: true),
    );
  }

  // ------------------------------------------------------------- Keys ---

  KeyEventResult _inputKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed || hw.isMetaPressed;
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        !hw.isShiftPressed) {
      ctrl ? _saveAll() : _addInput();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && widget.onDown != null) {
      widget.onDown!();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && widget.onEscape != null) {
      widget.onEscape!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------ Menus ---

  Widget _urgencyMenu(ThemeData theme, _Item i) => PopupMenuButton<TaskUrgency>(
    key: ValueKey('draft-urgency-${i.id}'),
    tooltip: 'Urgency',
    initialValue: i.urgency,
    enabled: !_busy,
    onSelected: (u) {
      i.urgency = u;
      _changed();
    },
    itemBuilder: (_) => [
      for (final u in TaskUrgency.values)
        PopupMenuItem(
          value: u,
          child: Row(
            children: [
              Icon(Icons.circle, size: 12, color: u.color(theme.brightness)),
              const SizedBox(width: 10),
              Text(u.label),
            ],
          ),
        ),
    ],
    child: UrgencyPill(i.urgency),
  );

  List<(String, DateTime)> get _quickDues {
    final t = _today;
    DateTime day(int add) => DateTime(t.year, t.month, t.day + add);
    final toFriday = (DateTime.friday - t.weekday) % 7;
    final toMonday = (DateTime.monday - t.weekday + 7) % 7;
    return [
      ('Today', t),
      ('Tomorrow', day(1)),
      if (toFriday > 1) ('Friday', day(toFriday)),
      ('Next Monday', day(toMonday == 0 ? 7 : toMonday)),
    ];
  }

  Widget _dueMenu(ThemeData theme, _Item i) {
    final c = Clarity.of(theme);
    final dues = _quickDues;
    return PopupMenuButton<int>(
      key: ValueKey('draft-due-${i.id}'),
      tooltip: 'Due date',
      enabled: !_busy,
      onSelected: (n) async {
        if (n == -1) {
          i.due = null;
        } else if (n == dues.length) {
          final first = DateTime(_today.year - 1);
          final picked = await showDatePicker(
            context: context,
            initialDate: i.due ?? _today.add(const Duration(days: 1)),
            firstDate: first,
            lastDate: DateTime(_today.year + 2),
            helpText: 'Due date',
          );
          if (picked == null) return;
          i.due = picked;
        } else {
          i.due = dues[n].$2;
        }
        _changed();
      },
      itemBuilder: (_) => [
        for (final (n, d) in dues.indexed)
          PopupMenuItem(
            value: n,
            child: Text('${d.$1} · ${taskDay(d.$2, today: _today)}'),
          ),
        PopupMenuItem(value: dues.length, child: const Text('Pick a date…')),
        if (i.due != null)
          const PopupMenuItem(value: -1, child: Text('No due date')),
      ],
      child: TaskPill(
        i.due == null ? 'Due date' : 'Due ${taskDay(i.due!, today: _today)}',
        i.due == null ? c.textMuted : c.textSecondary,
        icon: Icons.event,
        trailingIcon: Icons.arrow_drop_down,
      ),
    );
  }

  // ------------------------------------------------------------ Items ---

  Widget _item(ThemeData theme, _Item i, bool narrow) {
    final c = Clarity.of(theme);
    final outputs = i.done ? (_dept?.outputs ?? const <OutputField>[]) : [];
    final status = TaskModeToggle(
      keyPrefix: 'draft-mode-${i.id}',
      dense: true,
      value: i.mode,
      onChanged: _busy
          ? null
          : (m) {
              i.mode = m;
              _changed();
            },
    );
    final title = TextField(
      key: ValueKey('draft-title-${i.id}'),
      controller: i.title,
      enabled: !_busy,
      maxLength: 300,
      textCapitalization: TextCapitalization.sentences,
      onChanged: (_) {
        if (i.error != null) i.error = null;
        _changed();
      },
      onSubmitted: (_) => widget.inputFocus.requestFocus(),
      style: theme.textTheme.bodyMedium,
      decoration: const InputDecoration(
        isDense: true,
        filled: false,
        counterText: '',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(vertical: 8),
      ),
    );
    final remove = IconButton(
      key: ValueKey('draft-remove-${i.id}'),
      tooltip: 'Remove from the list',
      visualDensity: VisualDensity.compact,
      onPressed: _busy ? null : () => _remove(i),
      icon: Icon(Icons.close, size: 16, color: c.textMuted),
    );
    final extras = <Widget>[
      _urgencyMenu(theme, i),
      if (!i.done) _dueMenu(theme, i),
    ];
    final counts = [
      for (final o in outputs)
        SizedBox(
          width: 150,
          child: TextFormField(
            key: ValueKey('draft-count-${i.id}-${o.key}'),
            initialValue: (i.outputs[o.key] ?? 0) > 0
                ? '${i.outputs[o.key]}'
                : null,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(5),
            ],
            decoration: InputDecoration(
              isDense: true,
              labelText: o.label,
              hintText: '0',
            ),
            onChanged: (v) {
              i.outputs[o.key] = int.tryParse(v) ?? 0;
              _changed();
            },
          ),
        ),
    ];
    const gap = SizedBox(width: 8);
    return Padding(
      key: ValueKey('draft-${i.id}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!narrow) ...[status, gap],
              Expanded(child: title),
              if (!narrow) ...[
                for (final w in extras) ...[gap, w],
              ],
              remove,
            ],
          ),
          if (narrow || counts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (narrow) ...[status, ...extras],
                  ...counts,
                ],
              ),
            ),
          if (i.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                i.error!,
                key: ValueKey('draft-error-${i.id}'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    // Rebuild when the remembered choice arrives from disk.
    ref.watch(reportChoicesProvider);
    final mode = _defaultMode;
    final sent = _items.where((i) => i.done).length;
    final listed = _items.length - sent;
    final saveLabel = sent > 0 && listed > 0
        ? 'Submit $sent, add $listed'
        : sent > 0
        ? 'Submit $sent'
        : 'Add $listed to my list';

    final modeControl = Tooltip(
      message: 'Status for new items',
      child: TaskModeToggle(
        keyPrefix: 'draft-default-mode',
        dense: true,
        value: mode,
        onChanged: (m) {
          setState(() => _mode = m);
          ref.read(reportChoicesProvider.notifier).remember(mode: m.name);
        },
      ),
    );
    Widget input(bool narrow) => Row(
      children: [
        if (!narrow) ...[modeControl, const SizedBox(width: 8)],
        Expanded(
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (_, e) => _inputKey(e),
            child: TextField(
              key: const ValueKey('quick-task'),
              controller: _input,
              focusNode: widget.inputFocus,
              readOnly: _busy,
              // A pasted list: an item per line.
              minLines: 1,
              maxLines: null,
              keyboardType: TextInputType.text,
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
                disabledBorder: InputBorder.none,
                hintText: _items.isEmpty
                    ? 'Type a task and press Enter'
                    : 'Add another…',
                hintMaxLines: 1,
              ),
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('quick-add'),
          tooltip: 'Add to the list (Enter)',
          visualDensity: VisualDensity.compact,
          onPressed: _busy ? null : _addInput,
          icon: const Icon(Icons.keyboard_return, size: 18),
        ),
      ],
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            _saveAll,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _saveAll,
      },
      child: Container(
        key: const ValueKey('task-composer'),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(Dt.rMd),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final narrow = box.maxWidth < 560;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4, right: 4),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text('TODAY’S LIST', style: microLabel(theme)),
                      ),
                      const SizedBox(width: 12),
                      if (narrow) ...[
                        const Spacer(),
                        modeControl,
                      ] else if (_items.isNotEmpty)
                        Expanded(
                          child: Text(
                            '${_items.length} item${_items.length == 1 ? '' : 's'}'
                            ' · not sent yet',
                            key: const ValueKey('draft-summary'),
                            textAlign: TextAlign.end,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: muted,
                          ),
                        ),
                    ],
                  ),
                ),
                for (final i in _items) ...[
                  _item(theme, i, narrow),
                  Divider(height: 1, color: c.border),
                ],
                input(narrow),
                if (_items.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        const Spacer(),
                        TextButton(
                          key: const ValueKey('draft-clear'),
                          onPressed: _busy ? null : _clear,
                          child: const Text('Clear'),
                        ),
                        Flexible(
                          flex: 2,
                          child: FilledButton.icon(
                            key: const ValueKey('draft-save'),
                            onPressed: _busy ? null : _saveAll,
                            icon: _busy
                                ? const SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    sent > 0 ? Icons.send : Icons.playlist_add,
                                    size: 16,
                                  ),
                            label: Text(
                              saveLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Enter (a newline typed) adds; a pasted list of lines adds one item per
/// line. The line never keeps a newline itself.
class LinesFormatter extends TextInputFormatter {
  LinesFormatter({required this.onEnter, required this.onLines});

  final VoidCallback onEnter;
  final ValueChanged<List<String>> onLines;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text.replaceAll('\r', '');
    if (!text.contains('\n')) return newValue;
    final lines = [
      for (final l in text.split('\n'))
        if (l.trim().isNotEmpty) l.trim(),
    ];
    final typedNewline =
        text.length == oldValue.text.length + 1 &&
        text.replaceFirst('\n', '') == oldValue.text;
    if (typedNewline) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onEnter());
      return oldValue;
    }
    if (lines.length <= 1) {
      final one = lines.isEmpty ? '' : lines.single;
      return TextEditingValue(
        text: one,
        selection: TextSelection.collapsed(offset: one.length),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => onLines(lines));
    return TextEditingValue.empty;
  }
}
