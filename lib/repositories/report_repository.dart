import '../database/database.dart';

/// Detailed numbers for any date range (a day, a week or a month) — the
/// Reports page. Same rules as the rest of the app: numbers on a staff
/// member's day off are excluded, and the daily average divides by staffed
/// days up to today (holidays and future days don't count).
class ReportRepository {
  ReportRepository(this._db);

  final AppDatabase _db;

  /// The first tracked working day, or null before anything is tracked.
  DateTime? firstDay() {
    final v = _db.raw
        .select('SELECT MIN(date) AS d FROM work_days;')
        .first['d'];
    return v == null ? null : DateTime.parse(v as String);
  }

  Report report(DateTime from, DateTime to) {
    final range = [_dateKey(from), _dateKey(to)];
    final today = _dateKey(DateTime.now());

    // One row per staff-day entry (LEFT JOIN keeps days with no entries).
    final rows = _db.raw.select('''
      SELECT wd.id AS day_id, wd.date AS date, wd.week_id AS week_id,
             cc.staff_id AS staff_id,
             cc.new_clients AS new_clients,
             cc.existing_clients AS existing_clients,
             cc.updated_at AS updated_at,
             (sdo.id IS NOT NULL) AS off
      FROM work_days wd
      LEFT JOIN client_counts cc ON cc.day_id = wd.id
      LEFT JOIN staff_day_off sdo
             ON sdo.day_id = wd.id AND sdo.staff_id = cc.staff_id
      WHERE wd.date BETWEEN ? AND ?
      ORDER BY wd.date;
    ''', range);

    final notes = {
      for (final r in _db.raw.select('''
        SELECT dn.day_id AS day_id, dn.note AS note
        FROM day_notes dn JOIN work_days wd ON wd.id = dn.day_id
        WHERE wd.date BETWEEN ? AND ?;
      ''', range))
        r['day_id']! as int: r['note']! as String,
    };

    final staffInfo = {
      for (final r in _db.raw.select(
        'SELECT id, name, active, display_order FROM staff;',
      ))
        r['id']! as int: r,
    };

    final days = <int, _DayAcc>{};
    final staff = <int, _StaffAcc>{};
    final cells = <String, ReportCell>{};
    final entries = <({int staffId, DateTime date, int n, int e, String at})>[];
    String? lastUpdated;

    for (final r in rows) {
      final dayId = r['day_id']! as int;
      final date = r['date']! as String;
      final day = days.putIfAbsent(
        dayId,
        () => _DayAcc(dayId, DateTime.parse(date), r['week_id']! as int),
      );
      final staffId = r['staff_id'] as int?;
      if (staffId == null) continue;

      final off = (r['off']! as int) == 1;
      final n = r['new_clients']! as int;
      final e = r['existing_clients']! as int;
      final s = staff.putIfAbsent(staffId, () => _StaffAcc(staffId));
      cells[ReportCell.key(staffId, dayId)] = ReportCell(
        newClients: n,
        existingClients: e,
        off: off,
      );
      day.staffCount++;
      if (off) {
        day.offCount++;
        s.daysOff++;
        continue;
      }
      day.newClients += n;
      day.existingClients += e;
      s.newClients += n;
      s.existingClients += e;
      if (date.compareTo(today) <= 0) s.daysWorked++;
      if (n + e > 0) {
        final at = r['updated_at']! as String;
        if (lastUpdated == null || at.compareTo(lastUpdated) > 0) {
          lastUpdated = at;
        }
        entries.add((
          staffId: staffId,
          date: DateTime.parse(date),
          n: n,
          e: e,
          at: at,
        ));
      }
    }

    final dayList = [
      for (final d in days.values)
        ReportDay(
          dayId: d.dayId,
          weekId: d.weekId,
          date: d.date,
          newClients: d.newClients,
          existingClients: d.existingClients,
          staffCount: d.staffCount,
          offCount: d.offCount,
          note: notes[d.dayId],
        ),
    ];
    final staffedDaysSoFar = dayList
        .where((d) => !d.isHoliday && d.staffCount > 0)
        .where((d) => _dateKey(d.date).compareTo(today) <= 0)
        .length;

    final staffList =
        [
          for (final s in staff.values)
            ReportStaff(
              staffId: s.staffId,
              name:
                  staffInfo[s.staffId]?['name'] as String? ??
                  'Staff #${s.staffId}',
              active: (staffInfo[s.staffId]?['active'] as int? ?? 0) == 1,
              displayOrder: staffInfo[s.staffId]?['display_order'] as int? ?? 0,
              newClients: s.newClients,
              existingClients: s.existingClients,
              daysWorked: s.daysWorked,
              daysOff: s.daysOff,
            ),
        ]..sort((a, b) {
          final byTotal = b.total.compareTo(a.total);
          return byTotal != 0
              ? byTotal
              : a.displayOrder.compareTo(b.displayOrder);
        });

    entries.sort((a, b) => b.at.compareTo(a.at));
    String nameOf(int id) => staffInfo[id]?['name'] as String? ?? 'Staff #$id';

    return Report(
      from: from,
      to: to,
      days: dayList,
      staff: staffList,
      cells: cells,
      activity: [
        for (final x in entries)
          ReportActivity(
            staffName: nameOf(x.staffId),
            date: x.date,
            newClients: x.n,
            existingClients: x.e,
            updatedAt: DateTime.parse(x.at),
          ),
      ],
      staffedDaysSoFar: staffedDaysSoFar,
      lastUpdated: lastUpdated == null ? null : DateTime.parse(lastUpdated),
    );
  }
}

