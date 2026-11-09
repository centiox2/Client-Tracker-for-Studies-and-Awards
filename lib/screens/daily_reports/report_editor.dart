import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../services/daily_reports_service.dart';
import '../../state/app_state.dart';

final _dayFormat = DateFormat('EEE d MMM y');

Color statusColor(ReportStatus s, ThemeData theme) => switch (s) {
  ReportStatus.completed => Dt.statusGreen(theme.brightness),
  ReportStatus.inProgress => Dt.existingBlue(theme.brightness),
  ReportStatus.pending => theme.colorScheme.onSurfaceVariant,
  ReportStatus.blocked || ReportStatus.escalated => theme.colorScheme.error,
};

/// One report in a list: what was done, by whom, its outputs and status.
class ReportTile extends StatelessWidget {
  const ReportTile({
    super.key,
    required this.report,
    required this.meta,
    required this.today,
    this.onTap,
    this.showPerson = false,
    this.showDate = false,
    this.action,
  });

  final ActivityReport report;
  final ReportsMeta meta;
  final DateTime today;
  final VoidCallback? onTap;
  final bool showPerson;
  final bool showDate;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    final r = report;
    final dept = meta.department(r.departmentId);
    final overdue = r.isOverdue(today);
    final details = [
      if (showPerson) r.userName,
      if (showPerson && r.departmentName.isNotEmpty) r.departmentName,
      if (showDate) _dayFormat.format(r.date),
      if (r.reference.isNotEmpty) 'Ref ${r.reference}',
      if (r.priority != ReportPriority.medium) '${r.priority.label} priority',
      if (r.dueDate != null && r.status.isOpen)
        'Due ${_dayFormat.format(r.dueDate!)}',
    ].join(' · ');
    final outputs = [
      for (final e in r.outputs.entries)
        '${dept?.outputLabel(e.key) ?? e.key} ${e.value}',
    ].join(' · ');
    Widget chip(String text, Color color) => Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Dt.rPill),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
    return InkWell(
      key: r.id == null ? null : ValueKey('report-${r.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(Dt.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor(r.status, theme),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (details.isNotEmpty) Text(details, style: muted),
                  if (outputs.isNotEmpty)
                    Text(outputs, style: theme.textTheme.bodySmall),
                  if (r.blocker.isNotEmpty && r.status.isOpen)
                    Text(
                      'Blocker: ${r.blocker}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (overdue) chip('Overdue', scheme.error),
                    chip(r.status.label, statusColor(r.status, theme)),
                  ],
                ),
                ?action,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Adds a report for [day] (or changes [existing]). Returns the saved one.
Future<ActivityReport?> showReportEditor(
  BuildContext context, {
  required ReportsMeta meta,
  DateTime? day,
  ActivityReport? existing,
}) => showDialog<ActivityReport>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ReportEditor(meta: meta, day: day, existing: existing),
);

class _ReportEditor extends ConsumerStatefulWidget {
  const _ReportEditor({required this.meta, this.day, this.existing});

  final ReportsMeta meta;
  final DateTime? day;
  final ActivityReport? existing;

  @override
  ConsumerState<_ReportEditor> createState() => _ReportEditorState();
}

