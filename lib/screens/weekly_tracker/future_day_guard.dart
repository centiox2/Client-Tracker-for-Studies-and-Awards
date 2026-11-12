import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../state/app_state.dart';

/// True when [date] is after today — numbers can't have happened yet, so
/// the tracker dims that day and asks before the first edit.
bool isFutureDay(DateTime date) {
  final now = DateTime.now();
  return DateTime(
    date.year,
    date.month,
    date.day,
  ).isAfter(DateTime(now.year, now.month, now.day));
}

/// The Monday of [date]'s week.
DateTime mondayOf(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  return d.subtract(Duration(days: d.weekday - DateTime.monday));
}

/// True when [date] is in a week that has already finished (before this
/// week's Monday): changing it changes numbers already reported.
bool isPastWeekDay(DateTime date) =>
    mondayOf(date).isBefore(mondayOf(DateTime.now()));

/// Whether the cells of [dayId] (dated [date]) are locked: a future day, or
/// a day of a finished week, that the user hasn't confirmed editing yet in
/// this session.
bool isDayGuarded(WidgetRef ref, int dayId, DateTime date) {
  if (isFutureDay(date)) {
    return !ref.watch(unlockedDaysProvider).contains(dayId);
  }
  if (isPastWeekDay(date)) {
    return !ref.watch(unlockedWeeksProvider).contains(mondayOf(date));
  }
  return false;
}

/// Asks before numbers go into a future day, or change in a finished week;
/// on yes, unlocks that day (or that whole past week) for the rest of the
/// session. Returns whether editing may go ahead.
Future<bool> confirmFutureDayEdit(
  BuildContext context,
  WidgetRef ref, {
  required int dayId,
  required DateTime date,
}) async {
  if (!isFutureDay(date) && isPastWeekDay(date)) {
    return _confirmPastWeekEdit(context, ref, date);
  }
  final dayName = DateFormat('EEEE').format(date);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('$dayName hasn’t happened yet'),
      content: Text(
        '${DateFormat('EEEE d MMMM').format(date)} is in the future. Numbers '
        'entered here count as $dayName’s clients, not today’s.\n\n'
        'Enter numbers for $dayName anyway?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('Enter for $dayName'),
        ),
      ],
    ),
  );
  if (ok == true) ref.read(unlockedDaysProvider.notifier).unlock(dayId);
  return ok == true;
}

Future<bool> _confirmPastWeekEdit(
  BuildContext context,
  WidgetRef ref,
  DateTime date,
) async {
  final monday = mondayOf(date);
  final friday = monday.add(const Duration(days: 4));
  final range =
      '${DateFormat('d MMM').format(monday)} – '
      '${DateFormat('d MMM y').format(friday)}';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('past-week-warning'),
      icon: const Icon(Icons.history_toggle_off),
      title: const Text('Change a past week?'),
      content: Text(
        'The week of $range has already finished. Changing it changes '
        'numbers that may already be in reports and totals.\n\n'
        'Every change is kept in Change history.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('past-week-confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Change this week'),
        ),
      ],
    ),
  );
  if (ok == true) ref.read(unlockedWeeksProvider.notifier).unlock(monday);
  return ok == true;
}
