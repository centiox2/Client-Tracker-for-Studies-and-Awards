import '../database/database.dart';
import '../models/staff.dart';
import 'week_repository.dart';

/// Groups a work day with its client-count rows (one per staff).
class DayWithCounts {
  DayWithCounts._({
    required this.day,
    required this.counts,
    required this.named,
    required this.offStaffIds,
  });

  final WorkDay day;

  /// Keyed by staffId. Missing entry == 0/0.
  final Map<int, ClientCount> counts;

  /// Same rows with staff display info, keyed by staffId, sorted by
  /// displayOrder when listed.
  final Map<int, NamedClientCount> named;

  /// Staff ids marked off (time off) for this day. Their numbers — if any
  /// were recorded — are kept in [counts] but excluded from every total.
  final Set<int> offStaffIds;

  /// True when [staffId] is marked off for this day.
  bool isOff(int staffId) => offStaffIds.contains(staffId);

  /// A holiday: every staff member on this day is marked off. Such days are
  /// also skipped by the daily averages.
  bool get isHoliday => rows.isNotEmpty && rows.every((r) => isOff(r.staffId));

  /// Rows ordered for display (staff display order, then name).
  List<NamedClientCount> get rows {
    final list = named.values.toList()
      ..sort((a, b) {
        final byOrder = a.displayOrder.compareTo(b.displayOrder);
        return byOrder != 0
            ? byOrder
            : a.staffName.toLowerCase().compareTo(b.staffName.toLowerCase());
      });
    return list;
  }

  /// Display rows excluding staff who are off this day — the set every
  /// total, average and "logged" check should be computed from.
  List<NamedClientCount> get workingRows =>
      rows.where((r) => !isOff(r.staffId)).toList();

  ClientCount countFor(int staffId) =>
      counts[staffId] ??
      ClientCount(
        id: 0,
        dayId: day.id,
        staffId: staffId,
        newClients: 0,
        existingClients: 0,
        updatedAt: DateTime.now(),
      );
}

/// A client-count row joined with the staff display name at read time.
/// The name is resolved from the staff table when the data is loaded, so the
/// export and UI always show the current name for that staff id.
class NamedClientCount {
  NamedClientCount({
    required this.count,
    required this.staffName,
    required this.staffActive,
    this.displayOrder = 0,
  });

  final ClientCount count;
  final String staffName;
  final bool staffActive;
  final int displayOrder;

  int get staffId => count.staffId;
  int get newClients => count.newClients;
  int get existingClients => count.existingClients;
  int get total => count.total;
}

/// Data access for the per-staff, per-day client counts and all derived
/// statistics. Totals are ALWAYS calculated from these rows — never stored.
class ClientCountRepository {
  ClientCountRepository(this._db, {WeekRepository? weekRepository})
    : weekRepository = weekRepository ?? WeekRepository(_db);

  final AppDatabase _db;
  final WeekRepository weekRepository;

  DayWithCounts getDayWithCounts(int dayId) {
    final day = WorkDay.fromRow(
      _db.raw.select('SELECT * FROM work_days WHERE id = ?;', [dayId]).first,
    );
    final rows = _db.raw.select(
      '''
      SELECT cc.*, s.name AS staff_name, s.active AS staff_active,
             s.display_order AS staff_order
      FROM client_counts cc
      LEFT JOIN staff s ON s.id = cc.staff_id
      WHERE cc.day_id = ?;
    ''',
      [dayId],
    );
    final counts = <int, ClientCount>{};
    final named = <int, NamedClientCount>{};
    for (final r in rows) {
      final c = ClientCount.fromRow(r);
      counts[c.staffId] = c;
      named[c.staffId] = NamedClientCount(
        count: c,
        staffName: (r['staff_name'] as String?) ?? 'Staff #${c.staffId}',
        staffActive: ((r['staff_active'] as int?) ?? 1) != 0,
        displayOrder: (r['staff_order'] as int?) ?? 0,
      );
    }
    final offRows = _db.raw.select(
      'SELECT staff_id FROM staff_day_off WHERE day_id = ?;',
      [dayId],
    );
    final off = {for (final r in offRows) r['staff_id']! as int};
    return DayWithCounts._(
      day: day,
      counts: counts,
      named: named,
      offStaffIds: off,
    );
  }

