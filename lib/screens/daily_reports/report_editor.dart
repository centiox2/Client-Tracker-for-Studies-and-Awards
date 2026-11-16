import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/daily_reports_service.dart';
import '../../state/app_state.dart';

final _dayFormat = DateFormat('EEE d MMM');
final _dayYearFormat = DateFormat('EEE d MMM y');
final _timeFormat = DateFormat('HH:mm');

/// "Mon 16 Nov" (with the year when it isn't this year).
String taskDay(DateTime d, {DateTime? today}) {
  final now = today ?? DateTime.now();
  return d.year == now.year ? _dayFormat.format(d) : _dayYearFormat.format(d);
}

/// "Mon 16 Nov, 14:32".
String taskStamp(DateTime d) => '${taskDay(d)}, ${_timeFormat.format(d)}';

/// When it was submitted, in words: "Submitted Mon 16 Nov, 14:32".
String submittedLabel(ActivityReport r) {
  final at = r.submittedAt;
  if (at != null) return 'Submitted ${taskStamp(at)}';
  final day = r.date;
  return day == null ? '' : 'Submitted ${taskDay(day)}';
}

Color statusColor(ReportStatus s, ThemeData theme) => switch (s) {
  ReportStatus.done => Dt.statusGreen(theme.brightness),
  ReportStatus.inProgress => Dt.existingBlue(theme.brightness),
  ReportStatus.toDo => theme.colorScheme.onSurfaceVariant,
  ReportStatus.blocked => theme.colorScheme.error,
};

Color reviewColor(ReviewState r, ThemeData theme) => switch (r) {
  ReviewState.approved => Dt.statusGreen(theme.brightness),
  ReviewState.submitted => Clarity.of(theme).warningFg,
  ReviewState.returned => theme.colorScheme.error,
  ReviewState.none => theme.colorScheme.onSurfaceVariant,
};

/// Whether [meta]'s person may approve or return [task] (the server checks
/// again).
bool canReviewTask(ReportsMeta meta, ActivityReport task) =>
    task.userId != meta.myId &&
    (task.assignedBy == meta.myId ||
        meta.scope == ReportScope.all ||
        (meta.scope == ReportScope.department &&
            task.departmentId == meta.myDepartmentId));

/// A short message at the bottom of the screen, with Undo when [onUndo]
/// is set. It goes away by itself.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> reportSnack(
  ScaffoldMessengerState messenger,
  String text, {
  VoidCallback? onUndo,
}) {
  // A new message replaces the last (a queue would show Undo too late).
  messenger.clearSnackBars();
  return messenger.showSnackBar(
    SnackBar(
      content: Text(text),
      duration: Duration(seconds: onUndo == null ? 4 : 6),
      persist: false,
      action: onUndo == null
          ? null
          : SnackBarAction(
              key: const ValueKey('report-undo'),
              label: 'Undo',
              onPressed: onUndo,
            ),
    ),
  );
}

/// What was saved, in words.
String savedMessage(ActivityReport saved) => saved.pending
    ? 'Saved on this device. It’s sent when you’re back online.'
    : saved.isSubmitted
    ? '${saved.ref} submitted for review'
    : 'Added ${saved.ref} to your list';

/// The task actions that offer Undo afterwards instead of asking first.
/// Holds what it needs, so Undo still works after the page or dialog that
/// started it has closed.
class TaskActions {
  TaskActions(BuildContext context, WidgetRef ref)
    : messenger = ScaffoldMessenger.of(context),
      _service = ref.read(dailyReportsProvider),
      _outbox = ref.read(reportOutboxProvider.notifier),
      _hidden = ref.read(reportHiddenProvider.notifier);

  final ScaffoldMessengerState messenger;
  final DailyReportsService _service;
  final ReportOutboxNotifier _outbox;
  final ReportHiddenNotifier _hidden;

  void snack(String text, {VoidCallback? onUndo}) =>
      reportSnack(messenger, text, onUndo: onUndo);

  void error(Object e) => snack(describeReportError(e));

  Future<SaveOutcome> save(ActivityReport t, {bool submit = false}) =>
      _outbox.save(t, submit: submit);

  /// "#12 submitted · Undo". [created]: it was new, so Undo deletes it;
  /// otherwise Undo takes the submission back.
  void submitted(SaveOutcome o, {bool created = false}) =>
      snack(savedMessage(o.task), onUndo: () => undo(o, created: created));

  /// "Added #12 · Undo" for a new task.
  void added(SaveOutcome o) =>
      snack(savedMessage(o.task), onUndo: () => undo(o, created: true));

  /// Takes back a save: what's waiting on this device is dropped, a new
  /// task is deleted, a submission withdrawn.
  Future<void> undo(SaveOutcome o, {bool created = false}) async {
    final id = o.task.id;
    if (id == null) return;
    if (o.queued || o.task.pending) {
      _outbox.cancel(id);
      return;
    }
    try {
      if (created) {
        await _service.delete(id);
      } else {
        await _service.withdraw(id);
      }
    } catch (e) {
      error(e);
    }
  }

  /// Several at once (Wrap up my day, a pasted list).
  Future<void> undoAll(List<SaveOutcome> all, {bool created = false}) async {
    for (final o in all) {
      await undo(o, created: created);
    }
  }

  /// Hides [t] at once and deletes it when the Undo has gone.
  void delete(ActivityReport t) {
    final id = t.id;
    if (id == null) return;
    if (!t.isSaved) {
      _outbox.cancel(id);
      snack('Removed it.');
      return;
    }
    _hidden.hide(id);
    var undone = false;
    final shown = reportSnack(
      messenger,
      'Deleted task ${t.ref}',
      onUndo: () {
        undone = true;
        _hidden.show(id);
      },
    );
    shown.closed.then((_) async {
      if (undone) return;
      try {
        await _service.delete(id);
      } catch (e) {
        _hidden.show(id);
        error(e);
      }
    });
  }

  /// Sets [t]'s status ("#12 is now doing · Undo").
  Future<void> setStatus(ActivityReport t, ReportStatus s) async {
    try {
      final o = await _outbox.save(t.withStatus(s));
      snack(
        o.queued
            ? savedMessage(o.task)
            : '${t.ref} is now ${s.label.toLowerCase()}',
        onUndo: () async {
          if (o.queued && !t.isSaved) {
            await _outbox.save(o.task.withStatus(t.status));
          } else if (o.queued) {
            _outbox.cancel(t.id!);
          } else {
            try {
              await _outbox.save(o.task.withStatus(t.status));
            } catch (e) {
              error(e);
            }
          }
        },
      );
    } catch (e) {
      error(e);
    }
  }
}