class Report {
  Report({
    required this.from,
    required this.to,
    required this.days,
    required this.staff,
    required this.cells,
    required this.activity,
    required this.staffedDaysSoFar,
    required this.lastUpdated,
  });

  /// One staff member's numbers on one day: [cellFor].
  final Map<String, ReportCell> cells;

  /// Staff-days with clients, most recently updated first ("latest
  /// activity"). Counts are running totals, so each row is the latest tally.
  final List<ReportActivity> activity;

  ReportCell? cellFor(int staffId, int dayId) =>
      cells[ReportCell.key(staffId, dayId)];

  final DateTime from;
  final DateTime to;

  /// Tracked working days in the range, oldest first. Days whose week was
  /// never created don't appear.
  final List<ReportDay> days;

  /// Everyone with a row in the range, most clients first.
  final List<ReportStaff> staff;

  /// Days that count toward the daily average.
  final int staffedDaysSoFar;

  /// When a non-zero count in the range was last changed.
  final DateTime? lastUpdated;

  int get newClients => days.fold(0, (a, d) => a + d.newClients);
  int get existingClients => days.fold(0, (a, d) => a + d.existingClients);
  int get total => newClients + existingClients;
  double get dailyAverage =>
      staffedDaysSoFar == 0 ? 0 : total / staffedDaysSoFar;

  /// Staff who saw at least one client in the range.
  int get staffWithClients => staff.where((s) => s.total > 0).length;

  /// Totals per calendar month, oldest first.
  List<ReportBucket> get months => _bucket((d) => DateTime(d.year, d.month));

  /// Totals per week (keyed by its Monday), oldest first.
  List<ReportBucket> get weeks => _bucket(_mondayOf);