  /// Every day of a week with its counts, oldest first — the same result as
  /// calling [getDayWithCounts] per day, in 3 queries instead of 3 per day.
  /// This runs on every keystroke in the tracker, so it matters.
  List<DayWithCounts> weekDaysWithCounts(int weekId) {
    final days = weekRepository.getDays(weekId);
    if (days.isEmpty) return const [];
    final rows = _db.raw.select(
      '''
      SELECT cc.*, s.name AS staff_name, s.active AS staff_active,
             s.display_order AS staff_order
      FROM client_counts cc
      JOIN work_days wd ON wd.id = cc.day_id
      LEFT JOIN staff s ON s.id = cc.staff_id
      WHERE wd.week_id = ?;
    ''',
      [weekId],
    );
    final offRows = _db.raw.select(
      '''
      SELECT sdo.day_id AS day_id, sdo.staff_id AS staff_id
      FROM staff_day_off sdo
      JOIN work_days wd ON wd.id = sdo.day_id
      WHERE wd.week_id = ?;
    ''',
      [weekId],
    );

    final counts = {for (final d in days) d.id: <int, ClientCount>{}};
    final named = {for (final d in days) d.id: <int, NamedClientCount>{}};
    final off = {for (final d in days) d.id: <int>{}};
    for (final r in rows) {
      final c = ClientCount.fromRow(r);
      counts[c.dayId]?[c.staffId] = c;
      named[c.dayId]?[c.staffId] = NamedClientCount(
        count: c,
        staffName: (r['staff_name'] as String?) ?? 'Staff #${c.staffId}',
        staffActive: ((r['staff_active'] as int?) ?? 1) != 0,
        displayOrder: (r['staff_order'] as int?) ?? 0,
      );
    }
    for (final r in offRows) {
      off[r['day_id']! as int]?.add(r['staff_id']! as int);
    }
    return [
      for (final d in days)
        DayWithCounts._(
          day: d,
          counts: counts[d.id]!,
          named: named[d.id]!,
          offStaffIds: off[d.id]!,
        ),
    ];
  }

  /// The stored values for one staff-day (zeros if there is no row yet).
  /// Cheaper than loading the whole day when only one cell is needed.
  ({int newClients, int existingClients}) countValues(int dayId, int staffId) {
    final rows = _db.raw.select(
      'SELECT new_clients, existing_clients FROM client_counts '
      'WHERE day_id = ? AND staff_id = ?;',
      [dayId, staffId],
    );
    if (rows.isEmpty) return (newClients: 0, existingClients: 0);
    return (
      newClients: rows.first['new_clients']! as int,
      existingClients: rows.first['existing_clients']! as int,
    );
  }

  /// Edits of one cell within this window are merged into one history entry
  /// (typing "12" saves 1 then 12; "+1" clicked three times is one change).
  static const changeMergeWindow = Duration(minutes: 2);

  /// Cumulative-value write: setting New to 5 stores 5 (not 5 + previous 3).
  /// Returns the persisted row. Changes are recorded in the change history
  /// unless [log] is false (e.g. a bulk import).
  ClientCount saveCount({
    required int dayId,
    required int staffId,
    required int newClients,
    required int existingClients,
    bool log = true,
  }) {
    assert(newClients >= 0 && existingClients >= 0);
    final now = DateTime.now().toIso8601String();
    if (log) {
      _logChange(
        dayId: dayId,
        staffId: staffId,
        before: countValues(dayId, staffId),
        newClients: newClients,
        existingClients: existingClients,
        at: now,
      );
    }
    _db.raw.execute(
      'INSERT INTO client_counts '
      '(day_id, staff_id, new_clients, existing_clients, updated_at) '
      'VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT(day_id, staff_id) DO UPDATE SET '
      'new_clients = excluded.new_clients, '
      'existing_clients = excluded.existing_clients, '
      'updated_at = excluded.updated_at;',
      [dayId, staffId, newClients, existingClients, now],
    );
    final row = _db.raw.select(
      'SELECT * FROM client_counts WHERE day_id = ? AND staff_id = ?;',
      [dayId, staffId],
    ).first;
    return ClientCount.fromRow(row);
  }

  void _logChange({
    required int dayId,
    required int staffId,
    required ({int newClients, int existingClients}) before,
    required int newClients,
    required int existingClients,
    required String at,
  }) {
    // The latest entry for this cell, if it's recent enough to merge into.
    final since = DateTime.parse(at)
        .subtract(changeMergeWindow)
        .toIso8601String();
    final recent = _db.raw.select(
      '''
      SELECT id, old_new, old_existing FROM count_changes
      WHERE day_id = ? AND staff_id = ? AND changed_at >= ?
        AND id = (SELECT MAX(id) FROM count_changes
                  WHERE day_id = ? AND staff_id = ?);
    ''',
      [dayId, staffId, since, dayId, staffId],
    );
    if (recent.isNotEmpty) {
      final r = recent.first;
      final id = r['id']! as int;
      if (r['old_new'] == newClients && r['old_existing'] == existingClients) {
        // Edited back to where it started: no change after all.
        _db.raw.execute('DELETE FROM count_changes WHERE id = ?;', [id]);
      } else {
        _db.raw.execute(
          'UPDATE count_changes SET new_new = ?, new_existing = ?, '
          'changed_at = ? WHERE id = ?;',
          [newClients, existingClients, at, id],
        );
      }
      return;
    }
    if (before.newClients == newClients &&
        before.existingClients == existingClients) {
      return;
    }
    _db.raw.execute(
      'INSERT INTO count_changes (day_id, staff_id, old_new, old_existing, '
      'new_new, new_existing, changed_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
      [
        dayId,
        staffId,
        before.newClients,
        before.existingClients,
        newClients,
        existingClients,
        at,
      ],
    );
  }

