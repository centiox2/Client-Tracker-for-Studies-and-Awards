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

/// Whether the cells of [dayId] (dated [date]) are locked: a future day the
/// user hasn't confirmed editing yet in this session.
bool isDayGuarded(WidgetRef ref, int dayId, DateTime date) =>
    isFutureDay(date) && !ref.watch(unlockedDaysProvider).contains(dayId);

/// Asks before numbers go into a future day; on yes, unlocks that day for
/// the rest of the session. Returns whether editing may go ahead.
Future<bool> confirmFutureDayEdit(
  BuildContext context,
  WidgetRef ref, {
  required int dayId,
  required DateTime date,
}) async {
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