  List<ReportBucket> _bucket(DateTime Function(DateTime) keyOf) {
    final today = _dateKey(DateTime.now());
    final out = <DateTime, ReportBucket>{};
    for (final d in days) {
      final b = out.putIfAbsent(
        keyOf(d.date),
        () => ReportBucket(keyOf(d.date)),
      );
      b.newClients += d.newClients;
      b.existingClients += d.existingClients;
      if (!d.isHoliday &&
          d.staffCount > 0 &&
          _dateKey(d.date).compareTo(today) <= 0) {
        b.staffedDays++;
      }
    }
    return out.values.toList()..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Average clients per working day for each weekday (Monday first), over
  /// the days so far that someone worked — which days are usually busiest.
  List<WeekdayAverage> get weekdayAverages {
    final today = _dateKey(DateTime.now());
    final acc = {for (var w = 1; w <= 5; w++) w: WeekdayAverage(w)};
    for (final d in days) {
      if (d.isHoliday || d.staffCount == 0) continue;
      if (_dateKey(d.date).compareTo(today) > 0) continue;
      final a = acc[d.date.weekday];
      if (a == null) continue;
      a.days++;
      a._new += d.newClients;
      a._existing += d.existingClients;
    }
    return acc.values.toList();
  }

  /// One staff member's numbers over this report's range, or null when they
  /// have no rows in it.
  StaffProfile? profileFor(int staffId) {
    final s = staff.where((x) => x.staffId == staffId).firstOrNull;
    if (s == null) return null;
    final today = _dateKey(DateTime.now());
    final weeks = <DateTime, ReportBucket>{};
    final weekday = {for (var w = 1; w <= 5; w++) w: WeekdayAverage(w)};
    final recent = <StaffDay>[];
    StaffDay? best;
    DateTime? first;
    for (final d in days) {
      final c = cellFor(staffId, d.dayId);
      if (c == null) continue;
      final past = _dateKey(d.date).compareTo(today) <= 0;
      final day = StaffDay(
        date: d.date,
        newClients: c.newClients,
        existingClients: c.existingClients,
        off: c.off,
      );
      if (past) recent.add(day);
      if (c.off) continue;
      final w = weeks.putIfAbsent(
        _mondayOf(d.date),
        () => ReportBucket(_mondayOf(d.date)),
      );
      w.newClients += c.newClients;
      w.existingClients += c.existingClients;
      if (past) {
        w.staffedDays++;
        final a = weekday[d.date.weekday];
        if (a != null) {
          a.days++;
          a._new += c.newClients;
          a._existing += c.existingClients;
        }
      }
      if (c.total > 0) {
        first ??= d.date;
        if (best == null || c.total > best.total) best = day;
      }
    }
    return StaffProfile(
      staff: s,
      weeks: weeks.values.toList()..sort((a, b) => a.start.compareTo(b.start)),
      weekdays: weekday.values.toList(),
      recentDays: recent.reversed.take(10).toList(),
      bestDay: best,
      firstClient: first,
    );
  }
}

DateTime _mondayOf(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// Totals for a month or a week inside a report.
class ReportBucket {
  ReportBucket(this.start);

  /// First day of the month, or the Monday of the week.
  final DateTime start;
  int newClients = 0;
  int existingClients = 0;

  /// Working days so far (holidays and future days don't count).
  int staffedDays = 0;

  int get total => newClients + existingClients;
  double get dailyAverage => staffedDays == 0 ? 0 : total / staffedDays;
}

/// Average clients per working day on one weekday.
class WeekdayAverage {
  WeekdayAverage(this.weekday);

  /// DateTime.monday … DateTime.friday.
  final int weekday;
  int days = 0;
  int _new = 0;
  int _existing = 0;

  double get newAverage => days == 0 ? 0 : _new / days;
  double get existingAverage => days == 0 ? 0 : _existing / days;
  double get average => newAverage + existingAverage;
}

/// One day of one staff member's numbers.
class StaffDay {
  const StaffDay({
    required this.date,
    required this.newClients,
    required this.existingClients,
    required this.off,
  });

  final DateTime date;
  final int newClients;
  final int existingClients;
  final bool off;

  int get total => newClients + existingClients;
}

/// A staff member's record over a report's range (the staff profile).
class StaffProfile {
  const StaffProfile({
    required this.staff,
    required this.weeks,
    required this.weekdays,
    required this.recentDays,
    required this.bestDay,
    required this.firstClient,
  });

  final ReportStaff staff;

  /// Week by week, oldest first (only weeks they were on).
  final List<ReportBucket> weeks;

  /// Their average per working day on each weekday.
  final List<WeekdayAverage> weekdays;

  /// Their latest days up to today, newest first.
  final List<StaffDay> recentDays;

  /// Their busiest day (null before their first client).
  final StaffDay? bestDay;

  /// The first day they saw a client in the range.
  final DateTime? firstClient;

  double get dailyAverage =>
      staff.daysWorked == 0 ? 0 : staff.total / staff.daysWorked;
}

class ReportDay {
  const ReportDay({
    required this.dayId,
    required this.weekId,
    required this.date,
    required this.newClients,
    required this.existingClients,
    required this.staffCount,
    required this.offCount,
    this.note,
  });

  final int dayId;

  /// The day's note, if one was written.
  final String? note;
  final int weekId;
  final DateTime date;
  final int newClients;
  final int existingClients;
  final int staffCount;
  final int offCount;

  int get total => newClients + existingClients;
  bool get isHoliday => staffCount > 0 && offCount == staffCount;
}

class ReportStaff {
  const ReportStaff({
    required this.staffId,
    required this.name,
    required this.active,
    required this.displayOrder,
    required this.newClients,
    required this.existingClients,
    required this.daysWorked,
    required this.daysOff,
  });

  final int staffId;
  final String name;
  final bool active;
  final int displayOrder;
  final int newClients;
  final int existingClients;

  /// Days so far in the range this person was on (not marked off).
  final int daysWorked;
  final int daysOff;

  int get total => newClients + existingClients;
}

class _DayAcc {
  _DayAcc(this.dayId, this.date, this.weekId);
  final int dayId;
  final DateTime date;
  final int weekId;
  int newClients = 0;
  int existingClients = 0;
  int staffCount = 0;
  int offCount = 0;
}

class _StaffAcc {
  _StaffAcc(this.staffId);
  final int staffId;
  int newClients = 0;
  int existingClients = 0;
  int daysWorked = 0;
  int daysOff = 0;
}

String _dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// One staff member on one day.
class ReportCell {
  const ReportCell({
    required this.newClients,
    required this.existingClients,
    required this.off,
  });

  static String key(int staffId, int dayId) => '$staffId:$dayId';

  final int newClients;
  final int existingClients;

  /// Marked off: the numbers are excluded from every total.
  final bool off;

  int get total => newClients + existingClients;
}

/// A staff-day's latest tally and when it was last changed.
class ReportActivity {
  const ReportActivity({
    required this.staffName,
    required this.date,
    required this.newClients,
    required this.existingClients,
    required this.updatedAt,
  });

  final String staffName;
  final DateTime date;
  final int newClients;
  final int existingClients;
  final DateTime updatedAt;

  int get total => newClients + existingClients;
}