  /// The change history, newest first: every edit to a client number with
  /// the values before and after. [weekId] limits it to one week.
  List<CountChange> changes({int? weekId, int limit = 500}) {
    final rows = _db.raw.select(
      '''
      SELECT cc.*, wd.date AS date, s.name AS staff_name
      FROM count_changes cc
      JOIN work_days wd ON wd.id = cc.day_id
      LEFT JOIN staff s ON s.id = cc.staff_id
      ${weekId == null ? '' : 'WHERE wd.week_id = ?'}
      ORDER BY cc.changed_at DESC, cc.id DESC
      LIMIT ?;
    ''',
      [?weekId, limit],
    );
    return [
      for (final r in rows)
        CountChange(
          staffName: (r['staff_name'] as String?) ?? 'Staff #${r['staff_id']}',
          day: DateTime.parse(r['date']! as String),
          oldNew: r['old_new']! as int,
          oldExisting: r['old_existing']! as int,
          newNew: r['new_new']! as int,
          newExisting: r['new_existing']! as int,
          changedAt: DateTime.parse(r['changed_at']! as String),
        ),
    ];
  }

  /// Excludes client-count rows whose staff is marked off for that day.
  static const String _notOff = '''
    NOT EXISTS (SELECT 1 FROM staff_day_off sdo
                WHERE sdo.day_id = cc.day_id
                  AND sdo.staff_id = cc.staff_id)
  ''';

  /// Which `work_days wd` count toward a daily average: days where at least
  /// one staff member is working. A day with everyone marked off (a public
  /// holiday, say) is skipped instead of pulling the average down. Callers
  /// also limit to `wd.date <= today` so future days never count.
  static const String _staffedDay =
      '''
    EXISTS (SELECT 1 FROM client_counts cc
            WHERE cc.day_id = wd.id AND $_notOff)
  ''';

  /// Totals for one week: new / existing / combined, daily average and
  /// per-day breakdown. Derived on the fly from `client_counts`; time-off
  /// marks exclude their staff-day numbers.
  WeekTotals weekTotals(int weekId) {
    final dayRows = _db.raw.select(
      '''
      SELECT wd.id            AS day_id,
             COALESCE(SUM(cc.new_clients), 0)      AS new_total,
             COALESCE(SUM(cc.existing_clients), 0) AS existing_total
      FROM work_days wd
      LEFT JOIN client_counts cc ON cc.day_id = wd.id
      WHERE wd.week_id = ? AND (cc.id IS NULL OR $_notOff)
      GROUP BY wd.id
      ORDER BY MIN(wd.date);
    ''',
      [weekId],
    );

    final perDay = <int, DayTotals>{};
    var newTotal = 0, existingTotal = 0;
    for (final r in dayRows) {
      final n = r['new_total']! as int;
      final e = r['existing_total']! as int;
      perDay[r['day_id']! as int] = DayTotals(
        newClients: n,
        existingClients: e,
      );
      newTotal += n;
      existingTotal += e;
    }
    final days =
        _db.raw.select(
              'SELECT COUNT(*) AS c FROM work_days wd '
              'WHERE wd.week_id = ? AND wd.date <= ? AND $_staffedDay;',
              [weekId, _dateKey(DateTime.now())],
            ).first['c']!
            as int;
    return WeekTotals(
      newClients: newTotal,
      existingClients: existingTotal,
      dailyAverage: days == 0 ? 0 : (newTotal + existingTotal) / days,
      perDay: perDay,
    );
  }

  /// Per-staff totals for a whole week (the staff summary table). Includes
  /// staff that were later renamed or deactivated — history stays intact.
  /// Time-off marks exclude the affected days.
  List<StaffWeekTotals> staffWeekTotals(int weekId) {
    final rows = _db.raw.select(
      '''
      SELECT cc.staff_id      AS staff_id,
             s.name           AS name,
             COALESCE(SUM(cc.new_clients), 0)      AS new_total,
             COALESCE(SUM(cc.existing_clients), 0) AS existing_total
      FROM client_counts cc
      JOIN work_days wd ON wd.id = cc.day_id
      LEFT JOIN staff s ON s.id = cc.staff_id
      WHERE wd.week_id = ? AND $_notOff
      GROUP BY cc.staff_id;
    ''',
      [weekId],
    );
    return rows.map(_staffTotalsFromRow).toList();
  }

