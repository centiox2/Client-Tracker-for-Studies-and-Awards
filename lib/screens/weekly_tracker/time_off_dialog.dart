import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../repositories/client_count_repository.dart';
import '../../state/app_state.dart';

/// Opens the per-week time-off editor for one staff member: pick the days
/// (Mon–Fri) they are not working this week, or mark the whole week off.
///
/// Numbers already recorded on a marked-off day are never deleted — they are
/// hidden and excluded from every total until the day is switched back on.
Future<void> showTimeOffDialog(
  BuildContext context,
  WidgetRef ref, {
  required int staffId,
  required String staffName,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _TimeOffDialog(staffId: staffId, staffName: staffName),
  );
}

class _TimeOffDialog extends ConsumerStatefulWidget {
  const _TimeOffDialog({required this.staffId, required this.staffName});

  final int staffId;
  final String staffName;

  @override
  ConsumerState<_TimeOffDialog> createState() => _TimeOffDialogState();
}

class _TimeOffDialogState extends ConsumerState<_TimeOffDialog> {
  /// Days currently toggled off in the editor (day ids).
  late Set<int> _offDays;

  /// The state when the dialog opened — Save writes only the diff.
  late Set<int> _initialOff;

  bool _seeded = false;

  void _seed() {
    if (_seeded) return;
    final data = ref.read(currentWeekProvider);
    _initialOff = {
      for (final d in data?.days ?? const <DayWithCounts>[])
        if (d.isOff(widget.staffId)) d.day.id,
    };
    _offDays = {..._initialOff};
    _seeded = true;
  }

  @override
  Widget build(BuildContext context) {
    _seed();
    final data = ref.watch(currentWeekProvider);
    final theme = Theme.of(context);

    if (data == null || data.days.isEmpty) {
      return const AlertDialog(
        title: Text('Time off'),
        content: Text('Create a week first.'),
      );
    }
    final days = data.days;

    String dayLabel(DayWithCounts d) =>
        '${DateFormat('EEEE').format(d.day.date)} · '
        '${DateFormat('d MMM').format(d.day.date)}';

    // Warn only when newly-off days hold numbers that will now be hidden.
    final newlyOff = _offDays.difference(_initialOff).where((dayId) {
      final d = days.where((x) => x.day.id == dayId).firstOrNull;
      return d != null && d.countFor(widget.staffId).total > 0;
    }).length;

    final wholeWeek = _offDays.length == days.length;

    return AlertDialog(
      title: Text('Time off — ${widget.staffName}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Week of ${DateFormat('MMMM d').format(data.week.startDate)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Off the whole week'),
              value: wholeWeek,
              onChanged: (v) => setState(() {
                _offDays = v ? days.map((d) => d.day.id).toSet() : {};
              }),
            ),
            const Divider(height: 1),
            for (final d in days)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                visualDensity: VisualDensity.compact,
                title: Text(dayLabel(d)),
                value: _offDays.contains(d.day.id),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _offDays.add(d.day.id);
                  } else {
                    _offDays.remove(d.day.id);
                  }
                }),
              ),
            if (newlyOff > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Numbers already recorded for $newlyOff '
                '${newlyOff == 1 ? 'day' : 'days'} are kept — they are just '
                'excluded until the day is switched back on.',
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
            for (final d in days) {
              final off = _offDays.contains(d.day.id);
              if (off != _initialOff.contains(d.day.id)) {
                actions.setStaffDayOff(
                  dayId: d.day.id,
                  staffId: widget.staffId,
                  off: off,
                );
              }
            }
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
