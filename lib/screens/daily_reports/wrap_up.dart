import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../services/daily_reports_service.dart';
import '../../state/app_state.dart';
import 'report_editor.dart';

/// "Wrap up my day": your open tasks with tick boxes (what you were doing
/// is ticked already) and counts if your department records them; submits
/// every ticked one together. Returns what was submitted.
Future<List<SaveOutcome>?> showWrapUp(
  BuildContext context, {
  required ReportsMeta meta,
  required List<ActivityReport> tasks,
}) => showDialog<List<SaveOutcome>>(
  context: context,
  builder: (_) => _WrapUp(meta: meta, tasks: tasks),
);

class _WrapUp extends ConsumerStatefulWidget {
  const _WrapUp({required this.meta, required this.tasks});
  final ReportsMeta meta;
  final List<ActivityReport> tasks;

  @override
  ConsumerState<_WrapUp> createState() => _WrapUpState();
}

class _WrapUpState extends ConsumerState<_WrapUp> {
  late final Set<int> _ticked = {
    for (final t in widget.tasks)
      if (t.status == ReportStatus.inProgress &&
          t.review != ReviewState.returned)
        t.id!,
  };
  final Map<int, Map<String, int>> _counts = {};
  bool _busy = false;
  String? _error;
  final List<SaveOutcome> _done = [];

  List<OutputField> _outputsFor(ActivityReport t) =>
      widget.meta
          .department(t.departmentId ?? widget.meta.myDepartmentId)
          ?.outputs ??
      const [];

  Future<void> _submit() async {
    if (_busy || _ticked.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final outbox = ref.read(reportOutboxProvider.notifier);
    for (final t in widget.tasks) {
      if (!_ticked.contains(t.id) || _done.any((o) => o.task.id == t.id)) {
        continue;
      }
      try {
        final counts = _counts[t.id] ?? const {};
        _done.add(
          await outbox.save(
            submit: true,
            t.copyWith(
              status: ReportStatus.done,
              outputs: {
                ...t.outputs,
                for (final e in counts.entries)
                  if (e.value > 0) e.key: e.value,
              },
            ),
          ),
        );
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error =
              '${t.ref}: ${describeReportError(e)}'
              '${_done.isEmpty ? '' : ' The others were submitted.'}';
          _ticked.removeAll([for (final o in _done) o.task.id]);
        });
        return;
      }
    }
    if (mounted) Navigator.pop(context, _done);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = Clarity.of(theme);
    final muted = theme.textTheme.bodySmall?.copyWith(color: c.textMuted);
    final today = widget.meta.today;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit,
      },
      child: AlertDialog(
        title: const Text('Wrap up my day'),
        scrollable: true,
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Tick what you finished today '
                '(${taskDay(today, today: today)}). They’re submitted '
                'together; the rest stay on your list.',
                style: muted,
              ),
              const SizedBox(height: 8),
              for (final t in widget.tasks) ...[
                CheckboxListTile(
                  key: ValueKey('wrap-${t.id}'),
                  value: _ticked.contains(t.id),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: _busy
                      ? null
                      : (on) => setState(
                          () => on == true
                              ? _ticked.add(t.id!)
                              : _ticked.remove(t.id),
                        ),
                  title: Text(
                    '${t.ref}  ${t.description}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    t.review == ReviewState.returned
                        ? 'Returned to you'
                        : t.status.label,
                    style: muted,
                  ),
                  secondary: t.urgency == TaskUrgency.normal
                      ? null
                      : UrgencyPill(t.urgency),
                ),
                if (_ticked.contains(t.id) && _outputsFor(t).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 48, bottom: 8),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      children: [
                        for (final o in _outputsFor(t))
                          SizedBox(
                            width: 150,
                            child: TextField(
                              key: ValueKey('wrap-${t.id}-${o.key}'),
                              enabled: !_busy,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(5),
                              ],
                              decoration: InputDecoration(
                                isDense: true,
                                labelText: o.label,
                                hintText: '${t.outputs[o.key] ?? 0}',
                              ),
                              onChanged: (v) => (_counts[t.id!] ??= {})[o.key] =
                                  int.tryParse(v) ?? 0,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const ValueKey('wrap-error'),
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
            onPressed: _busy
                ? null
                : () => Navigator.pop(context, _done.isEmpty ? null : _done),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            key: const ValueKey('wrap-submit'),
            onPressed: _busy || _ticked.isEmpty ? null : _submit,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send, size: 16),
            label: Text(
              _ticked.isEmpty
                  ? 'Submit'
                  : 'Submit ${_ticked.length} task${_ticked.length == 1 ? '' : 's'}',
            ),
          ),
        ],
      ),
    );
  }
}