  /// A grouped per-staff row (with the name joined in) → [StaffWeekTotals].
  static StaffWeekTotals _staffTotalsFromRow(Map<String, Object?> r) {
    final staffId = r['staff_id']! as int;
    return StaffWeekTotals(
      staffId: staffId,
      name: (r['name'] as String?) ?? 'Staff #$staffId',
      newClients: r['new_total']! as int,
      existingClients: r['existing_total']! as int,
    );
  }

  /// Aggregated month totals (whole weeks that overlap the month contribute
  /// their days inside the month). Calculated from stored day data only.
  MonthTotals monthTotals(DateTime month) {
    final first = DateTime(month.year, month.month, 1);
    final last = DateTime(month.year, month.month + 1, 0);
    final range = [_dateKey(first), _dateKey(last)];

    final rows = _db.raw.select('''
      SELECT COALESCE(SUM(cc.new_clients), 0)      AS new_total,
             COALESCE(SUM(cc.existing_clients), 0) AS existing_total
      FROM work_days wd
      JOIN client_counts cc ON cc.day_id = wd.id
      WHERE wd.date BETWEEN ? AND ? AND $_notOff;
    ''', range);

    final staffRows = _db.raw.select('''
      SELECT cc.staff_id AS staff_id,
             s.name      AS name,
             COALESCE(SUM(cc.new_clients), 0)      AS new_total,
             COALESCE(SUM(cc.existing_clients), 0) AS existing_total
      FROM work_days wd
      JOIN client_counts cc ON cc.day_id = wd.id
      LEFT JOIN staff s ON s.id = cc.staff_id
      WHERE wd.date BETWEEN ? AND ? AND $_notOff
      GROUP BY cc.staff_id;
    ''', range);
    final staff = staffRows.map(_staffTotalsFromRow).toList();

    final n = rows.first['new_total']! as int;
    final e = rows.first['existing_total']! as int;
    // Same rule as weekTotals: staffed days in the month up to today.
    final today = _dateKey(DateTime.now());
    final upTo = today.compareTo(range[1]) < 0 ? today : range[1];
    final dayCount =
        _db.raw.select(
              'SELECT COUNT(*) AS c FROM work_days wd '
              'WHERE wd.date BETWEEN ? AND ? AND $_staffedDay;',
              [range[0], upTo],
            ).first['c']!
            as int;
    return MonthTotals(
      newClients: n,
      existingClients: e,
      dailyAverage: dayCount == 0 ? 0 : (n + e) / dayCount,
      staffTotals: staff,
    );
  }

  WeekWithDays getWeekWithDays(Week week) {
    return WeekWithDays(week: week, days: weekDaysWithCounts(week.id));
  }
}

/// A full week: the [Week] plus each day with its counts.
class WeekWithDays {
  WeekWithDays({required this.week, required this.days});

  final Week week;
  final List<DayWithCounts> days;
}

class DayTotals {
  const DayTotals({required this.newClients, required this.existingClients});

  final int newClients;
  final int existingClients;

  int get total => newClients + existingClients;
}

class WeekTotals {
  const WeekTotals({
    required this.newClients,
    required this.existingClients,
    required this.dailyAverage,
    required this.perDay,
  });

  final int newClients;
  final int existingClients;
  final double dailyAverage;

  /// Keyed by dayId.
  final Map<int, DayTotals> perDay;

  int get total => newClients + existingClients;
}

/// One edit to a staff member's numbers for a day (change history).
class CountChange {
  const CountChange({
    required this.staffName,
    required this.day,
    required this.oldNew,
    required this.oldExisting,
    required this.newNew,
    required this.newExisting,
    required this.changedAt,
  });

  final String staffName;

  /// The working day the numbers belong to.
  final DateTime day;
  final int oldNew;
  final int oldExisting;
  final int newNew;
  final int newExisting;
  final DateTime changedAt;
}

class StaffWeekTotals {
  const StaffWeekTotals({
    required this.staffId,
    required this.name,
    required this.newClients,
    required this.existingClients,
  });

  final int staffId;
  final String name;
  final int newClients;
  final int existingClients;

  int get total => newClients + existingClients;
}

class MonthTotals {
  const MonthTotals({
    required this.newClients,
    required this.existingClients,
    required this.dailyAverage,
    required this.staffTotals,
  });

  final int newClients;
  final int existingClients;
  final double dailyAverage;
  final List<StaffWeekTotals> staffTotals;

  int get total => newClients + existingClients;
}

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