/// Finishes [task] in one tap: submitted straight away, with Undo. The
/// submit window (what you did, counts) opens instead when the department
/// records counts, or with [details].
Future<void> finishTask(
  BuildContext context,
  WidgetRef ref, {
  required ReportsMeta meta,
  required ActivityReport task,
  bool details = false,
}) async {
  final actions = TaskActions(context, ref);
  final dept = meta.department(task.departmentId ?? meta.myDepartmentId);
  if (details || (dept?.outputs.isNotEmpty ?? false)) {
    final o = await showSubmitDialog(context, meta: meta, task: task);
    if (o != null) actions.submitted(o);
    return;
  }
  try {
    final o = await actions.save(
      task.withStatus(ReportStatus.done),
      submit: true,
    );
    actions.submitted(o);
  } catch (e) {
    actions.error(e);
  }
}

/// A small coloured label.
class TaskPill extends StatelessWidget {
  const TaskPill(
    this.text,
    this.color, {
    super.key,
    this.icon,
    this.filled,
    this.trailingIcon,
  });

  final String text;
  final Color color;
  final IconData? icon;

  /// After the text, e.g. a drop-down arrow on a pill that is a menu.
  final IconData? trailingIcon;

  /// A solid background (white text) for the loudest labels.
  final bool? filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final solid = filled ?? false;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: solid ? color : color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(Dt.rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: solid ? Colors.white : color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            maxLines: 1,
            style: theme.textTheme.labelSmall?.copyWith(
              color: solid ? Colors.white : color,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
          if (trailingIcon != null)
            Icon(trailingIcon, size: 14, color: solid ? Colors.white : color),
        ],
      ),
    );
  }
}

/// The urgency as a pill: grey, blue, orange or red.
class UrgencyPill extends StatelessWidget {
  const UrgencyPill(this.urgency, {super.key});
  final TaskUrgency urgency;

  @override
  Widget build(BuildContext context) {
    final color = urgency.color(Theme.of(context).brightness);
    return TaskPill(
      urgency.label,
      color,
      icon: urgency == TaskUrgency.urgent ? Icons.priority_high : Icons.circle,
      filled: urgency == TaskUrgency.urgent,
    );
  }
}

/// From this width a card's labels and buttons sit beside its title.
const double _wide = 520;

