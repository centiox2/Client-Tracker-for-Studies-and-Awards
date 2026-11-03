import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../repositories/client_count_repository.dart';
import '../../repositories/notes_settings_repository.dart';
import '../../state/app_state.dart';

/// Opens the day editor: a short note for the day ("System down 2–4pm"),
/// then who is off — with a "Holiday" switch that marks the whole team off.
///
/// The mirror of [showTimeOffDialog] (one person × the week's days). Like
/// it, marking someone off never deletes their numbers — they're hidden and
/// excluded from totals until the mark is removed.
Future<void> showDayOffDialog(BuildContext context, {required int dayId}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _DayOffDialog(dayId: dayId),
  );
}

class _DayOffDialog extends ConsumerStatefulWidget {
  const _DayOffDialog({required this.dayId});

  final int dayId;

  @override
  ConsumerState<_DayOffDialog> createState() => _DayOffDialogState();
}

class _DayOffDialogState extends ConsumerState<_DayOffDialog> {
  /// Staff currently ticked as off in the editor.
  late Set<int> _off;

  /// The marks when the dialog opened — Save writes only the diff.
  late Set<int> _initialOff;

  bool _seeded = false;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  DayWithCounts? _day() => ref
      .read(currentWeekProvider)
      ?.days
      .where((d) => d.day.id == widget.dayId)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final day = _day();
    if (day == null) {
      return const AlertDialog(
        title: Text('Time off'),
        content: Text('This day is no longer in the selected week.'),
      );
    }
    if (!_seeded) {
      _initialOff = {...day.offStaffIds};
      _off = {..._initialOff};
      _note.text = ref.read(currentWeekProvider)?.notes[day.day.id] ?? '';
      _seeded = true;
    }

    final theme = Theme.of(context);
    final rows = day.rows;
    final everyone =
        rows.isNotEmpty && rows.every((r) => _off.contains(r.staffId));
    final title =
        '${DateFormat('EEEE').format(day.day.date)} '
        '${DateFormat('d MMM').format(day.day.date)}';

    // Warn only when newly-off staff have numbers that will now be hidden.
    final hiding = _off
        .difference(_initialOff)
        .where((id) => day.countFor(id).total > 0)
        .length;

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _note,
              maxLength: DayNotesRepository.maxLength,
              decoration: const InputDecoration(
                labelText: 'Note for the day (optional)',
                hintText: 'e.g. System down 2–4pm, outreach day',
                counterText: '',
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Who’s off on ${DateFormat('EEEE').format(day.day.date)}?',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Holiday — whole team off'),
              subtitle: const Text('Skipped in daily averages'),
              value: everyone,
              onChanged: (v) => setState(() {
                _off = v ? {for (final r in rows) r.staffId} : {};
              }),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final r in rows)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        visualDensity: VisualDensity.compact,
                        title: Text(r.staffName),
                        value: _off.contains(r.staffId),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _off.add(r.staffId);
                          } else {
                            _off.remove(r.staffId);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
            if (hiding > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Numbers already entered for $hiding '
                '${hiding == 1 ? 'person' : 'people'} are kept — they are '
                'just excluded until they are marked as working again.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final actions = ref.read(appActionsProvider);
            final before = ref.read(currentWeekProvider)?.notes[day.day.id];
            if (_note.text.trim() != (before ?? '')) {
              actions.setDayNote(day.day.id, _note.text);
            }
            actions.setDayOffForStaff(
              dayId: day.day.id,
              changes: {
                for (final r in rows)
                  if (_off.contains(r.staffId) !=
                      _initialOff.contains(r.staffId))
                    r.staffId: _off.contains(r.staffId),
              },
            );
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
