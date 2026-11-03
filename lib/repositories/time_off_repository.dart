import '../database/database.dart';

/// Data access for per-staff time off inside a week.
///
/// One row in `staff_day_off` means "this staff member is not working on
/// that working day of that week" (leave, holiday, a short week, …). The
/// mark only *hides and excludes* whatever numbers exist for those
/// staff-days — it never deletes them, so removing the mark restores the
/// day exactly as it was.
class TimeOffRepository {
  TimeOffRepository(this._db);

  final AppDatabase _db;

  /// Staff ids marked off on [dayId].
  Set<int> offStaffIds(int dayId) {
    final rows = _db.raw.select(
      'SELECT staff_id FROM staff_day_off WHERE day_id = ?;',
      [dayId],
    );
    return {for (final r in rows) r['staff_id']! as int};
  }

  /// Marks (or unmarks) one staff member off on one working day.
  void setDay({required int dayId, required int staffId, required bool off}) {
    if (off) {
      _db.raw.execute(
        'INSERT OR IGNORE INTO staff_day_off (id, day_id, staff_id) '
        'VALUES (new_id(), ?, ?);',
        [dayId, staffId],
      );
    } else {
      _db.raw.execute(
        'DELETE FROM staff_day_off WHERE day_id = ? AND staff_id = ?;',
        [dayId, staffId],
      );
    }
  }

  /// Applies several staff on/off changes to one day in a single
  /// transaction ([changes] maps staff id → off). Used by the day time-off
  /// dialog, including "Holiday" (everyone off).
  void setDayForStaff({required int dayId, required Map<int, bool> changes}) {
    _db.transaction(() {
      for (final MapEntry(key: staffId, value: off) in changes.entries) {
        setDay(dayId: dayId, staffId: staffId, off: off);
      }
    });
  }

  /// Marks (or unmarks) a staff member off on every working day of a week.
  void setAllWeekDays({
    required int weekId,
    required int staffId,
    required bool off,
  }) {
    final days = _db.raw.select('SELECT id FROM work_days WHERE week_id = ?;', [
      weekId,
    ]);
    _db.transaction(() {
      for (final day in days) {
        setDay(dayId: day['id']! as int, staffId: staffId, off: off);
      }
    });
  }

  /// All off marks in a week, keyed by dayId → staff ids.
  Map<int, Set<int>> offMapForWeek(int weekId) {
    final rows = _db.raw.select(
      '''
      SELECT sdo.day_id AS day_id, sdo.staff_id AS staff_id
      FROM staff_day_off sdo
      JOIN work_days wd ON wd.id = sdo.day_id
      WHERE wd.week_id = ?;
    ''',
      [weekId],
    );
    final map = <int, Set<int>>{};
    for (final r in rows) {
      map
          .putIfAbsent(r['day_id']! as int, () => <int>{})
          .add(r['staff_id']! as int);
    }
    return map;
  }

  /// Number of off marks in a week (staff-days).
  int weekOffCount(int weekId) =>
      offMapForWeek(weekId).values.fold(0, (a, s) => a + s.length);

  /// Removes every mark for one staff member (used when the staff member is
  /// permanently deleted, alongside their client counts).
  void deleteForStaff(int staffId) {
    _db.raw.execute('DELETE FROM staff_day_off WHERE staff_id = ?;', [staffId]);
  }
}