/// One task as a card: its number, urgency label,
/// title, who and when, where it is, and what can be done next.
class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.meta,
    this.onTap,
    this.showPerson = false,
    this.actions = const [],
    this.onStatus,
    this.onTick,
    this.focusNode,
  });

  final ActivityReport task;
  final ReportsMeta meta;
  final VoidCallback? onTap;

  /// Shows whose task it is (in team and review lists).
  final bool showPerson;

  /// Buttons along the bottom (Start, Submit, Approve…).
  final List<Widget> actions;

  /// Set: the status pill is a menu that changes the status in one tap.
  final ValueChanged<ReportStatus>? onStatus;

  /// Set: a tick box before the title finishes the task in one tap.
  final VoidCallback? onTick;

  /// For moving between cards with the arrow keys.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: c.textMuted,
      height: 1.35,
    );
    final t = task;
    final today = meta.today;
    final dept = meta.department(t.departmentId);
    final overdue = t.isOverdue(today);
    final dueToday = t.isDueToday(today);

    final info = <InlineSpan>[];
    void add(String text, {Color? color, bool bold = false}) {
      if (info.isNotEmpty) info.add(const TextSpan(text: '  ·  '));
      info.add(
        TextSpan(
          text: text,
          style: color == null && !bold
              ? null
              : TextStyle(
                  color: color,
                  fontWeight: bold ? FontWeight.w600 : null,
                ),
        ),
      );
    }

    if (showPerson && t.userName.isNotEmpty) {
      add(t.userName, bold: true);
      if (t.departmentName.isNotEmpty) add(t.departmentName);
    }
    if (t.isAssigned && t.assignedBy != meta.myId) {
      add('From ${t.assignedByName.isEmpty ? 'a manager' : t.assignedByName}');
    } else if (t.isAssigned && t.userId != meta.myId) {
      add('Assigned by you');
    }
    if (t.dueDate != null && t.status.isOpen) {
      add(
        overdue
            ? 'Overdue · was due ${taskDay(t.dueDate!, today: today)}'
            : dueToday
            ? 'Due today'
            : 'Due ${taskDay(t.dueDate!, today: today)}',
        color: overdue ? scheme.error : null,
        bold: overdue || dueToday,
      );
    }
    final submitted = t.review == ReviewState.none ? '' : submittedLabel(t);
    if (submitted.isNotEmpty) add(submitted);
    if (t.reference.isNotEmpty) add('Ref ${t.reference}');
    if (t.commentCount > 0) {
      if (info.isNotEmpty) info.add(const TextSpan(text: '  ·  '));
      info.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Icon(Icons.chat_bubble_outline, size: 12, color: c.textMuted),
        ),
      );
      info.add(TextSpan(text: ' ${t.commentCount}'));
    }

    final outputs = [
      for (final e in t.outputs.entries)
        '${dept?.outputLabel(e.key) ?? e.key.replaceAll('_', ' ')} ${e.value}',
    ].join('  ·  ');

    Widget statusPill() {
      final pill = TaskPill(
        t.status.label,
        statusColor(t.status, theme),
        icon: t.status.icon,
        trailingIcon: onStatus == null ? null : Icons.arrow_drop_down,
      );
      if (onStatus == null) return pill;
      return PopupMenuButton<ReportStatus>(
        key: t.id == null ? null : ValueKey('status-menu-${t.id}'),
        tooltip: 'Change status',
        initialValue: t.status,
        onSelected: (s) {
          if (s != t.status) onStatus!(s);
        },
        itemBuilder: (_) => [
          for (final s in ReportStatus.working)
            PopupMenuItem(
              value: s,
              child: Row(
                children: [
                  Icon(s.icon, size: 16, color: statusColor(s, theme)),
                  const SizedBox(width: 10),
                  Text(s.label),
                ],
              ),
            ),
        ],
        child: pill,
      );
    }

    Widget note(String label, String text, Color color, Color bg) => Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Dt.rSm),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: TextStyle(fontWeight: FontWeight.w700, color: color),
            ),
            TextSpan(text: text),
          ],
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(Dt.rMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: t.id == null ? null : ValueKey('report-${t.id}'),
          focusNode: focusNode,
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(Dt.rMd),
            ),
            padding: EdgeInsets.fromLTRB(onTick == null ? 14 : 4, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (onTick != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: SizedBox(
                      width: 36,
                      height: 24,
                      child: Checkbox(
                        key: ValueKey('tick-${t.id}'),
                        value: false,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        semanticLabel: 'Done: submit ${t.description}',
                        onChanged: (_) => onTick!(),
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LayoutBuilder(
                        builder: (context, box) {
                          final title = Text.rich(
                            TextSpan(
                              children: [
                                if (t.id != null)
                                  TextSpan(
                                    text: '${t.ref}  ',
                                    style: TextStyle(
                                      color: c.textMuted,
                                      fontWeight: FontWeight.w600,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                TextSpan(text: t.description),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          );
                          final pills = Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            alignment: WrapAlignment.end,
                            children: [
                              if (t.pending)
                                TaskPill(
                                  'Waiting to send',
                                  c.textMuted,
                                  key: ValueKey('pending-${t.id}'),
                                  icon: Icons.cloud_upload_outlined,
                                ),
                              if (t.urgency != TaskUrgency.normal)
                                UrgencyPill(t.urgency),
                              if (t.review == ReviewState.none ||
                                  t.review == ReviewState.returned)
                                statusPill(),
                              if (t.review != ReviewState.none &&
                                  !(t.pending && t.isSubmitted))
                                TaskPill(
                                  t.review == ReviewState.submitted
                                      ? 'Awaiting review'
                                      : t.review.label,
                                  reviewColor(t.review, theme),
                                  icon: switch (t.review) {
                                    ReviewState.approved => Icons.verified,
                                    ReviewState.returned => Icons.undo,
                                    _ => Icons.hourglass_top,
                                  },
                                ),
                            ],
                          );
                          // Narrow (phones): the labels go under the title, so
                          // the title keeps the width.
                          if (box.maxWidth < _wide) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                title,
                                const SizedBox(height: 6),
                                pills,
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: title),
                              const SizedBox(width: 8),
                              pills,
                              for (final a in actions) ...[
                                const SizedBox(width: 6),
                                a,
                              ],
                            ],
                          );
                        },
                      ),
                      if (info.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text.rich(TextSpan(children: info), style: muted),
                      ],
                      if (t.details.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          t.details,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.4,
                          ),
                        ),
                      ],
                      if (outputs.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          outputs,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: c.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      if (t.status == ReportStatus.blocked &&
                          t.blocker.isNotEmpty)
                        note(
                          'Blocked:',
                          t.blocker,
                          scheme.error,
                          scheme.error.withValues(alpha: 0.08),
                        ),
                      if (t.review == ReviewState.returned)
                        note(
                          'Returned${t.reviewedByName.isEmpty ? '' : ' by ${t.reviewedByName}'}:',
                          t.lastReviewNote.isEmpty ? '—' : t.lastReviewNote,
                          scheme.error,
                          scheme.error.withValues(alpha: 0.08),
                        ),
                      if (t.review == ReviewState.approved &&
                          t.lastReviewNote.isNotEmpty)
                        note(
                          'Approved${t.reviewedByName.isEmpty ? '' : ' by ${t.reviewedByName}'}:',
                          t.lastReviewNote,
                          Dt.statusGreen(theme.brightness),
                          c.positiveBg,
                        ),
                      // Wide: the buttons sit beside the labels instead.
                      if (actions.isNotEmpty)
                        LayoutBuilder(
                          builder: (context, box) => box.maxWidth >= _wide
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Wrap(
                                    alignment: WrapAlignment.end,
                                    spacing: 8,
                                    runSpacing: 6,
                                    children: actions,
                                  ),
                                ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- Editor ---

/// What a new task of your own is, chosen at the top of the editor.
enum TaskMode {
  done('Done today', Icons.check_circle_outline),
  doing('Doing now', Icons.timelapse),
  todo('To do', Icons.radio_button_unchecked);

  const TaskMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Adds a task (or changes [existing]).
///
/// - Your own new task: [mode] Done today submits it straight away (that's
///   "Add activity"); Doing now / To do put it on your list.
/// - [assign]: a director, manager or head gives a task to one or more
///   people ([assignTo] chosen first, if known).
///
/// With [template], a new task starts as a copy of it. Returns the last one
/// saved.
Future<ActivityReport?> showReportEditor(
  BuildContext context, {
  required ReportsMeta meta,
  ActivityReport? existing,
  ActivityReport? template,
  bool assign = false,
  int? assignTo,
  TaskMode? mode,
  ReportDraft? draft,
}) => showDialog<ActivityReport>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ReportEditor(
    host: context,
    meta: meta,
    existing: existing,
    template: template,
    assign: assign,
    assignTo: assignTo,
    mode: mode,
    draft: draft,
  ),
);

/// What was typed in the editor when it was closed, to bring it back with
/// Undo.
class ReportDraft {
  const ReportDraft({
    required this.task,
    required this.mode,
    required this.people,
    required this.assign,
    this.existing,
  });

  final ActivityReport task;
  final TaskMode mode;
  final Set<int> people;
  final bool assign;
  final ActivityReport? existing;
}

class _ReportEditor extends ConsumerStatefulWidget {
  const _ReportEditor({
    required this.host,
    required this.meta,
    this.existing,
    this.template,
    this.assign = false,
    this.assignTo,
    this.mode,
    this.draft,
  });

  /// Where it was opened from (to open it again with Undo).
  final BuildContext host;
  final ReportsMeta meta;
  final ActivityReport? existing;
  final ActivityReport? template;
  final bool assign;
  final int? assignTo;

  /// Null: the one used last.
  final TaskMode? mode;
  final ReportDraft? draft;

  @override
  ConsumerState<_ReportEditor> createState() => _ReportEditorState();
}

class _ReportEditorState extends ConsumerState<_ReportEditor> {
  late final ReportDraft? _draft = widget.draft;
  late final ActivityReport? _e = _draft?.existing ?? widget.existing;
  // What it starts from: a draft brought back, the task, or a copy.
  late final ActivityReport? _from = _draft?.task ?? _e ?? widget.template;
  late final ActivityReport? _full = _draft?.task ?? _e;
  late final bool _assign = (_draft?.assign ?? widget.assign) && _e == null;
  late final ReportChoices _choices = ref.read(reportChoicesProvider);
  late TaskMode _mode =
      _draft?.mode ??
      widget.mode ??
      TaskMode.values.firstWhere(
        (m) => m.name == _choices.mode,
        orElse: () => TaskMode.done,
      );
  late final _title = TextEditingController(text: _from?.description);
  late final _details = TextEditingController(text: _full?.details);
  late final _reference = TextEditingController(text: _from?.reference);
  late final _blocker = TextEditingController(text: _full?.blocker);
  final _referenceFocus = FocusNode();
  final _personSearch = TextEditingController();
  late final Set<int> _people = {...?_draft?.people, ?widget.assignTo};
  late ReportStatus _status = _full?.status.isOpen == true
      ? _full!.status
      : ReportStatus.toDo;
  late TaskUrgency _urgency =
      _from?.urgency ??
      (_isNew && !_assign ? _choices.urgency : TaskUrgency.normal);
  late DateTime? _due = _full?.dueDate;
  late final Department? _dept = widget.meta.department(
    _e?.departmentId ?? (_assign ? null : widget.meta.myDepartmentId),
  );
  late final Map<String, int> _outputs = {
    for (final o in _dept?.outputs ?? const <OutputField>[])
      o.key: _full?.outputs[o.key] ?? 0,
  };

  /// Urgency, due date, notes and reference show (new tasks of your own
  /// keep them behind "More" unless something is already in them).
  late bool _more =
      !_isNew ||
      _details.text.isNotEmpty ||
      _reference.text.isNotEmpty ||
      _due != null;
  bool _busy = false;
  String? _error;

  /// Saved with "Save & add another", shown under the title.
  final List<ActivityReport> _added = [];

  bool get _isNew => _e == null;

  /// A new task of your own, done already: it's submitted on save.
  bool get _submitting => _isNew && !_assign && _mode == TaskMode.done;

  late final String _opened = _snapshot;

  String get _snapshot => [
    _title.text,
    _details.text,
    _reference.text,
    _blocker.text,
    _status,
    _urgency,
    _due,
    _people.join(','),
    _mode,
    _outputs.values.join(','),
  ].join('\u0000');

  @override
  void initState() {
    super.initState();
    _opened;
  }

  @override
  void dispose() {
    _title.dispose();
    _details.dispose();
    _reference.dispose();
    _blocker.dispose();
    _referenceFocus.dispose();
    _personSearch.dispose();
    super.dispose();
  }

  /// Closes it. What was typed isn't asked about: Undo brings it back.
  void _close() {
    if (_busy) return;
    final changed = _snapshot != _opened && _title.text.trim().isNotEmpty;
    final draft = ReportDraft(
      task: _build(),
      mode: _mode,
      people: {..._people},
      assign: _assign,
      existing: _e,
    );
    final messenger = ScaffoldMessenger.of(context);
    final host = widget.host;
    final meta = widget.meta;
    Navigator.of(context).pop(_added.lastOrNull);
    if (!changed) return;
    reportSnack(
      messenger,
      _isNew ? 'Not saved.' : 'Changes not saved.',
      onUndo: () {
        if (host.mounted) showReportEditor(host, meta: meta, draft: draft);
      },
    );
  }

  DateTime get _today => widget.meta.today;

  /// One-tap due dates: today, tomorrow, Friday, next Monday.
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
      ('In 2 weeks', day(14)),
    ];
  }

  Future<void> _pickDue() async {
    final initial = _due ?? _today.add(const Duration(days: 1));
    final first = DateTime(_today.year - 1);
    final last = DateTime(_today.year + 2);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.isBefore(first) ? initial : first,
      lastDate: initial.isAfter(last) ? initial : last,
      helpText: 'Due date',
    );
    if (picked != null) setState(() => _due = picked);
  }

  ReportStatus get _savedStatus => _isNew && !_assign
      ? switch (_mode) {
          TaskMode.done => ReportStatus.done,
          TaskMode.doing => ReportStatus.inProgress,
          TaskMode.todo => ReportStatus.toDo,
        }
      : _assign
      ? ReportStatus.toDo
      : _status;

  ActivityReport _build({int? forUser}) => ActivityReport(
    id: _e?.id,
    pending: _e?.pending ?? false,
    userId: forUser ?? _e?.userId,
    description: _title.text,
    details: _details.text,
    reference: _reference.text,
    outputs: {
      for (final e in (_e?.outputs ?? const <String, int>{}).entries)
        if (!_outputs.containsKey(e.key)) e.key: e.value,
      for (final e in _outputs.entries)
        if (e.value > 0) e.key: e.value,
    },
    status: _savedStatus,
    blocker: _savedStatus == ReportStatus.blocked ? _blocker.text : '',
    urgency: _urgency,
    dueDate: _submitting ? null : _due,
  );

  Future<void> _save({bool another = false}) async {
    String? error;
    if (_assign && _people.isEmpty) {
      error = 'Choose who the task is for.';
    } else if (_title.text.trim().isEmpty) {
      error = 'Give the task a title.';
    } else if (_savedStatus == ReportStatus.blocked &&
        _blocker.text.trim().isEmpty) {
      error = 'Say what is blocking it, so someone can help.';
    }
    setState(() => _error = error);
    if (error != null || _busy) return;
    setState(() => _busy = true);
    final service = ref.read(dailyReportsProvider);
    final outbox = ref.read(reportOutboxProvider.notifier);
    if (_isNew && !_assign) {
      unawaited(
        ref
            .read(reportChoicesProvider.notifier)
            .remember(mode: _mode.name, urgency: _urgency),
      );
    }
    try {
      ActivityReport? last;
      if (_assign) {
        for (final person in _people) {
          last = await service.save(_build(forUser: person));
        }
      } else {
        last = (await outbox.save(_build(), submit: _submitting)).task;
      }
      if (!mounted) return;
      if (another && last != null) {
        setState(() {
          _added.add(last!);
          _busy = false;
          _title.clear();
          _details.clear();
          _reference.clear();
          _blocker.clear();
          for (final k in _outputs.keys) {
            _outputs[k] = 0;
          }
          _due = null;
        });
        return;
      }
      Navigator.of(context).pop(last);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeReportError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
        },
        child: _dialog(context, theme),
      ),
    );
  }

  Widget _label(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Text(text.toUpperCase(), style: microLabel(theme)),
  );

  Widget _dialog(BuildContext context, ThemeData theme) {
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final dept = _dept;
    final showOutputs =
        dept != null &&
        dept.outputs.isNotEmpty &&
        !_assign &&
        (_submitting || !_isNew);
    final showDue = !_submitting;
    final blocked = !_isNew && !_assign && _status == ReportStatus.blocked;
    final title = _assign
        ? 'Assign a task'
        : !_isNew
        ? 'Edit task ${_e!.ref}'
        : _mode == TaskMode.done
        ? 'Add activity'
        : 'Add a task';
    final primary = _assign
        ? (_people.length > 1 ? 'Assign to ${_people.length}' : 'Assign')
        : !_isNew
        ? 'Save'
        : _mode == TaskMode.done
        ? 'Submit'
        : 'Add to my list';

    return AlertDialog(
      title: Text(title),
      scrollable: true,
      content: SizedBox(
        width: 580,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_added.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: c.positiveBg,
                  borderRadius: BorderRadius.circular(Dt.rSm),
                ),
                child: Text(
                  'Saved ${[for (final a in _added) a.ref].join(', ')}. '
                  'Add the next one, or close when you’re done.',
                  key: const ValueKey('added-list'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: c.positiveFg,
                  ),
                ),
              ),
            if (_isNew && !_assign) ...[
              SegmentedButton<TaskMode>(
                key: const ValueKey('task-mode'),
                segments: [
                  for (final m in TaskMode.values)
                    ButtonSegment(
                      value: m,
                      icon: Icon(m.icon, size: 16),
                      label: Text(m.label),
                    ),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: _busy
                    ? null
                    : (v) => setState(() => _mode = v.first),
              ),
              const SizedBox(height: 6),
              Text(switch (_mode) {
                TaskMode.done =>
                  'Work you’ve finished. It’s submitted for today '
                      '(${taskDay(_today, today: _today)}) and goes for review.',
                TaskMode.doing =>
                  'Goes on your list as Doing. Submit it when it’s done.',
                TaskMode.todo =>
                  'Goes on your list to do later. Your manager can see it.',
              }, style: muted),
              const SizedBox(height: 10),
            ],
            if (_assign) ..._peoplePicker(theme, muted),
            TextField(
              key: const ValueKey('report-description'),
              controller: _title,
              autofocus: _isNew && !_assign,
              enabled: !_busy,
              maxLength: 300,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Task',
                hintText: _mode == TaskMode.done && !_assign
                    ? 'What you did, e.g. Followed up 12 applications'
                    : 'What needs doing, e.g. Follow up the pending COEs',
              ),
            ),
            if (!_isNew && !_assign) ...[
              _label(theme, 'Status'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in ReportStatus.working)
                    ChoiceChip(
                      key: ValueKey('status-${s.code}'),
                      showCheckmark: false,
                      avatar: Icon(
                        s.icon,
                        size: 16,
                        color: statusColor(s, theme),
                      ),
                      label: Text(s.label),
                      selected: _status == s,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _status = s),
                    ),
                ],
              ),
            ],
            if (!_more && !_assign)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Tooltip(
                      message: _submitting
                          ? 'Urgency, notes and a reference'
                          : 'Urgency, a due date, notes and a reference',
                      child: TextButton.icon(
                        key: const ValueKey('report-more'),
                        onPressed: _busy
                            ? null
                            : () => setState(() => _more = true),
                        icon: const Icon(Icons.expand_more, size: 18),
                        label: const Text('More details'),
                      ),
                    ),
                    if (_urgency != TaskUrgency.normal) UrgencyPill(_urgency),
                  ],
                ),
              ),
            if (_more || _assign) ...[
              _label(theme, 'Urgency'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final u in TaskUrgency.values)
                    ChoiceChip(
                      key: ValueKey('urgency-${u.code}'),
                      showCheckmark: false,
                      avatar: Icon(
                        Icons.circle,
                        size: 12,
                        color: u.color(theme.brightness),
                      ),
                      label: Text(u.label),
                      selected: _urgency == u,
                      selectedColor: u
                          .color(theme.brightness)
                          .withValues(alpha: 0.18),
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _urgency = u),
                    ),
                ],
              ),
              if (showDue) ...[
                _label(theme, 'Due'),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final (label, day) in _quickDues)
                      ChoiceChip(
                        key: ValueKey('due-$label'),
                        label: Text(label),
                        selected: _due == day,
                        onSelected: _busy
                            ? null
                            : (_) => setState(
                                () => _due = _due == day ? null : day,
                              ),
                      ),
                    ActionChip(
                      key: const ValueKey('report-due'),
                      avatar: const Icon(Icons.event, size: 16),
                      label: Text(
                        _due == null || _quickDues.any((q) => q.$2 == _due)
                            ? 'Pick a date'
                            : taskDay(_due!, today: _today),
                      ),
                      onPressed: _busy ? null : _pickDue,
                    ),
                    if (_due != null)
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _due = null),
                        child: const Text('No due date'),
                      ),
                  ],
                ),
                if (_due != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Due ${_dayYearFormat.format(_due!)}',
                      style: muted,
                    ),
                  ),
              ],
            ],
            if (showOutputs) ...[
              _label(theme, 'Counts (where you can count them)'),
              for (final o in dept.outputs)
                _Stepper(
                  key: ValueKey('output-${o.key}'),
                  label: o.label,
                  value: _outputs[o.key] ?? 0,
                  enabled: !_busy,
                  onChanged: (v) => setState(() => _outputs[o.key] = v),
                ),
            ],
            if (blocked) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('report-blocker'),
                controller: _blocker,
                enabled: !_busy,
                minLines: 1,
                maxLines: 3,
                maxLength: 1000,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'What’s blocking it',
                  hintText: 'The problem, and the help you need',
                ),
              ),
            ],
            if (_assign && !_more)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('report-more'),
                  onPressed: _busy ? null : () => setState(() => _more = true),
                  icon: const Icon(Icons.expand_more, size: 18),
                  label: const Text('Instructions, reference'),
                ),
              ),
            if (_more) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('report-details'),
                controller: _details,
                enabled: !_busy,
                minLines: 2,
                maxLines: 6,
                maxLength: 4000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: _submitting
                      ? 'What you did (optional)'
                      : 'Notes (optional)',
                  hintText: _submitting
                      ? 'Details the reviewer should know'
                      : _assign
                      ? 'Instructions, what “done” looks like'
                      : 'Anything to remember about it',
                ),
              ),
              _referenceField(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const ValueKey('report-error'),
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
          onPressed: _busy ? null : _close,
          child: Text(_added.isEmpty ? 'Cancel' : 'Close'),
        ),
        if (_isNew)
          TextButton(
            key: const ValueKey('report-save-another'),
            onPressed: _busy ? null : () => _save(another: true),
            child: const Text('Save & add another'),
          ),
        FilledButton(
          key: const ValueKey('report-save'),
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(primary),
        ),
      ],
    );
  }

  /// Student names from Applications, for whoever may open it.
  late final List<String> _students = () {
    final user = ref.read(currentUserProvider);
    if (!(user?.mayOpen(AppTab.applications.name) ?? true)) {
      return const <String>[];
    }
    try {
      final names = <String>{
        for (final a in ref.read(applicationRepositoryProvider).all())
          if (a.student.trim().isNotEmpty) a.student.trim(),
      };
      return names.toList()..sort();
    } catch (_) {
      return const <String>[];
    }
  }();

  Widget _referenceField() => RawAutocomplete<String>(
    textEditingController: _reference,
    focusNode: _referenceFocus,
    optionsBuilder: (value) {
      final q = value.text.trim().toLowerCase();
      if (q.length < 2 || _students.isEmpty) return const [];
      return _students
          .where((n) => n.toLowerCase().contains(q) && n.toLowerCase() != q)
          .take(6);
    },
    fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
      key: const ValueKey('report-reference'),
      controller: controller,
      focusNode: focus,
      enabled: !_busy,
      maxLength: 200,
      decoration: InputDecoration(
        labelText: 'Reference (optional)',
        helperText: _students.isEmpty
            ? 'Student, application or case reference. No passport '
                  'numbers or other personal details.'
            : 'Start typing a student’s name, or a case reference. No '
                  'passport numbers or other personal details.',
        helperMaxLines: 2,
      ),
    ),
    optionsViewBuilder: (context, onSelected, options) => Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(Dt.rSm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240, maxWidth: 420),
          child: ListView(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            children: [
              for (final o in options)
                ListTile(
                  key: ValueKey('reference-option-$o'),
                  dense: true,
                  leading: const Icon(Icons.school_outlined, size: 18),
                  title: Text(o),
                  onTap: () => onSelected(o),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  List<Widget> _peoplePicker(ThemeData theme, TextStyle? muted) {
    final query = _personSearch.text.trim().toLowerCase();
    final people = [
      for (final p in widget.meta.people)
        if (p.active &&
            p.id != widget.meta.myId &&
            (query.isEmpty || p.fullName.toLowerCase().contains(query)))
          p,
    ];
    return [
      Text('FOR', style: microLabel(theme)),
      const SizedBox(height: 6),
      if (widget.meta.people.length > 8)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            key: const ValueKey('assign-search'),
            controller: _personSearch,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Find a person',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
      Wrap(
        key: const ValueKey('assign-person'),
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final p in people)
            FilterChip(
              key: ValueKey('assign-${p.id}'),
              label: Text(
                [
                  p.fullName,
                  widget.meta.department(p.departmentId)?.name,
                ].nonNulls.join(' · '),
              ),
              selected: _people.contains(p.id),
              onSelected: _busy
                  ? null
                  : (on) => setState(
                      () => on ? _people.add(p.id) : _people.remove(p.id),
                    ),
            ),
          if (people.isEmpty) Text('Nobody matches.', style: muted),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        'Pick one or more people. Each gets their own copy on their list, '
        'marked as from you, and a notification. When they submit it, it '
        'comes to you for review.',
        style: muted,
      ),
      const SizedBox(height: 10),
    ];
  }
}

/// A count with − and + buttons, and a box to type it.
class _Stepper extends StatefulWidget {
  const _Stepper({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  State<_Stepper> createState() => _StepperState();
}

class _StepperState extends State<_Stepper> {
  late final _text = TextEditingController(
    text: widget.value == 0 ? '' : '${widget.value}',
  );

  @override
  void didUpdateWidget(_Stepper old) {
    super.didUpdateWidget(old);
    final shown = int.tryParse(_text.text) ?? 0;
    if (shown != widget.value) {
      _text.text = widget.value == 0 ? '' : '${widget.value}';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _set(int v) {
    final next = v.clamp(0, 99999);
    _text.text = next == 0 ? '' : '$next';
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Expanded(child: Text(widget.label)),
        IconButton(
          tooltip: 'One less',
          visualDensity: VisualDensity.compact,
          onPressed: widget.enabled && widget.value > 0
              ? () => _set(widget.value - 1)
              : null,
          icon: const Icon(Icons.remove_circle_outline, size: 20),
        ),
        SizedBox(
          width: 64,
          child: TextField(
            controller: _text,
            enabled: widget.enabled,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(5),
            ],
            decoration: const InputDecoration(isDense: true, hintText: '0'),
            onChanged: (t) => widget.onChanged(int.tryParse(t) ?? 0),
          ),
        ),
        IconButton(
          tooltip: 'One more',
          visualDensity: VisualDensity.compact,
          onPressed: widget.enabled ? () => _set(widget.value + 1) : null,
          icon: const Icon(Icons.add_circle_outline, size: 20),
        ),
      ],
    ),
  );
}

// -------------------------------------------------------------- Submit ---

/// Marks [task] done and sends it for review, after the person says what
/// they did. Returns how it went (it may be waiting to send).
Future<SaveOutcome?> showSubmitDialog(
  BuildContext context, {
  required ReportsMeta meta,
  required ActivityReport task,
}) => showDialog<SaveOutcome>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _SubmitDialog(meta: meta, task: task),
);

class _SubmitDialog extends ConsumerStatefulWidget {
  const _SubmitDialog({required this.meta, required this.task});
  final ReportsMeta meta;
  final ActivityReport task;

  @override
  ConsumerState<_SubmitDialog> createState() => _SubmitDialogState();
}

class _SubmitDialogState extends ConsumerState<_SubmitDialog> {
  late final _details = TextEditingController(text: widget.task.details);
  final _note = TextEditingController();
  late final Department? _dept = widget.meta.department(
    widget.task.departmentId,
  );
  late final Map<String, int> _outputs = {
    for (final o in _dept?.outputs ?? const <OutputField>[])
      o.key: widget.task.outputs[o.key] ?? 0,
  };
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _details.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final t = widget.task;
    try {
      final saved = await ref
          .read(reportOutboxProvider.notifier)
          .save(
            submit: true,
            t.copyWith(
              details: _details.text,
              outputs: {
                for (final e in t.outputs.entries)
                  if (!_outputs.containsKey(e.key)) e.key: e.value,
                for (final e in _outputs.entries)
                  if (e.value > 0) e.key: e.value,
              },
              status: ReportStatus.done,
            ),
            note: _note.text,
          );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeReportError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final t = widget.task;
    final dept = _dept;
    final reviewer = t.isAssigned && t.assignedByName.isNotEmpty
        ? t.assignedByName
        : 'your department head or manager';
    return AlertDialog(
      title: Text('Submit ${t.ref}'),
      scrollable: true,
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.description,
              style: theme.textTheme.titleSmall?.copyWith(height: 1.3),
            ),
            const SizedBox(height: 6),
            Text(
              'It’s marked done and dated today, '
              '${taskDay(widget.meta.today, today: widget.meta.today)}. '
              '${t.review == ReviewState.returned ? 'It goes back' : 'It goes'} '
              'to $reviewer to review.',
              style: muted,
            ),
            if (t.review == ReviewState.returned &&
                t.lastReviewNote.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(Dt.rSm),
                ),
                child: Text(
                  'Returned: ${t.lastReviewNote}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('submit-details'),
              controller: _details,
              autofocus: true,
              enabled: !_busy,
              minLines: 3,
              maxLines: 8,
              maxLength: 4000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'What you did',
                hintText: 'The work done, results, anything left over',
              ),
            ),
            if (dept != null && dept.outputs.isNotEmpty) ...[
              Text('COUNTS', style: microLabel(theme)),
              const SizedBox(height: 6),
              for (final o in dept.outputs)
                _Stepper(
                  key: ValueKey('submit-output-${o.key}'),
                  label: o.label,
                  value: _outputs[o.key] ?? 0,
                  enabled: !_busy,
                  onChanged: (v) => setState(() => _outputs[o.key] = v),
                ),
              const SizedBox(height: 8),
            ],
            TextField(
              key: const ValueKey('submit-note'),
              controller: _note,
              enabled: !_busy,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Note to the reviewer (optional)',
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                key: const ValueKey('submit-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const ValueKey('submit-confirm'),
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send, size: 16),
          label: const Text('Submit'),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- Review ---

/// Approves [task] (a comment is optional) or returns it ([approve] false:
/// a comment is needed). Returns the reviewed task, or null if cancelled.
Future<ActivityReport?> reviewTask(
  BuildContext context,
  WidgetRef ref, {
  required ActivityReport task,
  required bool approve,
}) => showDialog<ActivityReport>(
  context: context,
  builder: (_) => _ReviewDialog(task: task, approve: approve),
);

class _ReviewDialog extends ConsumerStatefulWidget {
  const _ReviewDialog({required this.task, required this.approve});

  final ActivityReport task;
  final bool approve;

  @override
  ConsumerState<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends ConsumerState<_ReviewDialog> {
  // Owned by the dialog, so it outlives the closing animation.
  final _comment = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_busy) return;
    if (!widget.approve && _comment.text.trim().isEmpty) {
      setState(() => _error = 'Say what needs fixing.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(dailyReportsProvider)
          .review(
            widget.task.id!,
            approve: widget.approve,
            comment: _comment.text,
          );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeReportError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final task = widget.task;
    final approve = widget.approve;
    return AlertDialog(
      title: Text(approve ? 'Approve ${task.ref}' : 'Return ${task.ref}'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${task.userName}: ${task.description}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              approve
                  ? 'It’s marked approved and ${task.userName.isEmpty ? 'they are' : '${task.userName} is'} notified.'
                  : 'It goes back on ${task.userName.isEmpty ? 'their' : '${task.userName}’s'} list with your comment, to do again and resubmit.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Dt.textMuted(theme),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('review-comment'),
              controller: _comment,
              autofocus: true,
              enabled: !_busy,
              minLines: 2,
              maxLines: 5,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: approve ? 'Comment (optional)' : 'What needs fixing',
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                key: const ValueKey('review-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('review-confirm'),
          style: approve
              ? null
              : FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
          onPressed: _busy ? null : _go,
          child: Text(approve ? 'Approve' : 'Return'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- Details ---

/// A task in full: what was asked and done, where it is, the review
/// timeline with comments, and its history. True when it changed.
Future<bool> showReportDetails(
  BuildContext context, {
  required ReportsMeta meta,
  required ActivityReport report,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _ReportDetails(meta: meta, report: report),
    ) ??
    false;

class _ReportDetails extends ConsumerStatefulWidget {
  const _ReportDetails({required this.meta, required this.report});

  final ReportsMeta meta;
  final ActivityReport report;

  @override
  ConsumerState<_ReportDetails> createState() => _ReportDetailsState();
}

class _ReportDetailsState extends ConsumerState<_ReportDetails> {
  late ActivityReport _task = widget.report;
  List<ReportChange>? _history;
  List<ReportComment>? _comments;
  final _comment = TextEditingController();
  bool _sending = false;
  bool _changed = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadComments();
    final id = _task.id;
    if (id != null) {
      ref
          .read(dailyReportsProvider)
          .history(id)
          .then((h) {
            if (mounted) setState(() => _history = h);
          })
          .catchError((_) {
            if (mounted) setState(() => _history = const []);
          });
    }
  }

  Future<void> _loadComments() async {
    final id = _task.id;
    if (id == null) return;
    try {
      final c = await ref.read(dailyReportsProvider).comments(id);
      if (mounted) setState(() => _comments = c);
    } catch (_) {
      if (mounted) setState(() => _comments = const []);
    }
  }

  void _snack(String text) => reportSnack(ScaffoldMessenger.of(context), text);

  Future<void> _sendComment() async {
    final id = _task.id;
    final body = _comment.text.trim();
    if (id == null || body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final all = await ref.read(dailyReportsProvider).addComment(id, body);
      if (!mounted) return;
      setState(() {
        _comments = all;
        _comment.clear();
        _changed = true;
      });
    } catch (e) {
      if (mounted) _snack(describeReportError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deleteComment(ReportComment c) async {
    try {
      await ref.read(dailyReportsProvider).deleteComment(c.id);
      _changed = true;
      await _loadComments();
    } catch (e) {
      if (mounted) _snack(describeReportError(e));
    }
  }

  bool get _mine => _task.userId == widget.meta.myId;
  bool get _admin => ref.read(isAdminProvider);

  bool get _canEdit =>
      (_mine &&
          _task.review != ReviewState.submitted &&
          _task.review != ReviewState.approved) ||
      _task.assignedBy == widget.meta.myId ||
      _admin;

  bool get _canDelete =>
      _task.assignedBy == widget.meta.myId ||
      _admin ||
      (_mine && !_task.isAssigned && _task.review != ReviewState.approved);

  bool get _canSubmit =>
      _mine &&
      _task.review != ReviewState.submitted &&
      _task.review != ReviewState.approved;

  bool get _canReview =>
      _task.review == ReviewState.submitted &&
      canReviewTask(widget.meta, _task);

  void _after(ActivityReport saved) {
    setState(() {
      _task = saved;
      _changed = true;
    });
    _loadComments();
  }

  Future<void> _edit() async {
    final saved = await showReportEditor(
      context,
      meta: widget.meta,
      existing: _task,
    );
    if (saved != null && mounted) _after(saved);
  }

  /// A new task starting as a copy of this one (repeat work).
  Future<void> _again() async {
    final saved = await showReportEditor(
      context,
      meta: widget.meta,
      template: _task,
    );
    if (saved != null && mounted) {
      _changed = true;
      _snack(
        saved.isSubmitted
            ? '${saved.ref} submitted for today'
            : 'Added ${saved.ref} to your list',
      );
    }
  }

  Future<void> _submit() async {
    final actions = TaskActions(context, ref);
    final o = await showSubmitDialog(context, meta: widget.meta, task: _task);
    if (o != null && mounted) {
      _after(o.task);
      actions.submitted(o);
    }
  }

  /// Takes back a submission that hasn't been reviewed yet.
  Future<void> _withdraw() async {
    try {
      final saved = await ref.read(dailyReportsProvider).withdraw(_task.id!);
      if (mounted) {
        _after(saved);
        _snack('${saved.ref} is back on your list');
      }
    } catch (e) {
      if (mounted) _snack(describeReportError(e));
    }
  }

  Future<void> _review(bool approve) async {
    final saved = await reviewTask(context, ref, task: _task, approve: approve);
    if (saved != null && mounted) {
      _after(saved);
      _snack(approve ? '${saved.ref} approved' : '${saved.ref} returned');
    }
  }

  /// Closes and deletes it, with Undo.
  void _delete() {
    final actions = TaskActions(context, ref);
    Navigator.pop(context, true);
    actions.delete(_task);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final t = _task;
    final meta = widget.meta;
    final dept = meta.department(t.departmentId);
    Widget field(String label, String value, {Color? color}) =>
        value.trim().isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label.toUpperCase(), style: microLabel(theme)),
                const SizedBox(height: 3),
                SelectableText(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          );
    final history = _history;
    final facts = <(String, String)>[
      (
        'Person',
        [t.userName, t.departmentName].where((s) => s.isNotEmpty).join(' · '),
      ),
      if (t.isAssigned)
        (
          'Assigned by',
          t.assignedByName.isEmpty ? 'A manager' : t.assignedByName,
        ),
      if (t.createdAt != null) ('Added', taskStamp(t.createdAt!)),
      if (t.dueDate != null)
        (
          'Due',
          '${_dayYearFormat.format(t.dueDate!)}'
              '${t.isOverdue(meta.today) ? ' · overdue' : ''}',
        ),
      if (t.review != ReviewState.none)
        ('Submitted', submittedLabel(t).replaceFirst('Submitted ', '')),
      if (t.reviewedAt != null && t.review != ReviewState.submitted)
        (
          t.review == ReviewState.approved ? 'Approved' : 'Returned',
          '${taskStamp(t.reviewedAt!)}'
              '${t.reviewedByName.isEmpty ? '' : ' by ${t.reviewedByName}'}',
        ),
      if (t.reference.isNotEmpty) ('Reference', t.reference),
    ];

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              TaskPill(t.ref, c.textMuted, key: const ValueKey('task-id')),
              UrgencyPill(t.urgency),
              if (t.review == ReviewState.none ||
                  t.review == ReviewState.returned)
                TaskPill(
                  t.status.label,
                  statusColor(t.status, theme),
                  icon: t.status.icon,
                ),
              if (t.review != ReviewState.none)
                TaskPill(
                  t.review == ReviewState.submitted
                      ? 'Awaiting review'
                      : t.review.label,
                  reviewColor(t.review, theme),
                ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            t.description,
            style: theme.textTheme.titleMedium?.copyWith(height: 1.3),
          ),
        ],
      ),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: c.bg,
                borderRadius: BorderRadius.circular(Dt.rSm),
              ),
              child: Column(
                children: [
                  for (final (label, value) in facts)
                    if (value.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 104,
                              child: Text(label, style: muted),
                            ),
                            Expanded(
                              child: Text(
                                value,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            field(
              t.review == ReviewState.none ? 'Notes' : 'What they did',
              t.details,
            ),
            field(
              'Counts',
              [
                for (final e in t.outputs.entries)
                  '${dept?.outputLabel(e.key) ?? e.key}: ${e.value}',
              ].join('\n'),
            ),
            if (t.status == ReportStatus.blocked)
              field('Blocked by', t.blocker, color: theme.colorScheme.error),
            Text('TIMELINE AND COMMENTS', style: microLabel(theme)),
            const SizedBox(height: 6),
            if (_comments == null)
              const LinearProgressIndicator()
            else ...[
              if (_comments!.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Nothing yet. Ask a question or leave feedback.',
                    style: muted,
                  ),
                ),
              for (final cm in _comments!) _timelineItem(theme, cm),
              const SizedBox(height: 4),
              TextField(
                key: const ValueKey('comment-field'),
                controller: _comment,
                enabled: !_sending,
                minLines: 1,
                maxLines: 4,
                maxLength: 1000,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _sendComment(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Add a comment',
                  suffixIcon: IconButton(
                    key: const ValueKey('comment-send'),
                    tooltip: 'Send',
                    onPressed: _sending ? null : _sendComment,
                    icon: const Icon(Icons.send, size: 18),
                  ),
                ),
              ),
            ],
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const ValueKey('task-history'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 6),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: Text('HISTORY', style: microLabel(theme)),
                children: [
                  if (history == null)
                    const LinearProgressIndicator()
                  else if (history.isEmpty)
                    Text('No history available.', style: muted)
                  else
                    for (final h in history)
                      Text(
                        '${h.label} by ${h.changedBy.isEmpty ? 'a deleted account' : h.changedBy} · ${taskStamp(h.changedAt)}',
                        style: muted,
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 6,
      actions: [
        if (_canDelete)
          TextButton(
            key: const ValueKey('delete-report'),
            onPressed: _delete,
            child: const Text('Delete'),
          ),
        if (_mine && _task.status == ReportStatus.done)
          TextButton(
            key: const ValueKey('repeat-report'),
            onPressed: _again,
            child: const Text('Do again'),
          ),
        if (_canEdit)
          OutlinedButton(
            key: const ValueKey('edit-report'),
            onPressed: _edit,
            child: const Text('Edit'),
          ),
        if (_mine && t.isSubmitted && t.isSaved)
          TextButton(
            key: const ValueKey('withdraw-report'),
            onPressed: _withdraw,
            child: const Text('Take back'),
          ),
        if (_canReview) ...[
          OutlinedButton.icon(
            key: const ValueKey('return-report'),
            onPressed: () => _review(false),
            icon: const Icon(Icons.undo, size: 16),
            label: const Text('Return'),
          ),
          FilledButton.icon(
            key: const ValueKey('approve-report'),
            onPressed: () => _review(true),
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Approve'),
          ),
        ],
        if (_canSubmit)
          FilledButton.icon(
            key: const ValueKey('submit-report'),
            onPressed: _submit,
            icon: const Icon(Icons.send, size: 16),
            label: Text(
              t.review == ReviewState.returned ? 'Resubmit' : 'Submit',
            ),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, _changed),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _timelineItem(ThemeData theme, ReportComment cm) {
    final c = Clarity.of(theme);
    final (icon, color, verb) = switch (cm.kind) {
      CommentKind.submitted => (
        Icons.outbox_outlined,
        c.warningFg,
        'submitted it',
      ),
      CommentKind.approved => (
        Icons.verified,
        Dt.statusGreen(theme.brightness),
        'approved it',
      ),
      CommentKind.returned => (
        Icons.undo,
        theme.colorScheme.error,
        'returned it',
      ),
      CommentKind.comment => (Icons.chat_bubble_outline, c.textMuted, ''),
    };
    final who = cm.userName.isEmpty ? 'A deleted account' : cm.userName;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: who,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (verb.isNotEmpty)
                    TextSpan(
                      text: ' $verb',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  TextSpan(
                    text: '   ${taskStamp(cm.createdAt)}',
                    style: TextStyle(color: c.textMuted, fontSize: 12),
                  ),
                  if (cm.body.isNotEmpty) TextSpan(text: '\n${cm.body}'),
                ],
              ),
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
          ),
          if (cm.kind == CommentKind.comment &&
              (cm.userId == widget.meta.myId || _admin))
            IconButton(
              tooltip: 'Delete comment',
              visualDensity: VisualDensity.compact,
              onPressed: () => _deleteComment(cm),
              icon: const Icon(Icons.delete_outline, size: 16),
            ),
        ],
      ),
    );
  }
}
