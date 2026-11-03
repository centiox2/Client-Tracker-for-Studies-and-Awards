import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../design/app_theme.dart';
import '../../repositories/week_repository.dart';
import '../../state/app_state.dart';

/// Opens the New Week flow, set to [initialMonday]'s week (default: this
/// week). Returns the opened week id, or null if cancelled.
Future<int?> showNewWeekDialog(
  BuildContext context,
  WidgetRef ref, {
  DateTime? initialMonday,
}) async {
  final result = await showDialog<_NewWeekResult>(
    context: context,
    builder: (_) => _NewWeekDialog(initialMonday: initialMonday),
  );
  if (result == null) return null;
  return result.weekId;
}

class _NewWeekResult {
  _NewWeekResult(this.weekId);
  final int weekId;
}

class _NewWeekDialog extends ConsumerStatefulWidget {
  const _NewWeekDialog({this.initialMonday});

  final DateTime? initialMonday;

  @override
  ConsumerState<_NewWeekDialog> createState() => _NewWeekDialogState();
}

class _NewWeekDialogState extends ConsumerState<_NewWeekDialog> {
  late DateTime _monday;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _monday = WeekRepository.mondayOf(widget.initialMonday ?? DateTime.now());
  }

  Future<void> _pickWeek() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _monday.add(const Duration(days: 2)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: 'Pick any day in the week',
    );
    if (picked != null) {
      setState(() {
        _monday = WeekRepository.mondayOf(picked);
      });
    }
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    try {
      final weeks = ref.read(weekRepositoryProvider);
      final existingWeek = weeks.findByStartDate(_monday);
      final week =
          existingWeek ?? ref.read(appActionsProvider).createWeek(_monday);
      ref.read(currentWeekIdProvider.notifier).set(week.id);
      if (mounted) {
        Navigator.of(context).pop(_NewWeekResult(week.id));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not create week: $e')));
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = List.generate(5, (i) => _monday.add(Duration(days: i)));
    final fmt = DateFormat('EEEE – dd/MM/yyyy');
    final activeStaff = ref
        .watch(staffListProvider)
        .where((s) => s.active)
        .length;
    final existing = ref.watch(weekExistsProvider(_monday));

    return AlertDialog(
      title: Text(existing ? 'Open existing week' : 'New week'),
      content: ConstrainedBox(
        // Never wider than the window minus padding — prevents clipping on
        // small windows and phones.
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width < 470
              ? MediaQuery.sizeOf(context).width - 48
              : 420,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Week of ${DateFormat('MMMM d, yyyy').format(_monday)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Dt.s12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...days.map(
                      (d) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: Dt.s4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.event_outlined,
                              size: 14,
                              color: Dt.textFaint(Theme.of(context)),
                            ),
                            const SizedBox(width: Dt.s8),
                            Text(
                              fmt.format(d),
                              style: Dt.mono(context, size: 12.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: Dt.s12),
                    Text(
                      '$activeStaff active staff members will be added to every day.',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: Dt.textMuted(Theme.of(context))),
                    ),
                    if (existing)
                      Padding(
                        padding: const EdgeInsets.only(top: Dt.s8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.warning_amber_rounded,
                              color: Theme.of(context).colorScheme.error,
                              size: 16,
                            ),
                            const SizedBox(width: Dt.s8),
                            Expanded(
                              child: Text(
                                'A week starting ${DateFormat('dd/MM/yyyy').format(_monday)} already exists. It will be opened instead of duplicated.',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
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
            TextButton.icon(
              onPressed: _pickWeek,
              icon: const Icon(Icons.edit_calendar, size: 16),
              label: const Text('Change week'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          autofocus: true,
          onPressed: _creating ? null : _create,
          icon: const Icon(Icons.check, size: 16),
          label: Text(existing ? 'Open Existing Week' : 'Create Week'),
        ),
      ],
    );
  }
}

/// True if a week starting exactly on [monday] already exists.
final weekExistsProvider = Provider.family<bool, DateTime>((ref, monday) {
  ref.watch(dataVersionProvider);
  return ref.read(weekRepositoryProvider).findByStartDate(monday) != null;
});
