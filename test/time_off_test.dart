import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/database/app_database_io.dart';
import 'package:client_tracker/database/database.dart';
import 'package:client_tracker/repositories/client_count_repository.dart';
import 'package:client_tracker/repositories/staff_repository.dart';
import 'package:client_tracker/repositories/time_off_repository.dart';
import 'package:client_tracker/repositories/week_repository.dart';
import 'package:client_tracker/services/statistics_service.dart';

/// Data-layer tests for the time-off feature: marks hide numbers from every
/// statistic but never delete them, and un-marking restores them.
void main() {
  late AppDatabase db;
  late WeekRepository weeks;
  late ClientCountRepository counts;
  late TimeOffRepository timeOff;

  setUp(() {
    db = openInMemoryDatabase();
    weeks = WeekRepository(db);
    counts = ClientCountRepository(db);
    timeOff = TimeOffRepository(db);
  });
  tearDown(() => db.close());

  int joyId() =>
      db.raw.select('SELECT id FROM staff WHERE name = ?;', [
            'Joy',
          ]).first['id']!
          as int;

  /// A fixed week (Mon 28 Sep 2026 – Fri 2 Oct 2026) so month math is known.
  (int, List<int>) weekAndDayIds() {
    final week = weeks.createWeekFor(DateTime(2026, 9, 28));
    final days = weeks.getDays(week.id).map((d) => d.id).toList();
    return (week.id, days);
  }

  test('marking a day off hides its numbers and un-marking restores them', () {
    final (weekId, days) = weekAndDayIds();
    counts.saveCount(
      dayId: days[0],
      staffId: joyId(),
      newClients: 5,
      existingClients: 3,
    );

    var day = counts.getDayWithCounts(days[0]);
    expect(day.isOff(joyId()), isFalse);
    expect(day.workingRows.firstWhere((r) => r.staffId == joyId()).total, 8);
    expect(counts.weekTotals(weekId).total, 8);

    timeOff.setDay(dayId: days[0], staffId: joyId(), off: true);

    day = counts.getDayWithCounts(days[0]);
    expect(day.isOff(joyId()), isTrue);
    // Excluded from working rows and every total…
    expect(day.workingRows.any((r) => r.staffId == joyId()), isFalse);
    expect(counts.weekTotals(weekId).total, 0);
    // …but the numbers themselves are kept.
    expect(day.countFor(joyId()).total, 8);

    timeOff.setDay(dayId: days[0], staffId: joyId(), off: false);
    expect(counts.weekTotals(weekId).total, 8);
  });

  test('staffWeekTotals and monthTotals exclude off days', () {
    final (weekId, days) = weekAndDayIds();
    final id = joyId();
    counts.saveCount(
      dayId: days[0],
      staffId: id,
      newClients: 5,
      existingClients: 0,
    );
    counts.saveCount(
      dayId: days[1],
      staffId: id,
      newClients: 2,
      existingClients: 1,
    );

    timeOff.setDay(dayId: days[0], staffId: id, off: true);

    final staffTotals = counts.staffWeekTotals(weekId);
    final joyTotals = staffTotals.firstWhere(
      (t) => t.staffId == id,
      orElse: () => throw StateError('Joy not found'),
    );
    expect(joyTotals.newClients, 2);
    expect(joyTotals.existingClients, 1);

    // Both days fall in September 2026; day 1 is off.
    final month = counts.monthTotals(DateTime(2026, 9));
    expect(month.newClients, 2);
    expect(month.existingClients, 1);
  });

  test('shared day total helper excludes staff marked off', () {
    final (_, days) = weekAndDayIds();
    final id = joyId();
    counts.saveCount(
      dayId: days.first,
      staffId: id,
      newClients: 5,
      existingClients: 3,
    );
    timeOff.setDay(dayId: days.first, staffId: id, off: true);

    final totals = StatisticsService(counts)
        .dayTotals(counts.getDayWithCounts(days.first));
    expect(totals.total, 0);
  });

  test('whole-week off marks every working day', () {
    final (weekId, days) = weekAndDayIds();
    timeOff.setAllWeekDays(weekId: weekId, staffId: joyId(), off: true);
    for (final dayId in days) {
      expect(counts.getDayWithCounts(dayId).isOff(joyId()), isTrue);
    }
    expect(timeOff.weekOffCount(weekId), days.length);

    timeOff.setAllWeekDays(weekId: weekId, staffId: joyId(), off: false);
    expect(timeOff.weekOffCount(weekId), 0);
  });

  test('backup export/restore round-trips time off', () {
    final (_, days) = weekAndDayIds();
    timeOff.setDay(dayId: days[2], staffId: joyId(), off: true);

    final json = db.exportToJson();
    expect(json, contains('staff_day_off'));

    db.restoreFromJson(json);
    expect(counts.getDayWithCounts(days[2]).isOff(joyId()), isTrue);
    expect(counts.getDayWithCounts(days[3]).isOff(joyId()), isFalse);
  });

  test('deleting a week or a staff member removes the affected marks', () {
    final (weekId, days) = weekAndDayIds();
    timeOff.setDay(dayId: days[0], staffId: joyId(), off: true);

    weeks.deleteWeek(weekId);
    expect(
      db.raw.select('SELECT COUNT(*) AS c FROM staff_day_off;').first['c'],
      0,
    );

    final (weekId2, days2) = weekAndDayIds();
    timeOff.setDay(dayId: days2[0], staffId: joyId(), off: true);

    StaffRepository(db).delete(joyId());
    expect(
      db.raw.select('SELECT COUNT(*) AS c FROM staff_day_off;').first['c'],
      0,
    );
    expect(weeks.getWeek(weekId2), isNotNull);
  });
}