class _ReportEditorState extends ConsumerState<_ReportEditor> {
  late final ActivityReport? _e = widget.existing;
  late DateTime _date = _e?.date ?? widget.day ?? widget.meta.today;
  late final _description = TextEditingController(text: _e?.description);
  late final _reference = TextEditingController(text: _e?.reference);
  late final _nextAction = TextEditingController(text: _e?.nextAction);
  late final _blocker = TextEditingController(text: _e?.blocker);
  late ReportStatus _status = _e?.status ?? ReportStatus.completed;
  late ReportPriority _priority = _e?.priority ?? ReportPriority.medium;
  late DateTime? _due = _e?.dueDate;
  late final Department? _dept = widget.meta.department(
    _e?.departmentId ?? widget.meta.myDepartmentId,
  );
  late final Map<String, TextEditingController> _outputs = {
    for (final o in _dept?.outputs ?? const <OutputField>[])
      o.key: TextEditingController(
        text: _e?.outputs[o.key] == null ? '' : '${_e!.outputs[o.key]}',
      ),
  };
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _description.dispose();
    _reference.dispose();
    _nextAction.dispose();
    _blocker.dispose();
    for (final c in _outputs.values) {
      c.dispose();
    }
    super.dispose();
  }

  DateTime get _today => widget.meta.today;

  /// Up to 7 days back (managers: further), never in the future.
  DateTime get _earliest => widget.meta.scope == ReportScope.all
      ? DateTime(_today.year - 1, _today.month, _today.day)
      : _today.subtract(const Duration(days: 7));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isBefore(_earliest) ? _earliest : _date,
      firstDate: _date.isBefore(_earliest) ? _date : _earliest,
      lastDate: _today,
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickDue() async {
    final initial = _due ?? _today.add(const Duration(days: 1));
    // The range always includes the date already set, however old or far
    // off (the picker refuses a starting date outside its range).
    final first = DateTime(_today.year - 1);
    final last = DateTime(_today.year + 2);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: initial.isBefore(first) ? initial : first,
      lastDate: initial.isAfter(last) ? initial : last,
      helpText: 'Due / follow-up date',
    );
    if (picked != null) setState(() => _due = picked);
  }

  Future<void> _save() async {
    String? error;
    if (_description.text.trim().isEmpty) {
      error = 'Describe the activity or task.';
    } else if (_status.isOpen && _due == null) {
      error =
          'Anything not completed needs a due / follow-up date, so it can '
          'be followed up.';
    }
    setState(() => _error = error);
    if (error != null || _busy) return;
    setState(() => _busy = true);
    final report = ActivityReport(
      id: _e?.id,
      date: _date,
      description: _description.text,
      reference: _reference.text,
      outputs: {
        // Counts for outputs the department no longer has (renamed or
        // removed since): kept as they were.
        for (final e in (_e?.outputs ?? const <String, int>{}).entries)
          if (!_outputs.containsKey(e.key)) e.key: e.value,
        for (final e in _outputs.entries)
          if ((int.tryParse(e.value.text.trim()) ?? 0) > 0)
            e.key: int.parse(e.value.text.trim()),
      },
      status: _status,
      nextAction: _nextAction.text,
      blocker: _blocker.text,
      priority: _priority,
      dueDate: _due,
    );
    try {
      final saved = await ref.read(dailyReportsProvider).save(report);
      if (mounted) Navigator.of(context).pop(saved);
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
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    final dept = _dept;
    return AlertDialog(
      title: Text(_e == null ? 'Add activity' : 'Edit activity'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(dept?.name ?? '', style: muted),
                TextButton.icon(
                  key: const ValueKey('report-date'),
                  onPressed: _busy ? null : _pickDate,
                  icon: const Icon(Icons.event, size: 16),
                  label: Text(
                    _date == _today
                        ? 'Today, ${_dayFormat.format(_date)}'
                        : _dayFormat.format(_date),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              key: const ValueKey('report-description'),
              controller: _description,
              autofocus: _e == null,
              enabled: !_busy,
              minLines: 2,
              maxLines: 5,
              maxLength: 2000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Activity / task',
                hintText:
                    'What you did, e.g. Followed up on 12 applications with '
                    'universities',
              ),
            ),
            if (dept != null && dept.outputs.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'OUTPUTS (WHERE YOU CAN COUNT THEM)',
                style: microLabel(theme),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final o in dept.outputs)
                    SizedBox(
                      width: 168,
                      child: TextField(
                        key: ValueKey('output-${o.key}'),
                        controller: _outputs[o.key],
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        decoration: InputDecoration(
                          labelText: o.label,
                          isDense: true,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: 200,
                  child: DropdownButtonFormField<ReportStatus>(
                    key: const ValueKey('report-status'),
                    initialValue: _status,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: [
                      for (final s in ReportStatus.values)
                        DropdownMenuItem(value: s, child: Text(s.label)),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _status = v ?? _status),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: DropdownButtonFormField<ReportPriority>(
                    key: const ValueKey('report-priority'),
                    initialValue: _priority,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Priority'),
                    items: [
                      for (final p in ReportPriority.values)
                        DropdownMenuItem(value: p, child: Text(p.label)),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _priority = v ?? _priority),
                  ),
                ),
                SizedBox(
                  width: 240,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: _status.isOpen
                          ? 'Due / follow-up date (needed)'
                          : 'Due / follow-up date',
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            key: const ValueKey('report-due'),
                            onPressed: _busy ? null : _pickDue,
                            style: TextButton.styleFrom(
                              alignment: Alignment.centerLeft,
                              padding: EdgeInsets.zero,
                            ),
                            child: Text(
                              _due == null
                                  ? 'Choose date'
                                  : _dayFormat.format(_due!),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        if (_due != null)
                          IconButton(
                            tooltip: 'Clear',
                            visualDensity: VisualDensity.compact,
                            onPressed: _busy
                                ? null
                                : () => setState(() => _due = null),
                            icon: const Icon(Icons.close, size: 16),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('report-next'),
              controller: _nextAction,
              enabled: !_busy,
              minLines: 1,
              maxLines: 3,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Pending work / next action',
                hintText: 'What remains and the next step',
              ),
            ),
            TextField(
              key: const ValueKey('report-blocker'),
              controller: _blocker,
              enabled: !_busy,
              minLines: 1,
              maxLines: 3,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Challenge / blocker',
                hintText: 'Issue met, support needed',
              ),
            ),
            TextField(
              key: const ValueKey('report-reference'),
              controller: _reference,
              enabled: !_busy,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Reference (optional)',
                helperText:
                    'Student, application, transaction or case reference. '
                    'No passport numbers or other personal details.',
                helperMaxLines: 2,
              ),
            ),
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
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('report-save'),
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// A report in full, with its history; its writer (or an admin) can edit
/// or delete it. True when it was changed.
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
  List<ReportChange>? _history;

  @override
  void initState() {
    super.initState();
    final id = widget.report.id;
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

  bool get _canChange =>
      widget.report.userId == widget.meta.myId || ref.read(isAdminProvider);

  Future<void> _edit() async {
    final saved = await showReportEditor(
      context,
      meta: widget.meta,
      existing: widget.report,
    );
    if (saved != null && mounted) Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this activity?'),
        content: const Text(
          'It’s removed from reports. The change is kept in the audit trail.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete-report'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(dailyReportsProvider).delete(widget.report.id!);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeReportError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: Dt.textMuted(theme),
    );
    final r = widget.report;
    final dept = widget.meta.department(r.departmentId);
    final stamp = DateFormat('dd/MM/yyyy HH:mm');
    Widget field(String label, String value) => value.trim().isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label.toUpperCase(), style: microLabel(theme)),
                const SizedBox(height: 2),
                SelectableText(value),
              ],
            ),
          );
    final history = _history;
    return AlertDialog(
      title: Text(r.userName.isEmpty ? 'Activity' : r.userName),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              [
                if (r.departmentName.isNotEmpty) r.departmentName,
                _dayFormat.format(r.date),
              ].join(' · '),
              style: muted,
            ),
            const SizedBox(height: 12),
            field('Activity / task', r.description),
            field(
              'Outputs',
              [
                for (final e in r.outputs.entries)
                  '${dept?.outputLabel(e.key) ?? e.key}: ${e.value}',
              ].join('\n'),
            ),
            field(
              'Status',
              '${r.status.label} · ${r.priority.label} priority'
                  '${r.isOverdue(widget.meta.today) ? ' · OVERDUE' : ''}',
            ),
            field(
              'Due / follow-up',
              r.dueDate == null ? '' : _dayFormat.format(r.dueDate!),
            ),
            field('Pending work / next action', r.nextAction),
            field('Challenge / blocker', r.blocker),
            field('Reference', r.reference),
            Text('HISTORY', style: microLabel(theme)),
            const SizedBox(height: 4),
            if (history == null)
              const LinearProgressIndicator()
            else if (history.isEmpty)
              Text('No history available.', style: muted)
            else
              for (final h in history)
                Text(
                  '${switch (h.action) {
                    'created' => 'Added',
                    'edited' => 'Changed',
                    _ => 'Deleted',
                  }} by ${h.changedBy} · ${stamp.format(h.changedAt)}',
                  style: muted,
                ),
          ],
        ),
      ),
      actions: [
        if (_canChange) ...[
          TextButton(
            key: const ValueKey('delete-report'),
            onPressed: _delete,
            child: const Text('Delete'),
          ),
          OutlinedButton(
            key: const ValueKey('edit-report'),
            onPressed: _edit,
            child: const Text('Edit'),
          ),
        ],
        FilledButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
